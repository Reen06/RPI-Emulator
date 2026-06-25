# Remote Access — SSH Bridge to the Live Robot Pi

How to reach the running `ros-farino` robot Pi from the home control machine.
The Pi is **not directly reachable** — it sits on a remote LAN behind a travel
router. Access is a two-hop SSH bridge.

## Topology

```
control PC ──WireGuard (route to 10.79.114.0/24 via pivpn gateway 10.0.0.177)──►
  Sand-OS travel router  "Roku-E8C3"  (Pi Zero 2 W)
    wg0 = 10.79.114.4   user: gateway   key: ~/.ssh/rpi-zero-claude
    wlan1 (upstream Wi-Fi client) = 192.168.57.0/24
      └──► robot Pi  192.168.57.100   user: robotics
```

The travel router's upstream Wi-Fi (`wlan1`) joins the same `192.168.57.0/24`
LAN as the robot Pi, so it works as an SSH jump host.

## One-time setup (`~/.ssh/config` on the control PC)

```sshconfig
# Sand-OS Pi Zero 2 W travel router (jump host)
Host sand-gateway
    HostName 10.79.114.4
    User gateway
    IdentityFile ~/.ssh/rpi-zero-claude
    IdentitiesOnly yes

# ros-farino robot Pi, bridged through the travel router
Host robot-pi
    HostName 192.168.57.100
    User robotics
    ProxyJump sand-gateway
    IdentityFile ~/.ssh/rpi-zero-claude
    StrictHostKeyChecking accept-new
```

The `rpi-zero-claude` public key must be in `authorized_keys` for `gateway` on
the travel router **and** for `robotics` on the robot Pi.

## Connect

```bash
ssh sand-gateway          # the travel router itself
ssh robot-pi              # the robot Pi (auto-jumps through sand-gateway)
```

## Inspecting the running wave node (it runs in Docker)

The ROS2 code runs inside the `farino-wave` container, not on the host:

```bash
ssh robot-pi 'docker ps'                                   # confirm container up
ssh robot-pi 'docker logs --tail 50 farino-wave'           # node logs
ssh robot-pi 'systemctl status farino-wave'                # service status
# read the live source baked into the image:
ssh robot-pi 'docker exec farino-wave cat /ros2_ws/src/farino_wave/farino_wave/farino_client.py'
```

## Notes

- If `ssh robot-pi` fails at the second hop, check that sshd is running on the
  robot Pi (`ssh sand-gateway 'ssh robotics@192.168.57.100 hostname'`).
- WireGuard IPs `10.79.114.4` and `10.79.114.5` are the **same** travel-router
  box (two tunnels); use `.4`.
- The Sand-OS travel router has its own toolkit/docs at
  `/home/control/Sand OS Remote/` (see `docs/SSH & Remote Access.md`).
