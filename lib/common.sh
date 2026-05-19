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
