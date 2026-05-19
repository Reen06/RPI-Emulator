#!/usr/bin/env bash
# Shared Docker chroot runner for the rpi toolkit.
# Requires lib/common.sh to be sourced first.

# docker_chroot_run <img> <interactive:0|1> <network_mode:bridge|host> [cmd...]
#
# Mounts the image, runs the Pi chroot via Docker, then cleanly unmounts.
# When network_mode=host and /tmp/rpi-wifi-state exists, wpa_supplicant.conf
# is injected for the duration of the run and then restored (the .img file
# itself is never modified).
docker_chroot_run() {
    local img="$1"
    local interactive="$2"
    local network_mode="$3"
    shift 3
    local cmd=("$@")

    command -v docker &>/dev/null || die "docker not found"
    [[ -f "$img" ]] || die "Image not found: $img"

    mnt=$(mktemp -d /tmp/rpi-root.XXXXXX)
    local loop_dev=""

    _wpa_backup=""

    _docker_chroot_cleanup() {
        if [[ -n "$_wpa_backup" && -f "$_wpa_backup" ]]; then
            local wpa_conf="$mnt/etc/wpa_supplicant/wpa_supplicant.conf"
            sudo cp "$_wpa_backup" "$wpa_conf" 2>/dev/null || true
            rm -f "$_wpa_backup"
        elif [[ -n "$_wpa_backup" ]]; then
            # Backup name set means we created the file from scratch; remove it
            local wpa_conf="$mnt/etc/wpa_supplicant/wpa_supplicant.conf"
            sudo rm -f "$wpa_conf" 2>/dev/null || true
        fi
        sudo umount "$mnt/boot"     2>/dev/null || true
        sudo umount "$mnt/proc"    2>/dev/null || true
        sudo umount "$mnt/sys"     2>/dev/null || true
        sudo umount "$mnt/dev/pts" 2>/dev/null || true
        sudo umount "$mnt/dev"     2>/dev/null || true
        sudo umount "$mnt"         2>/dev/null || true
        [[ -n "${loop_dev:-}" ]] && sudo losetup -d "$loop_dev" 2>/dev/null || true
        rm -rf "$mnt"
    }
    trap _docker_chroot_cleanup EXIT INT TERM

    # Detach any stale loop devices for this image (left by a failed previous run)
    while IFS= read -r lo; do
        sudo losetup -d "$lo" 2>/dev/null || true
    done < <(losetup -j "$img" 2>/dev/null | cut -d: -f1)

    # Use partscan so both partitions share one loop device — avoids the
    # "overlapping loop device" error newer kernels raise when two loop
    # devices point at the same backing file.
    loop_dev=$(sudo losetup --find --show --partscan "$img") \
        || die "losetup failed for $img"
    sudo mount "${loop_dev}p2" "$mnt"
    sudo mount "${loop_dev}p1" "$mnt/boot"
    sudo mount --bind /proc    "$mnt/proc"
    sudo mount --bind /sys     "$mnt/sys"
    sudo mount --bind /dev     "$mnt/dev"
    sudo mount --bind /dev/pts "$mnt/dev/pts"

    # Inject WiFi network config when emulation is active
    if [[ "$network_mode" == "host" && -f /tmp/rpi-wifi-state ]]; then
        _inject_wifi_config "$mnt"
    fi

    local hostname; hostname=$(slug "$img")

    # Ensure the image hostname resolves inside the chroot so sudo doesn't warn
    if ! grep -q "127.0.1.1" "$mnt/etc/hosts" 2>/dev/null; then
        echo "127.0.1.1	$hostname" | sudo tee -a "$mnt/etc/hosts" >/dev/null
    fi
    local docker_flags=(
        --rm
        --platform linux/arm64
        --privileged
        --hostname "$hostname"
        --network "$network_mode"
        -v "$mnt:/rpi"
        -w /rpi
    )
    [[ "$interactive" == "1" ]] && docker_flags+=(-it)
    [[ ${#cmd[@]} -eq 0 ]] && cmd=(/bin/bash)

    docker run "${docker_flags[@]}" ubuntu:24.04 chroot /rpi "${cmd[@]}"
    local rc=$?

    _docker_chroot_cleanup
    trap - EXIT INT TERM
    return $rc
}

_inject_wifi_config() {
    local mnt="$1"
    local wpa_dir="$mnt/etc/wpa_supplicant"
    local wpa_conf="$wpa_dir/wpa_supplicant.conf"

    sudo mkdir -p "$wpa_dir"

    if [[ -f "$wpa_conf" ]]; then
        _wpa_backup=$(mktemp /tmp/rpi-wpa-backup.XXXXXX)
        sudo cp "$wpa_conf" "$_wpa_backup"
        # Signal to cleanup: non-empty + file existed
    else
        _wpa_backup="__new__"  # sentinel: file did not exist; cleanup will remove it
        sudo tee "$wpa_conf" >/dev/null <<'EOF'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=GB
EOF
    fi

    local net_count=0
    while IFS='=' read -r key val; do
        [[ "$key" == "RADIO_COUNT" ]] && net_count="$val"
    done < /tmp/rpi-wifi-state

    for ((i=0; i<net_count; i++)); do
        local type ssid pass
        type=$(grep "^NETWORK_${i}_TYPE=" /tmp/rpi-wifi-state | cut -d= -f2-)
        ssid=$(grep  "^NETWORK_${i}_SSID=" /tmp/rpi-wifi-state | cut -d= -f2-)
        pass=$(grep  "^NETWORK_${i}_PASS=" /tmp/rpi-wifi-state | cut -d= -f2-)

        case "$type" in
            wpa2)
                sudo tee -a "$wpa_conf" >/dev/null <<EOF

network={
    ssid="$ssid"
    psk="$pass"
    key_mgmt=WPA-PSK
}
EOF
                ;;
            open|captive-portal)
                sudo tee -a "$wpa_conf" >/dev/null <<EOF

network={
    ssid="$ssid"
    key_mgmt=NONE
}
EOF
                ;;
        esac
    done
}
