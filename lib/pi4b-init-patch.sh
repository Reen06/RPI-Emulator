#!/bin/sh

# Default PATH differs between shells, and is not automatically exported
# by klibc dash.  Make it consistent.
export PATH=/sbin:/usr/sbin:/bin:/usr/bin

[ -d /dev ] || mkdir -m 0755 /dev
[ -d /root ] || mkdir -m 0700 /root
[ -d /sys ] || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /tmp ] || mkdir /tmp
mkdir -p /var/lock
mount -t sysfs -o nodev,noexec,nosuid sysfs /sys
mount -t proc -o nodev,noexec,nosuid proc /proc

# shellcheck disable=SC2013
for x in $(cat /proc/cmdline); do
	case $x in
	initramfs.clear)
		clear
		;;
	quiet)
		quiet=y
		;;
	esac
done

if [ "$quiet" != "y" ]; then
	quiet=n
	echo "Loading, please wait..."
fi
export quiet

# Note that this only becomes /dev on the real filesystem if udev's scripts
# are used; which they will be, but it's worth pointing out
mount -t devtmpfs -o nosuid,mode=0755 udev /dev

# Prepare the /dev directory
[ ! -h /dev/fd ] && ln -s /proc/self/fd /dev/fd
[ ! -h /dev/stdin ] && ln -s /proc/self/fd/0 /dev/stdin
[ ! -h /dev/stdout ] && ln -s /proc/self/fd/1 /dev/stdout
[ ! -h /dev/stderr ] && ln -s /proc/self/fd/2 /dev/stderr

mkdir /dev/pts
mount -t devpts -o noexec,nosuid,gid=5,mode=0600 devpts /dev/pts || true

# Export the dpkg architecture
export DPKG_ARCH=
. /conf/arch.conf

# Set modprobe env
export MODPROBE_OPTIONS="-qb"

# Export relevant variables
export ROOT=
export ROOTDELAY=
export ROOTFLAGS=
export ROOTFSTYPE=
export IP=
export DEVICE=
export BOOT=
export BOOTIF=
export UBIMTD=
export break=
export init=/sbin/init
export readonly=y
export rootmnt=/root
export debug=
export panic=
export blacklist=
export resume=
export resume_offset=
export noresume=
export drop_caps=
export fastboot=n
export forcefsck=n
export fsckfix=


# Bring in the main config
. /conf/initramfs.conf
for conf in conf/conf.d/*; do
	[ -f "${conf}" ] && . "${conf}"
done
. /scripts/functions

# Parse command line options
# shellcheck disable=SC2013
for x in $(cat /proc/cmdline); do
	case $x in
	init=*)
		init=${x#init=}
		;;
	root=*)
		ROOT=${x#root=}
		if [ -z "${BOOT}" ] && [ "$ROOT" = "/dev/nfs" ]; then
			BOOT=nfs
		fi
		;;
	rootflags=*)
		ROOTFLAGS="-o ${x#rootflags=}"
		;;
	rootfstype=*)
		# Linux interprets 'rootfstype=*tmpfs*' to control the
		# initramfs filesystem; we should remove 'tmpfs' from
		# the list
		ROOTFSTYPE="$(list_filter_out "${x#rootfstype=}" tmpfs)"
		;;
	rootdelay=*)
		ROOTDELAY="${x#rootdelay=}"
		case ${ROOTDELAY} in
		*[![:digit:].]*)
			ROOTDELAY=
			;;
		esac
		;;
	nfsroot=*)
		# shellcheck disable=SC2034
		NFSROOT="${x#nfsroot=}"
		;;
	initramfs.runsize=*)
		RUNSIZE="${x#initramfs.runsize=}"
		;;
	ip=*)
		IP="${x#ip=}"
		;;
	boot=*)
		BOOT=${x#boot=}
		;;
	ubi.mtd=*)
		UBIMTD=${x#ubi.mtd=}
		;;
	resume=*)
		RESUME="${x#resume=}"
		;;
	resume_offset=*)
		resume_offset="${x#resume_offset=}"
		;;
	noresume)
		noresume=y
		;;
	drop_capabilities=*)
		drop_caps="-d ${x#drop_capabilities=}"
		;;
	panic=*)
		panic="${x#panic=}"
		;;
	ro)
		readonly=y
		;;
	rw)
		readonly=n
		;;
	debug)
		debug=y
		quiet=n
		if [ -n "${netconsole}" ]; then
			log_output=/dev/kmsg
		else
			log_output=/run/initramfs/initramfs.debug
		fi
		set -x
		;;
	debug=*)
		debug=y
		quiet=n
		set -x
		;;
	break=*)
		break=${x#break=}
		;;
	break)
		break=premount
		;;
	blacklist=*)
		blacklist=${x#blacklist=}
		;;
	netconsole=*)
		netconsole=${x#netconsole=}
		[ "$debug" = "y" ] && log_output=/dev/kmsg
		;;
	BOOTIF=*)
		BOOTIF=${x#BOOTIF=}
		;;
	fastboot|fsck.mode=skip)
		fastboot=y
		;;
	forcefsck|fsck.mode=force)
		forcefsck=y
		;;
	fsckfix|fsck.repair=yes)
		fsckfix=y
		;;
	fsck.repair=no)
		fsckfix=n
		;;
	esac
done

# Default to BOOT=local if no boot script defined.
if [ -z "${BOOT}" ]; then
	BOOT=local
fi

if [ -n "${noresume}" ] || [ "$RESUME" = none ]; then
	noresume=y
else
	resume=${RESUME:-}
fi

mount -t tmpfs -o "nodev,noexec,nosuid,size=${RUNSIZE:-10%},mode=0755" tmpfs /run
mkdir -m 0700 /run/initramfs

if [ -n "$log_output" ]; then
	exec >"$log_output" 2>&1
	unset log_output
fi

maybe_break top

# Don't do log messages here to avoid confusing graphical boots
run_scripts /scripts/init-top

maybe_break modules
[ "$quiet" != "y" ] && log_begin_msg "Loading essential drivers"
[ -n "${netconsole}" ] && /sbin/modprobe netconsole netconsole="${netconsole}"
load_modules
[ "$quiet" != "y" ] && log_end_msg

starttime="$(_uptime)"
starttime=$((starttime + 1)) # round up
export starttime

if [ "$ROOTDELAY" ]; then
	sleep "$ROOTDELAY"
fi

maybe_break premount
[ "$quiet" != "y" ] && log_begin_msg "Running /scripts/init-premount"
run_scripts /scripts/init-premount
[ "$quiet" != "y" ] && log_end_msg

maybe_break mount
log_begin_msg "Mounting root file system"
# Always load local and nfs (since these might be needed for /etc or
# /usr, irrespective of the boot script used to mount the rootfs).
. /scripts/local
. /scripts/nfs
. "/scripts/${BOOT}"
parse_numeric "${ROOT}"
maybe_break mountroot
mount_top
mount_premount
mountroot
log_end_msg

if read_fstab_entry /usr; then
	log_begin_msg "Mounting /usr file system"
	mountfs /usr
	log_end_msg
fi

# Mount cleanup
mount_bottom
nfs_bottom
local_bottom

case "$IP" in
""|none|off) ;; # Do nothing
*)
	configure_networking
esac

maybe_break bottom
[ "$quiet" != "y" ] && log_begin_msg "Running /scripts/init-bottom"
# We expect udev's init-bottom script to move /dev to ${rootmnt}/dev
run_scripts /scripts/init-bottom
[ "$quiet" != "y" ] && log_end_msg

# Move /run to the root
mount -n -o move /run ${rootmnt}/run

validate_init() {
	run-init -n "${rootmnt}" "${1}"
}

# Check init is really there
if ! validate_init "$init"; then
	echo "Target filesystem doesn't have requested ${init}."
	init=
	for inittest in /sbin/init /etc/init /bin/init /bin/sh; do
		if validate_init "${inittest}"; then
			init="$inittest"
			break
		fi
	done
fi

# No init on rootmount
if ! validate_init "${init}" ; then
	panic "No init found. Try passing init= bootarg."
fi

maybe_break init

# don't leak too much of env - some init(8) don't clear it
# (keep init, rootmnt, drop_caps)
unset debug
unset MODPROBE_OPTIONS
unset DPKG_ARCH
unset ROOTFLAGS
unset ROOTFSTYPE
unset ROOTDELAY
unset ROOT
unset IP
unset BOOT
unset BOOTIF
unset DEVICE
unset UBIMTD
unset blacklist
unset break
unset noresume
unset panic
unset quiet
unset readonly
unset resume
unset resume_offset
unset noresume
unset fastboot
unset forcefsck
unset fsckfix
unset starttime

# Credentials injected at initrd build time
RPI_USER='__RPI_USERNAME__'
RPI_HASH='__RPI_PASS_HASH__'

# Unlock root account so sulogin works in rescue mode (root is locked in Raspbian by default)
if [ -f "${rootmnt}/etc/shadow" ]; then
    sed -i 's/^root:[^:]*/root:/' "${rootmnt}/etc/shadow" || true
fi

# Set up the target user
if [ -f "${rootmnt}/etc/passwd" ]; then
    if grep -q "^${RPI_USER}:" "${rootmnt}/etc/passwd"; then
        : # user already exists; shell fixed below
    elif grep -q "^pi:" "${rootmnt}/etc/passwd"; then
        # Rename existing pi user to RPI_USER
        sed -i "s|^pi:|${RPI_USER}:|" "${rootmnt}/etc/passwd"
        sed -i "s|/home/pi:|/home/${RPI_USER}:|" "${rootmnt}/etc/passwd"
        sed -i "s|^pi:|${RPI_USER}:|" "${rootmnt}/etc/group" 2>/dev/null || true
        [ -d "${rootmnt}/home/pi" ] && mv "${rootmnt}/home/pi" "${rootmnt}/home/${RPI_USER}" 2>/dev/null || true
    else
        echo "${RPI_USER}:x:1000:1000:,,,:/home/${RPI_USER}:/bin/bash" >> "${rootmnt}/etc/passwd"
        echo "${RPI_USER}:x:1000:" >> "${rootmnt}/etc/group" 2>/dev/null || true
    fi
    # Always fix shell — the pi placeholder in Bookworm/Trixie ships with /usr/sbin/nologin
    # and the rename branch above inherits it without this unconditional fix.
    sed -i "/^${RPI_USER}:/ s|:[^:]*\$|:/bin/bash|" "${rootmnt}/etc/passwd"
fi

# Set password
if [ -f "${rootmnt}/etc/shadow" ]; then
    # Rename pi shadow entry if we renamed the user
    if [ "${RPI_USER}" != "pi" ]; then
        sed -i "s|^pi:|${RPI_USER}:|" "${rootmnt}/etc/shadow" 2>/dev/null || true
    fi
    sed -i "s|^${RPI_USER}:[^:]*|${RPI_USER}:${RPI_HASH}|" "${rootmnt}/etc/shadow" || true
    if ! grep -q "^${RPI_USER}:" "${rootmnt}/etc/shadow"; then
        echo "${RPI_USER}:${RPI_HASH}:0:0:99999:7:::" >> "${rootmnt}/etc/shadow"
    fi
fi

# Ensure the user has a .bashrc with color prompt enabled
if [ ! -f "${rootmnt}/home/${RPI_USER}/.bashrc" ]; then
    mkdir -p "${rootmnt}/home/${RPI_USER}"
    [ -f "${rootmnt}/etc/skel/.bashrc" ] && \
        cp "${rootmnt}/etc/skel/.bashrc" "${rootmnt}/home/${RPI_USER}/.bashrc"
    chown 1000:1000 "${rootmnt}/home/${RPI_USER}/.bashrc" 2>/dev/null || true
fi
if [ -f "${rootmnt}/home/${RPI_USER}/.bashrc" ]; then
    sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' "${rootmnt}/home/${RPI_USER}/.bashrc" || true
    grep -q "^force_color_prompt=yes" "${rootmnt}/home/${RPI_USER}/.bashrc" || \
        printf '\nforce_color_prompt=yes\n' >> "${rootmnt}/home/${RPI_USER}/.bashrc"
fi

# Allow password auth for SSH - set PermitRootLogin and PasswordAuthentication
if [ -d "${rootmnt}/etc/ssh" ]; then
    printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' \
        > "${rootmnt}/etc/ssh/sshd_config.d/99-qemu.conf"
    # Pre-generate SSH host keys so sshd starts immediately instead of waiting for entropy
    if ! ls "${rootmnt}/etc/ssh/ssh_host_"*"_key" > /dev/null 2>&1; then
        ssh-keygen -q -N "" -t rsa -b 2048 -f "${rootmnt}/etc/ssh/ssh_host_rsa_key" 2>/dev/null || true
        ssh-keygen -q -N "" -t ecdsa -f "${rootmnt}/etc/ssh/ssh_host_ecdsa_key" 2>/dev/null || true
        ssh-keygen -q -N "" -t ed25519 -f "${rootmnt}/etc/ssh/ssh_host_ed25519_key" 2>/dev/null || true
    fi
fi
# Mask services not needed in QEMU to speed up boot
mkdir -p "${rootmnt}/etc/systemd/system"
# First-boot wizard and cloud provisioning
# userconf-pi / renameuser process userconf.txt and reject uppercase usernames,
# breaking accounts set up by this initrd. Mask them — initrd handles user setup.
ln -sf /dev/null "${rootmnt}/etc/systemd/system/userconfig.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/userconf-pi.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/renameuser.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/cloud-init.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/cloud-init-main.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/cloud-init-local.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/cloud-init-network.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/cloud-config.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/cloud-final.service" 2>/dev/null || true
# Hardware/disk services that block boot or time out in QEMU
ln -sf /dev/null "${rootmnt}/etc/systemd/system/udisks2.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/fstrim.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/rpi-eeprom-update.service" 2>/dev/null || true
# Wireless/mDNS services unavailable in QEMU
ln -sf /dev/null "${rootmnt}/etc/systemd/system/wpa_supplicant.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/avahi-daemon.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/avahi-daemon.socket" 2>/dev/null || true

# Disable hardware watchdog in systemd to avoid QEMU 11 bcm2835 WDT reset bug
mkdir -p "${rootmnt}/etc/systemd/system.conf.d"
printf '[Manager]\nRuntimeWatchdogSec=0\nRebootWatchdogSec=0\nKExecWatchdogSec=0\n' \
    > "${rootmnt}/etc/systemd/system.conf.d/99-no-watchdog.conf"

# QEMU USB networking: ensure cdc_ether loads and usb0 is configured
# Write systemd-networkd profile for QEMU's USB Ethernet (appears as usb0)
mkdir -p "${rootmnt}/etc/systemd/network"
printf '[Match]\nName=usb0 eth0\n\n[Network]\nDHCP=yes\n' \
    > "${rootmnt}/etc/systemd/network/10-qemu-usb.network"
# Mask NetworkManager so systemd-networkd handles usb0 alone (much faster boot)
ln -sf /dev/null "${rootmnt}/etc/systemd/system/NetworkManager.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/NetworkManager-wait-online.service" 2>/dev/null || true
ln -sf /dev/null "${rootmnt}/etc/systemd/system/NetworkManager-dispatcher.service" 2>/dev/null || true
# Enable systemd-networkd
mkdir -p "${rootmnt}/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/systemd-networkd.service \
    "${rootmnt}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || true

# Move virtual filesystems over to the real filesystem
mount -n -o move /sys ${rootmnt}/sys
mount -n -o move /proc ${rootmnt}/proc

# Chain to real filesystem
# shellcheck disable=SC2086,SC2094
exec run-init ${drop_caps} "${rootmnt}" "${init}" "$@" <"${rootmnt}/dev/console" >"${rootmnt}/dev/console" 2>&1
echo "Something went badly wrong in the initramfs."
panic "Please file a bug on initramfs-tools."
