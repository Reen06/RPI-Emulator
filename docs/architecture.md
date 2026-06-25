# Farino FR-3 ROS2 Control — Architecture

Installed at: `/home/robotics/plans/architecture.md`

## System Layout

```
Raspberry Pi 4B  (this device)
  eth0 → 192.168.57.100 (DHCP, upstream LAN) + 192.168.58.100/24 (static)
         robot now reached on the .57 subnet — see reconciliation note below

  ~/ros2_ws/src/farino_wave/
    wave_node.py        ← main node (auto-starts via systemd)
    farino_client.py    ← SDK wrapper / dry-run fallback

  ~/fairino_sdk/        ← Fairino Python SDK (fairino/ package + libfairino/)
  ~/plans/              ← this documentation

  systemd: farino-wave.service

  ─── Ethernet cable ──────────────────────────────────
  FR-3 Control Box   192.168.57.2   TCP port 20003 (XML-RPC command)
```

> **Reconciled from the live robot Pi on 2026-06-24.** Communication required
> on-Pi tweaks not present in the original push. See "Robot Connection" below.

## ROS2 Interface

| Topic / Service        | Type                  | Description                         |
|------------------------|-----------------------|-------------------------------------|
| `/wave_node/status`    | `std_msgs/String`     | Current state: waving / stopped / error |
| `/wave_node/stop`      | `std_srvs/Trigger`    | Stop the wave loop gracefully       |

## Robot Connection

The Farino FR-3 uses the **Fairino Python SDK** (`Robot.RPC('192.168.57.2')`).
The SDK is pure Python (xmlrpc + ctypes), so no arm64 binaries are needed.

**Communication fix (reconciled from the live Pi, 2026-06-24):** the SDK's
internal `is_connect` flag stayed `False` on this robot's firmware — older
firmware exposes XML-RPC on port **20004** instead of **20005** (CNDE). Because
the SDK's `@xmlrpc_timeout` decorator gates *every* call on `is_connect`, all
commands silently failed. `farino_client.connect()` now:

1. Creates `_FairinoRPC.RPC(ip)` as usual.
2. Directly probes XML-RPC on **port 20003** (`ServerProxy(...).GetControllerIP()`,
   3 s socket timeout).
3. On success, **forces `_FairinoRPC.RPC.is_connect = True`** so the decorator
   lets commands through; on failure logs `XML-RPC probe failed` and returns False.

`is_estop_or_collision()` was also hardened to tolerate a non-tuple return from
`GetRobotErrorCode()` when the RPC link is not fully up.

If the SDK import fails or `FARINO_DRY_RUN=1`, the node logs a warning and runs
in dry-run mode (motion commands are logged, not executed).

## Wave Sequence

Joint positions in degrees for a 6-DOF wrist wave (tune for your installation):

| Step       | J1 | J2  | J3  | J4  | J5 | J6 |
|------------|-----|-----|-----|-----|----|----|
| home       | 0  | -90 | 90  | 0   | 90 | 0  |
| raise      | 0  | -60 | 80  | 0   | 70 | 0  |
| wave right | 0  | -60 | 80  | +25 | 70 | 0  |
| wave left  | 0  | -60 | 80  | -25 | 70 | 0  |
| (×3 wave)  |    |     |     |     |    |    |
| home       | 0  | -90 | 90  | 0   | 90 | 0  |

Speed: 30%, blending: 150 ms. Adjust in `farino_client.py:WAVE_SEQUENCE`.

## Collision Safety

- `SetAnticollision(3)` — level 3 (1=soft, 10=hard); set in `farino_client.py`
- `SetCollisionStrategy(0)` — robot stops automatically on collision
- Safety thread polls `GetRobotErrorCode()` at 10 Hz; non-zero → stop

## Useful Commands

```bash
# Check wave node logs
journalctl -u farino-wave -f

# Stop / start the service
systemctl stop farino-wave
systemctl start farino-wave

# Manual dry-run test (no robot needed)
FARINO_DRY_RUN=1 ros2 run farino_wave wave_node

# Stop wave via ROS2 service
ros2 service call /wave_node/stop std_srvs/srv/Trigger

# Watch status topic
ros2 topic echo /wave_node/status
```

## File Locations

| Path | Purpose |
|------|---------|
| `~/ros2_ws/src/farino_wave/` | ROS2 package source |
| `~/ros2_ws/install/farino_wave/` | Built package |
| `~/fairino_sdk/` | Fairino Python SDK |
| `~/plans/` | This documentation |
| `/etc/systemd/network/20-robot-eth.network` | eth0 static IP config |
| `/etc/systemd/system/farino-wave.service` | Systemd service unit |
