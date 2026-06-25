#!/usr/bin/env bash
# Configure static IP on eth0 for the FR-3 robot control box connection.
# Run inside the Pi via:  rpi exec ros-farino bash /tmp/02_configure_network.sh
#
# RECONCILIATION NOTE (2026-06-24, from the live robot Pi):
#   The working robot is now reached at 192.168.57.2 (not 192.168.58.2), on the
#   upstream LAN. On the live Pi, eth0 is dual-homed: this static 192.168.58.100
#   PLUS a DHCP 192.168.57.100 from NetworkManager ("Wired connection 1"), and
#   the robot answers on the .57 subnet. ROBOT_IP in farino_client.py was updated
#   to 192.168.57.2 to match. This script was left as-is (still writes .58.100) —
#   networking on the live Pi is in flux; revisit before re-flashing.
#
# Network layout:
#   eth0  → 192.168.58.100/24  (direct cable to FR-3 control box at 192.168.58.2)
#   usb0  → DHCP               (QEMU USB Ethernet for SSH during emulation)
#
# usb0 is already configured by the Pi 4B initramfs patcher — leave it alone.
set -euo pipefail

NETD=/etc/systemd/network

echo "=== Configuring eth0 static IP (192.168.58.100/24) ==="

cat > "$NETD/20-robot-eth.network" <<'EOF'
[Match]
Name=eth0

[Network]
Address=192.168.58.100/24

[Link]
RequiredForOnline=no
EOF

echo "=== Verifying systemd-networkd is enabled ==="
systemctl enable systemd-networkd 2>/dev/null || true

echo "=== Network configuration written to $NETD/20-robot-eth.network ==="
echo "    eth0 will get 192.168.58.100/24 on real Pi boot."
echo "    In the QEMU emulator, eth0 does not exist; usb0 handles SSH."
