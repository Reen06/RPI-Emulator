# RPI Emulator

Run any Raspberry Pi model in QEMU on a Linux machine — full boot, SSH access, and a terminal UI — with a single command.

```
rpi run
```

---

## Features

- **Full Pi OS boot** via QEMU — Raspberry Pi Zero, 1, 2, 3B, 3B+, 3A+, and 4B
- **Interactive TUI** — menu-driven image management, no flags required
- **Pi 4B support** — patched initramfs, USB OTG networking, watchdog fix, ~60s boot to SSH
- **LAN exposure** — optionally bind SSH to a LAN port so you can connect from any device on your network
- **Verbose boot** — `-v` flag streams the Pi's serial output while it boots
- **Color shell prompt** — green `pi@raspberrypi` prompt out of the box
- **Image management** — download, label, resize, and flash official Pi OS images
- **Persistent disks** — qcow2 disk per image; changes survive reboots
- **Port forwards** — configure per-image guest→host TCP port mappings
- **SSH helpers** — `rpi ssh`, `rpi exec`, `rpi put`, `rpi get`
- **Docker shell** — ARM64 shell inside any image without booting QEMU (`rpi shell`)
- **SD card flashing** — flash images directly to physical SD cards (`rpi flash`)

---

## Quick Start

```bash
git clone git@github.com:Reen06/RPI-Emulator.git
cd RPI-Emulator
./install
rpi download        # Download a Pi OS image
rpi run             # Boot it in QEMU and SSH in
```

### Requirements

| Feature | Requires |
|---|---|
| `rpi list/download` | `curl`, `wget`, `jq` |
| `rpi shell/exec/put/get` | `docker`, `fdisk` |
| `rpi run` (Pi 4B) | `qemu-system-arm` ≥ 11, `qemu-utils`, `fdisk`, `cpio`, `python3`, `ssh-keygen` |
| `rpi flash` | `lsblk`, `dd`, optionally `qemu-img` |
| `rpi resize` | `parted`, `resize2fs` |

Install QEMU on Ubuntu/Debian:
```bash
sudo apt install qemu-system-arm qemu-utils
```

---

## Usage

```
rpi                       Interactive menu
rpi list                  List local images and running VMs
rpi download              Download an official Pi OS image
rpi run [-v] [image]      Full QEMU boot + SSH
                            -v / --verbose  stream serial output during boot
rpi ssh [cmd...]          SSH to running VM (interactive or non-interactive)
rpi exec [image] <cmd>    Run a command non-interactively in the image
rpi put  [image] <src> <dst>   Copy a file into an image
rpi get  [image] <src> <dst>   Extract a file from an image
rpi shell [image]         ARM64 interactive shell via Docker (no QEMU)
rpi label <label> [image] Give an image a display name
rpi resize [image]        Grow the root partition by N GB
rpi ports [image]         Configure LAN port forwards
rpi machine [image]       Change the emulation target (Pi model)
rpi flash [image]         Flash image or qcow2 to an SD card
rpi stop [name]           Stop a running QEMU instance
rpi imager                Launch rpi-imager GUI
rpi help                  Full help text
```

---

## Default SSH credentials

| | |
|---|---|
| **User** | `pi` |
| **Password** | `raspberry` |
| **Local port** | `2222` |

Connect: `ssh -p 2222 pi@localhost`

---

## LAN Access

When you run `rpi run`, you'll be asked if you want to expose SSH on your LAN:

```
Expose SSH on LAN? Enter a port number >=1024 (or Enter to skip): 4222
  LAN SSH: ssh -p 4222 pi@192.168.1.42
```

Use any port ≥ 1024. The local port 2222 is always available too.

---

## Verbose Boot

```bash
rpi run -v
```

Or select **y** when the menu asks `Verbose boot output? [y/N]`. The Pi's serial output streams to your terminal so you can see exactly where it is if boot hangs.

---

## Pi 4B Notes

Pi 4B emulation uses the QEMU `raspi4b` machine and requires a real Pi OS image (the kernel and initramfs are extracted from the image's boot partition). The first run extracts and patches the initramfs automatically:

- Watchdog (`rpi_wd`) patched to no-op — QEMU 11's BCM2835 watchdog emulation reboots on any write
- USB OTG enabled in DTB for networking
- Services masked for fast boot: `cloud-init`, `NetworkManager`, `udisks2`, `wpa_supplicant`, and others
- SSH host keys pre-generated so sshd starts immediately
- `systemd-networkd` configured for `usb0` (QEMU USB Ethernet)

Expected boot time: ~60 seconds from QEMU start to SSH banner.

---

## File Layout

```
RPI-Emulator/
├── rpi                  Main CLI
├── rpi-wifi             WiFi emulation helper
├── rpi-bluetooth        Bluetooth emulation helper
├── install              Symlink installer (~/.local/bin)
├── lib/
│   ├── common.sh        Shared functions, machine table, Pi 4B initrd builder
│   ├── docker_exec.sh   Docker-based ARM64 execution helpers
│   └── pi4b-init-patch.sh  Patched initramfs /init for Pi 4B QEMU
└── configs/
    ├── machines.conf    Machine definitions
    ├── captive          Captive portal config
    └── hostapd          hostapd config
```

Images, disks, and kernels are stored outside the repo (excluded by `.gitignore`):

```
images/    *.img files
disks/     *.qcow2 persistent disks (one per image)
kernels/   Extracted kernel, initrd, DTB (one dir per image)
```

---

## Adding Port Forwards

```bash
rpi ports MyImage
```

Enter host:guest port pairs (e.g. `8080:80` to reach the Pi's web server at `localhost:8080`). Forwards persist across reboots of the VM.

---

## Changing Pi Model

```bash
rpi machine MyImage
```

Select a target from the list. Pi 4B requires kernel extraction from the image and builds a custom initramfs on first run.

---

## License

MIT
