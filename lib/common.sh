#!/usr/bin/env bash
# Shared variables and helpers for the rpi toolkit.
# Source this file; do not execute directly.

RPI_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
IMAGES_DIR="$RPI_HOME/images"
DISKS_DIR="$RPI_HOME/disks"
KERNELS_DIR="$RPI_HOME/kernels"
LIB_DIR="$RPI_HOME/lib"
CONFIGS_DIR="$RPI_HOME/configs"

DEFAULT_USER="pi"
DEFAULT_PASS="raspberry"
SSH_PORT=2222

die()     { echo "ERROR: $*" >&2; exit 1; }
info()    { echo "  $*"; }
section() { echo ""; echo "=== $* ==="; }

# Derive a short identifier from an image path.
# "label__original.img"  →  "label"
# "original.img"         →  "original"
slug() {
    local base; base=$(basename "$1" .img)
    if [[ "$base" == *__* ]]; then
        echo "${base%%__*}"
    else
        echo "$base" | tr ' ' '_'
    fi
}

# Human-friendly display name.
# "label__original.img"  →  "label  (original.img)"
# "original.img"         →  "original.img"
_image_display_name() {
    local base; base=$(basename "$1" .img)
    if [[ "$base" == *__* ]]; then
        local lbl="${base%%__*}"
        local orig="${base#*__}.img"
        printf "%s  (%s)" "$lbl" "$orig"
    else
        printf "%s.img" "$base"
    fi
}

# Supported emulation targets.
# Format: key|display|qemu_bin|qemu_machine|cpu|ram|kernel|dtb
# 32-bit (armhf image required): pi0, pi1aplus, pi2b
# 64-bit (arm64 image required): pi3b, pi3bplus, pi3aplus, pi4b, pi5b
# Pi 4B requires QEMU 9+ (available in QEMU 11). Pi 5B not yet in any QEMU release.
_MACHINE_TABLE=(
    "pi0|Pi Zero (512 MB)|qemu-system-arm|raspi0|arm1176|512M|kernel.img|bcm2708-rpi-zero.dtb"
    "pi1aplus|Pi 1 A+ (256 MB)|qemu-system-arm|raspi1ap|arm1176|256M|kernel.img|bcm2708-rpi-b-plus.dtb"
    "pi2b|Pi 2B (1 GB)|qemu-system-arm|raspi2b|cortex-a7|1G|kernel7.img|bcm2709-rpi-2-b.dtb"
    "pi3b|Pi 3B (1 GB)|qemu-system-aarch64|raspi3b|cortex-a53|1G|kernel8.img|bcm2710-rpi-3-b.dtb"
    "pi3bplus|Pi 3B+ (1 GB)|qemu-system-aarch64|raspi3b|cortex-a53|1G|kernel8.img|bcm2710-rpi-3-b-plus.dtb"
    "pi3aplus|Pi 3A+ (512 MB)|qemu-system-aarch64|raspi3ap|cortex-a53|512M|kernel8.img|bcm2710-rpi-3-b-plus.dtb"
    "pi4b|Pi 4B (2 GB)|qemu-system-aarch64|raspi4b|cortex-a72|2G|kernel8.img|bcm2711-rpi-4-b.dtb"
    "pi5b|Pi 5B (4 GB)|qemu-system-aarch64|raspi5b|cortex-a76|4G|kernel_2712.img|bcm2712-rpi-5-b.dtb"
)

# Load user-defined machines from machines.conf (same pipe-delimited format).
# Add entries there for new Pi models as QEMU gains support for them.
if [[ -f "$CONFIGS_DIR/machines.conf" ]]; then
    while IFS= read -r _mc_line; do
        _mc_line="${_mc_line%%#*}"
        [[ -z "${_mc_line// }" ]] && continue
        _MACHINE_TABLE+=("$_mc_line")
    done < "$CONFIGS_DIR/machines.conf"
fi

# Per-binary machine-list cache (populated lazily).
_QEMU_AARCH64_MACHINES=""
_QEMU_ARM_MACHINES=""

_qemu_supports_machine() {
    local bin="$1" machine="$2"
    command -v "$bin" &>/dev/null || return 1
    local cache
    case "$bin" in
        qemu-system-aarch64)
            [[ -z "$_QEMU_AARCH64_MACHINES" ]] && \
                _QEMU_AARCH64_MACHINES=$(qemu-system-aarch64 -M help 2>/dev/null)
            cache="$_QEMU_AARCH64_MACHINES" ;;
        qemu-system-arm)
            [[ -z "$_QEMU_ARM_MACHINES" ]] && \
                _QEMU_ARM_MACHINES=$(qemu-system-arm -M help 2>/dev/null)
            cache="$_QEMU_ARM_MACHINES" ;;
        *) cache=$("$bin" -M help 2>/dev/null) ;;
    esac
    grep -q "^${machine}[[:space:]]" <<< "$cache"
}

_machine_prop() {
    local key="$1" field="$2"
    for entry in "${_MACHINE_TABLE[@]}"; do
        [[ "${entry%%|*}" != "$key" ]] && continue
        case "$field" in
            display)  cut -d'|' -f2 <<< "$entry" ;;
            qemu_bin) cut -d'|' -f3 <<< "$entry" ;;
            qemu)     cut -d'|' -f4 <<< "$entry" ;;
            cpu)      cut -d'|' -f5 <<< "$entry" ;;
            ram)      cut -d'|' -f6 <<< "$entry" ;;
            kernel)   cut -d'|' -f7 <<< "$entry" ;;
            dtb)      cut -d'|' -f8 <<< "$entry" ;;
        esac
        return 0
    done
    return 1
}

_pick_machine() {
    echo "" >&2
    echo "Select emulation target:" >&2
    echo "  (Pi Zero/1/2 require a 32-bit armhf image; Pi 3+ use arm64)" >&2
    echo "" >&2
    local i=1 keys=() avail=()
    for entry in "${_MACHINE_TABLE[@]}"; do
        local key bin machine disp note
        key="${entry%%|*}"
        disp=$(cut -d'|' -f2 <<< "$entry")
        bin=$(cut -d'|' -f3 <<< "$entry")
        machine=$(cut -d'|' -f4 <<< "$entry")
        if _qemu_supports_machine "$bin" "$machine"; then
            note=""
            avail+=("1")
        elif ! command -v "$bin" &>/dev/null; then
            note="  [install qemu-system-arm]"
            avail+=("0")
        else
            note="  [not supported by installed QEMU]"
            avail+=("0")
        fi
        printf "  [%d] %-26s%s\n" "$i" "$disp" "$note" >&2
        keys+=("$key")
        ((i++))
    done
    echo "" >&2
    echo "  Pi 5 is not yet supported by any QEMU release. Check https://www.qemu.org/" >&2
    echo "  Or add custom models to: $CONFIGS_DIR/machines.conf" >&2
    echo "" >&2
    read -rp "Select [1-$((i-1))]: " sel
    [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le $((i-1)) ]] || die "Invalid selection"
    [[ "${avail[$((sel-1))]}" == "0" ]] && \
        die "$(_machine_prop "${keys[$((sel-1))]}" display) is not supported by the installed QEMU ($(qemu-system-aarch64 --version 2>/dev/null | head -1)). QEMU 9+ required."
    echo "${keys[$((sel-1))]}"
}

# Pi 4B: patch DTB to enable the DWC2 USB OTG controller (disabled in stock DTB).
# QEMU usb-net requires this to appear as usb0 in the guest.
_pi4b_patch_dtb() {
    local dtb="$1"
    python3 - "$dtb" <<'PYEOF' 2>/dev/null || return 1
import sys
try:
    import fdt
except ImportError:
    sys.exit(0)
with open(sys.argv[1], 'rb') as f:
    dt = fdt.parse_dtb(f.read())
usb = dt.get_node('/soc/usb@7e980000')
if usb is None:
    sys.exit(0)
patched = False
for prop in usb.props:
    if prop.name == 'status' and prop.data != ['okay']:
        prop.data = ['okay']
        patched = True
if patched:
    with open(sys.argv[1], 'wb') as f:
        f.write(dt.to_dtb())
PYEOF
}

# Pi 4B: build the custom initrd that fixes first-boot user setup for QEMU.
# Takes the original initrd from $kdir/initrd.orig, replaces the main init
# script with our patched version, and writes $kdir/initrd.
_pi4b_build_initrd() {
    local kdir="$1"
    local username="${2:-pi}"
    local password="${3:-raspberry}"
    local orig="$kdir/initrd.orig"
    local init_patch="$LIB_DIR/pi4b-init-patch.sh"

    [[ -f "$orig" ]] || { echo "  Warning: no initrd.orig found; Pi 4B networking may not work" >&2; return 1; }
    [[ -f "$init_patch" ]] || { echo "  Warning: pi4b-init-patch.sh not found in lib/" >&2; return 1; }

    python3 - "$orig" "$init_patch" "$kdir/initrd" "$username" "$password" <<'PYEOF' || return 1
import sys, os, subprocess, shutil, tempfile

orig, init_patch, out, username, password = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
ZSTD_MAGIC = b'\x28\xb5\x2f\xfd'

data = open(orig, 'rb').read()
split_at = data.find(ZSTD_MAGIC)
if split_at < 0:
    # No zstd magic — whole file is a single cpio; treat as main part
    split_at = 0
    header = b''
else:
    header = data[:split_at]

work = tempfile.mkdtemp(prefix='rpi-initrd.')
try:
    # Decompress main initramfs
    main_cpio = os.path.join(work, 'main.cpio')
    res = subprocess.run(['zstd', '-d', '-q', '-f', '-o', main_cpio],
                         input=data[split_at:], capture_output=True)
    if res.returncode != 0:
        print(f'zstd decompress failed: {res.stderr.decode()[:200]}', file=sys.stderr)
        sys.exit(1)

    # Extract cpio
    root = os.path.join(work, 'root')
    os.makedirs(root)
    with open(main_cpio, 'rb') as f:
        subprocess.run(['cpio', '-id', '--quiet'], stdin=f, cwd=root,
                       capture_output=True)

    # Generate password hash and patch init script with credentials
    res = subprocess.run(['openssl', 'passwd', '-6', '-stdin'],
                        input=password.encode(), capture_output=True)
    if res.returncode != 0:
        print(f'openssl passwd failed: {res.stderr.decode()[:200]}', file=sys.stderr)
        sys.exit(1)
    pass_hash = res.stdout.decode().strip()

    with open(init_patch) as f:
        init_content = f.read()
    init_content = init_content.replace('__RPI_USERNAME__', username)
    init_content = init_content.replace('__RPI_PASS_HASH__', pass_hash)
    with open(os.path.join(root, 'init'), 'w') as f:
        f.write(init_content)
    os.chmod(os.path.join(root, 'init'), 0o755)

    # Patch rpi_wd watchdog script: writing 'V' to /dev/watchdog0 causes
    # an immediate reboot in QEMU 11's bcm2835 watchdog emulation.
    wd_script = os.path.join(root, 'scripts', 'init-top', 'rpi_wd')
    if os.path.exists(wd_script):
        with open(wd_script, 'w') as f:
            f.write('#!/bin/sh\n# Skip: /dev/watchdog0 write causes immediate reboot in QEMU 11\ncase "${1}" in\n  prereqs) echo "udev"; exit 0 ;;\nesac\nexit 0\n')
        os.chmod(wd_script, 0o755)

    # Repack cpio | zstd
    new_zst = os.path.join(work, 'new.zst')
    files = sorted(subprocess.check_output(['find', '.'], cwd=root).decode().splitlines())
    ls_proc = subprocess.Popen(['find', '.'], cwd=root, stdout=subprocess.PIPE)
    sort_proc = subprocess.Popen(['sort'], stdin=ls_proc.stdout, stdout=subprocess.PIPE)
    ls_proc.stdout.close()
    cpio_proc = subprocess.Popen(['cpio', '-H', 'newc', '-o', '--quiet'],
                                  stdin=sort_proc.stdout, stdout=subprocess.PIPE, cwd=root)
    sort_proc.stdout.close()
    zstd_proc = subprocess.Popen(['zstd', '-19', '-q', '-f', '-o', new_zst],
                                  stdin=cpio_proc.stdout)
    cpio_proc.stdout.close()
    zstd_proc.wait()

    # Assemble output
    with open(out, 'wb') as f:
        f.write(header)
        f.write(open(new_zst, 'rb').read())
finally:
    shutil.rmtree(work, ignore_errors=True)
PYEOF
}

# Read $CONFIGS_DIR/<slug>.ports and echo a comma-prefixed hostfwd fragment.
# Output is empty when no forwards are configured.
# Example output: ,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443
_load_extra_hostfwds() {
    local slug_name="$1"
    local ports_file="$CONFIGS_DIR/${slug_name}.ports"
    [[ -f "$ports_file" ]] || return 0
    local fragment=""
    while IFS= read -r line; do
        line="${line%%#*}"; line="${line// /}"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^([0-9]+):([0-9]+)$ ]] || continue
        local hport="${BASH_REMATCH[1]}" gport="${BASH_REMATCH[2]}"
        [[ "$hport" == "$SSH_PORT" ]] && continue
        fragment+=",hostfwd=tcp::${hport}-:${gport}"
    done < "$ports_file"
    printf '%s' "$fragment"
}

pick_image() {
    local images=("$IMAGES_DIR"/*.img)
    [[ -e "${images[0]}" ]] || die "No images in $IMAGES_DIR. Run: rpi download"
    echo "" >&2
    echo "Available images:" >&2
    local i=1
    for img in "${images[@]}"; do
        local display size
        size=$(du -sh "$img" 2>/dev/null | cut -f1)
        display=$(_image_display_name "$img")
        printf "  [%d] %-50s  %s\n" "$i" "$display" "$size" >&2
        ((i++))
    done
    echo "" >&2
    read -rp "Select image [1-$((i-1))]: " sel
    [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le $((i-1)) ]] || die "Invalid selection"
    echo "${images[$((sel-1))]}"
}

# If $1 looks like an image path (file exists or exists under IMAGES_DIR), echo the
# resolved path; otherwise echo nothing.  Caller shifts $1 on non-empty result.
_parse_image_arg() {
    local first="${1:-}"
    if [[ -f "$first" ]]; then
        echo "$first"
    elif [[ -f "$IMAGES_DIR/$first" ]]; then
        echo "$IMAGES_DIR/$first"
    else
        echo ""
    fi
}

_mount_image_root() {
    local img="$1" mnt_var="$2" with_boot="$3"
    shift 3

    local sector_size root_offset boot_offset
    sector_size=$(fdisk -l "$img" | awk '/^Sector size/ {print $4}')
    root_offset=$(fdisk -l "$img" | awk '/Linux/ {print $2 * '"$sector_size"'; exit}')
    boot_offset=$(fdisk -l "$img" | awk '/FAT/ || /W95 FAT/ || / b / {print $2 * '"$sector_size"'; exit}')

    local mnt
    mnt=$(mktemp -d /tmp/rpi-root.XXXXXX)
    printf -v "$mnt_var" '%s' "$mnt"

    sudo mount -o loop,offset="$root_offset" "$img" "$mnt"
    [[ "$with_boot" == "1" ]] && sudo mount -o loop,offset="$boot_offset" "$img" "$mnt/boot"
}

_umount_image_root() {
    local mnt="$1" with_bind="${2:-0}"
    [[ "$with_bind" == "1" ]] && {
        sudo umount "$mnt/boot"     2>/dev/null || true
        sudo umount "$mnt/proc"    2>/dev/null || true
        sudo umount "$mnt/sys"     2>/dev/null || true
        sudo umount "$mnt/dev/pts" 2>/dev/null || true
        sudo umount "$mnt/dev"     2>/dev/null || true
    }
    sudo umount "$mnt" 2>/dev/null || true
    rm -rf "$mnt"
}

# List all wireless interfaces present in /sys (works without iw installed).
_get_wireless_ifaces() {
    local ifaces=()
    for netdir in /sys/class/net/*/; do
        [[ -d "$netdir/phy80211" ]] && ifaces+=("$(basename "$netdir")")
    done
    printf '%s\n' "${ifaces[@]}" | sort -V
}
