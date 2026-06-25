# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A single-command toolkit for running Raspberry Pi OS images in QEMU on Linux, with full SSH access, persistent qcow2 disks, and Docker-based ARM64 access without booting QEMU. The primary scripts are `rpi`, `rpi-wifi`, and `rpi-bluetooth`. `./install` symlinks them into `~/.local/bin`.

The `ros-farino` image (Pi 4B, user `robotics`) is the active project image — it will host a ROS2 Jazzy workspace for controlling a Farino FR-3 robot arm over Ethernet.

## Common commands

```bash
./install                         # First-time setup: symlinks, apt deps, binfmt, QEMU version check

rpi list                          # Show local images and running VMs
rpi download                      # Download an official Pi OS image
rpi run [-v] [image]              # Full QEMU boot → SSH (Pi 4B ~60s to ready)
rpi shell [image]                 # ARM64 Docker chroot — instant, no QEMU (preferred for dev work)
rpi ssh [cmd...]                  # SSH to running QEMU VM
rpi exec [image] <cmd>            # Non-interactive command via Docker chroot
rpi put [image] <src> <dst>       # Copy file into image filesystem
rpi get [image] <src> <dst>       # Extract file from image filesystem
rpi stop [name]                   # Kill a running QEMU instance
rpi machine [image]               # Change emulation target (Pi model)
rpi ports [image]                 # Configure persistent port forwards
rpi flash [image]                 # Write image or qcow2 to a physical SD card
```

**Development workflow:** use `rpi shell` (Docker chroot) for all installation, file writes, and builds — it is near-instant. Reserve `rpi run` (QEMU) only for verifying boot behavior and systemd service startup.

## Architecture

### Script layout

```
rpi                  Main CLI (~1400 lines); sources lib/common.sh and lib/docker_exec.sh
lib/common.sh        Shared vars (IMAGES_DIR, DISKS_DIR, etc.), machine table, Pi 4B initrd builder
lib/docker_exec.sh   docker_chroot_run(): mounts image via losetup, chroots via Docker ARM64
lib/pi4b-init-patch.sh  Template for the patched initramfs /init injected at Pi 4B first-run
configs/             Per-image state files (see below)
images/              *.img files (gitignored)
disks/               *.qcow2 persistent overlay disks (gitignored, one per image)
kernels/             Extracted kernel/DTB/initrd per image (gitignored)
```

### Image identity: the slug

Every image-level state is keyed on a **slug** derived from the filename:
- `label__original-name.img` → slug `label` (the part before `__`)
- `plain-name.img` → slug `plain-name`

The slug is the key for `configs/<slug>.creds`, `configs/<slug>.machine`, `configs/<slug>.ports`, `disks/<slug>.qcow2`, `kernels/<slug>/`.

### Per-image config files (`configs/`)

| File | Format | Purpose |
|------|--------|---------|
| `<slug>.creds` | `USER=…\nPASS=…` | Login credentials injected at Pi 4B initrd build time |
| `<slug>.machine` | single key, e.g. `pi4b` | Which machine table entry to use |
| `<slug>.ports` | `host:guest` lines | Extra QEMU port forwards |

### Machine table (`lib/common.sh:_MACHINE_TABLE`)

Pipe-delimited: `key|display|qemu_bin|qemu_machine|cpu|ram|kernel|dtb`

Built-in entries cover pi0 through pi5b. `configs/machines.conf` adds custom entries in the same format (useful when QEMU gains new Pi model support).

### Pi 4B special path

Pi 4B is the only model with custom initramfs handling. On first `rpi run` for a Pi 4B image, `lib/common.sh` extracts the kernel and DTB from the image's boot partition, patches the DTB (`fdtput` or `python3-fdt`) to enable USB OTG for networking, and builds a custom initrd from `lib/pi4b-init-patch.sh` with credentials and hostname injected as `__RPI_USERNAME__` / `__RPI_PASS_HASH__` placeholders. The patched initrd disables the BCM2835 watchdog (crashes QEMU 11), masks services that slow boot, and configures `systemd-networkd` for `usb0`.

### Docker chroot (`lib/docker_exec.sh`)

`docker_chroot_run <img> <interactive> <network_mode> [cmd...]` mounts the `.img` via `losetup --partscan` (both partitions from one loop device), bind-mounts `/proc /sys /dev`, then runs `docker run --platform linux/arm64` with the mount as the rootfs. Cleanup (umount + losetup -d) runs via `trap EXIT`. This is how `rpi shell`, `rpi exec`, `rpi put`, and `rpi get` work — no QEMU needed.

## ros-farino: Farino FR-3 robot control image

The `ros-farino` image (Pi 4B, user `robotics`, pass `farino`) is the active project image. It hosts a ROS2 Jazzy workspace for controlling a Farino FR-3 robot arm connected over Ethernet (robot at **192.168.57.2** — reconciled from the live Pi 2026-06-24; originally documented as 192.168.58.2 on a direct cable).

> **Live-Pi reconciliation (2026-06-24):** The flashed Pi required on-Pi tweaks to get robot communication working, now folded back into this repo. Key fix in `farino_client.py:connect()`: the Fairino SDK's `is_connect` flag stays False on this firmware (XML-RPC on port 20004 vs 20005/CNDE), so a direct XML-RPC probe on port 20003 + forcing `RPC.is_connect = True` is required before any command. Robot IP moved to 192.168.57.2. Pi networking is dual-homed/in-flux (see `setup/02_configure_network.sh` note). Remote access to the live Pi is a two-hop SSH bridge — documented separately in `docs/remote-access.md`.

**Provisioning** (runs once, uses Docker chroot — no QEMU needed):
```bash
./setup/provision.sh ros-farino
```

**Verify after provisioning** (Docker chroot, fast):
```bash
rpi exec ros-farino bash -c "source /opt/ros/jazzy/setup.bash && ros2 --version"
rpi exec ros-farino bash -c "FARINO_DRY_RUN=1 source /opt/ros/jazzy/setup.bash && source /home/robotics/ros2_ws/install/setup.bash && ros2 run farino_wave wave_node"
```

**Flash to real Pi** (after provisioning verified):
```bash
rpi flash ros-farino
```

**Wave node** (`ros2_ws/src/farino_wave/`):
- `farino_client.py` — wraps Fairino Python SDK; falls back to dry-run if SDK unavailable
- `wave_node.py` — regular ROS2 node: enables robot, runs joint wave loop, safety thread polls `GetRobotErrorCode()` at 10 Hz and stops on non-zero
- `FARINO_DRY_RUN=1` skips SDK connect, logs planned moves — use for emulator testing
- The systemd service `farino-wave.service` auto-starts on boot (enabled by provision.sh)

**Setup scripts** (`setup/`):
- `01_install_ros2_jazzy.sh` — adds ROS2 Jazzy apt repo (noble packages on Trixie arm64) and installs `ros-jazzy-ros-base`
- `02_configure_network.sh` — writes `/etc/systemd/network/20-robot-eth.network` for eth0 static IP
- `03_setup_service.sh` — writes and enables `farino-wave.service`
- `provision.sh` — master script: tarballs `ros2_ws/src` and `docs/`, puts them in the image via `rpi put`, runs scripts via `rpi exec`

**Pi-side docs** installed at `/home/robotics/plans/` on the Pi:
- `architecture.md` — network layout, joint sequence table, ROS2 interface, useful commands
- `future-isaac-lab.md` — Phase 2 plan: TorchScript policy inference node + MoveIt2 integration

## Key implementation notes

- `qemu-img` is called via a wrapper function that falls back to `docker run ubuntu:24.04` if `qemu-img` is not installed locally.
- QEMU is started daemonized; a PID file is written to `/tmp/rpi-<slug>.pid`. `rpi stop` uses these to find and kill instances.
- SSH readiness is polled by attempting a socket connection to `localhost:2222` in a loop (300 s timeout).
- Image naming is intentionally preserved: `rpi label` renames `.img`, `.qcow2`, kernel dir, and all config files atomically to keep the slug consistent.
- `configs/Default.machine` sets the default machine used when no `<slug>.machine` file exists.
