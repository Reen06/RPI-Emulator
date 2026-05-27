#!/usr/bin/env bash
# Master provisioning script for the ros-farino Pi image.
#
# Run on the HOST:
#   ./setup/provision.sh [slug]   # slug defaults to "ros-farino"
#
# Strategy: ROS2 Jazzy apt packages depend on Ubuntu Noble libraries that
# don't exist on Debian Trixie. We instead:
#   1. Build an arm64 Docker image (ros:jazzy-ros-base + farino_wave) on the
#      host using docker buildx (QEMU emulation, ~10 min one-time cost).
#   2. Save the image as a tar, copy it into the Pi image filesystem.
#   3. Install docker.io on the Pi via the chroot.
#   4. Configure two systemd services:
#        farino-wave-load — one-shot: docker load on first Pi boot
#        farino-wave      — runs the wave node via Docker on every boot
#   5. Delete the stale qcow2 so QEMU rebuilds from the provisioned image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SLUG="${1:-ros-farino}"

IMAGES_DIR="$REPO_DIR/images"
DISKS_DIR="$REPO_DIR/disks"
WS_DIR="$REPO_DIR/ros2_ws"
SDK_SRC="/home/bcavelti/Engineering/Robotics/Farino Docs/fairino-python-sdk-main/fairino-python-sdk-main/linux"

ok()   { echo "  ✓  $*"; }
info() { echo "  →  $*"; }
warn() { echo "  !  $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

command -v docker &>/dev/null || die "docker not found"

# ── Resolve image path by slug ────────────────────────────────────────────────

IMG=$(ls "$IMAGES_DIR/${SLUG}__"*.img 2>/dev/null | head -1 || true)
[[ -f "$IMG" ]] || IMG=$(ls "$IMAGES_DIR/${SLUG}.img" 2>/dev/null | head -1 || true)
[[ -f "$IMG" ]] || die "No image found for slug '$SLUG' in $IMAGES_DIR"

echo ""
echo "=== Provisioning: $SLUG ==="
echo "    Image: $IMG"
echo ""

# ── Step 1: Build arm64 Docker image on the host ──────────────────────────────
# Uses docker buildx with QEMU to build for linux/arm64.
# The ros2_ws/ directory is the Docker build context.

info "Preparing Docker build context..."
# Copy fairino SDK into the build context so Dockerfile COPY can find it
SDK_DEST="$WS_DIR/fairino_sdk"
if [[ -d "$SDK_SRC/fairino" ]]; then
    rm -rf "$SDK_DEST"
    cp -r "$SDK_SRC/fairino" "$SDK_DEST"
    [[ -f "$SDK_DEST/__init__.py" ]] || touch "$SDK_DEST/__init__.py"
    ok "Fairino SDK staged at ros2_ws/fairino_sdk/"
else
    warn "SDK not found at $SDK_SRC/fairino — creating empty placeholder"
    mkdir -p "$SDK_DEST/fairino"
    touch "$SDK_DEST/fairino/__init__.py"
    touch "$SDK_DEST/__init__.py"
fi

info "Building arm64 Docker image (farino-wave:latest) via buildx..."
info "This takes ~10 minutes on first run (QEMU emulates arm64 for the build)."
docker buildx build \
    --platform linux/arm64 \
    --load \
    -t farino-wave:latest \
    "$WS_DIR"
ok "Docker image built: farino-wave:latest"

info "Saving image to tar (this may take a minute)..."
IMAGE_TAR="$(mktemp /tmp/farino-wave.XXXXXX.tar.gz)"
docker save farino-wave:latest | gzip > "$IMAGE_TAR"
IMAGE_TAR_SIZE=$(du -sh "$IMAGE_TAR" | cut -f1)
ok "Image saved: $IMAGE_TAR_SIZE"

# ── Mount image once ──────────────────────────────────────────────────────────

ROOT_MNT=$(mktemp -d /tmp/rpi-prov.XXXXXX)
LOOP_DEV=""

_cleanup() {
    info "Unmounting image..."
    sudo umount "$ROOT_MNT/boot"    2>/dev/null || true
    sudo umount "$ROOT_MNT/dev/pts" 2>/dev/null || true
    sudo umount "$ROOT_MNT/dev"     2>/dev/null || true
    sudo umount "$ROOT_MNT/sys"     2>/dev/null || true
    sudo umount "$ROOT_MNT/proc"    2>/dev/null || true
    sudo umount "$ROOT_MNT"         2>/dev/null || true
    [[ -n "$LOOP_DEV" ]] && sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "$ROOT_MNT"
    rm -f "$IMAGE_TAR"
}
trap _cleanup EXIT INT TERM

info "Attaching image..."
while IFS= read -r lo; do
    sudo losetup -d "$lo" 2>/dev/null || true
done < <(sudo losetup -j "$IMG" 2>/dev/null | cut -d: -f1)

LOOP_DEV=$(sudo losetup --find --show --partscan "$IMG")
sudo mount "${LOOP_DEV}p2" "$ROOT_MNT"
sudo mount "${LOOP_DEV}p1" "$ROOT_MNT/boot"
sudo mount --bind /proc    "$ROOT_MNT/proc"
sudo mount --bind /sys     "$ROOT_MNT/sys"
sudo mount --bind /dev     "$ROOT_MNT/dev"
sudo mount --bind /dev/pts "$ROOT_MNT/dev/pts"
grep -q "127.0.1.1" "$ROOT_MNT/etc/hosts" 2>/dev/null || \
    echo "127.0.1.1	$SLUG" | sudo tee -a "$ROOT_MNT/etc/hosts" >/dev/null
ok "Image mounted at $ROOT_MNT (loop: $LOOP_DEV)"

# ── Helpers ───────────────────────────────────────────────────────────────────

pi_exec() {
    docker run --rm \
        --platform linux/arm64 \
        --privileged \
        --hostname "$SLUG" \
        --network bridge \
        -v "$ROOT_MNT:/rpi" \
        -w /rpi \
        ubuntu:24.04 \
        chroot /rpi "$@"
}

pi_copy() {
    local src="$1" dst="$2"
    sudo mkdir -p "$(dirname "$ROOT_MNT/$dst")"
    sudo cp "$src" "$ROOT_MNT/$dst"
}

pi_copy_dir() {
    local src_dir="$1" dest_parent="$2" dest_name="${3:-$(basename "$1")}"
    local src_base; src_base=$(basename "$src_dir")
    local tmp_tar; tmp_tar=$(mktemp /tmp/rpi-prov.XXXXXX.tar.gz)
    tar -czf "$tmp_tar" -C "$(dirname "$src_dir")" "$src_base"
    sudo mkdir -p "$ROOT_MNT/$dest_parent"
    sudo tar -xzf "$tmp_tar" -C "$ROOT_MNT/$dest_parent"
    local actual="$ROOT_MNT/$dest_parent/$src_base"
    local target="$ROOT_MNT/$dest_parent/$dest_name"
    [[ "$actual" != "$target" ]] && sudo mv "$actual" "$target"
    rm -f "$tmp_tar"
}

# ── Step 2: Ensure robotics user ──────────────────────────────────────────────

info "Ensuring 'robotics' user exists..."
pi_exec bash -c "
    if ! id robotics &>/dev/null; then
        useradd -m -s /bin/bash -u 1001 robotics
        echo 'robotics:farino' | chpasswd
        usermod -aG sudo robotics 2>/dev/null || true
        mkdir -p /etc/sudoers.d
        echo 'robotics ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/robotics
    fi
    mkdir -p /home/robotics/plans
    chown -R robotics:robotics /home/robotics
"
ok "User 'robotics' ready"

# ── Step 3: Install Docker CE on Pi ──────────────────────────────────────────
# docker.io on Debian Trixie ships only docker-init, not the daemon/CLI.
# Use the official Docker CE repository instead.

info "Installing Docker CE on Pi..."
pi_exec bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable' \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io
    systemctl enable docker 2>/dev/null || true
"
ok "Docker CE installed and enabled"

# ── Step 4: Copy the Docker image tar ─────────────────────────────────────────

info "Copying Docker image tar to Pi (~$(du -sh "$IMAGE_TAR" | cut -f1))..."
pi_copy "$IMAGE_TAR" "/home/robotics/farino-wave.tar.gz"
sudo chown 1001:1001 "$ROOT_MNT/home/robotics/farino-wave.tar.gz"
ok "Image tar ready at /home/robotics/farino-wave.tar.gz"

# ── Step 5: Configure network ─────────────────────────────────────────────────

info "Configuring eth0 static IP (192.168.58.100/24)..."
pi_copy "$SCRIPT_DIR/02_configure_network.sh" "/tmp/02_configure_network.sh"
sudo chmod +x "$ROOT_MNT/tmp/02_configure_network.sh"
pi_exec bash /tmp/02_configure_network.sh
ok "Network configured"

# ── Step 6: Install systemd services ─────────────────────────────────────────

info "Installing systemd services..."
pi_copy "$SCRIPT_DIR/03_setup_service.sh" "/tmp/03_setup_service.sh"
sudo chmod +x "$ROOT_MNT/tmp/03_setup_service.sh"
pi_exec bash /tmp/03_setup_service.sh
ok "Services installed and enabled"

# ── Step 7: Copy documentation ────────────────────────────────────────────────

info "Copying docs to /home/robotics/plans/..."
for f in "$REPO_DIR/docs/"*.md; do
    [[ -f "$f" ]] || continue
    pi_copy "$f" "/home/robotics/plans/$(basename "$f")"
done
sudo chown -R 1001:1001 "$ROOT_MNT/home/robotics/plans"
ok "Documentation installed"

# ── Step 8: Delete stale qcow2 ────────────────────────────────────────────────

QCOW2="$DISKS_DIR/${SLUG}.qcow2"
if [[ -f "$QCOW2" ]]; then
    info "Deleting stale qcow2 (QEMU will rebuild from provisioned image)..."
    rm -f "$QCOW2"
    ok "Deleted: $QCOW2"
fi

# Cleanup via trap EXIT
echo ""
echo "=== Provisioning complete ==="
echo ""
echo "Boot verify (QEMU, ~60s + first-boot docker load):"
echo "  rpi run $SLUG"
echo "  # then: systemctl status farino-wave-load farino-wave"
echo ""
echo "Flash to real Pi:"
echo "  rpi flash $SLUG"
echo ""
echo "On real Pi — manual test:"
echo "  docker run --rm --network=host -e FARINO_DRY_RUN=1 farino-wave:latest"
