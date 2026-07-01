# Farino FR-3 — Generic ROS2 Control Structure (Implementation Spec)

> **For any coding agent/wrapper:** this is a self-contained spec. Implement it as
> written. Development happens **directly on the live Pi over the travel-router
> SSH bridge** (see `docs/remote-access.md`); edit/build/run in `~/ros2_ws` on the
> Pi. The QEMU/Docker-chroot emulator (`rpi exec`/`rpi shell`) is a fallback only
> if a step is clearly easier offline. No SD-card flashing required.

## 1. Context & goal

Today the only thing that drives the arm is `farino_wave`, a hard-coded wave
demo. There is no general way to **command** the FR-3 over ROS2. Build a
**generic, reusable control node** — **no neural net, no learned policy** — that
exposes standard robot-control interfaces (command in, joint feedback out,
lifecycle services). This becomes the single control surface that anything can
drive: a manual publisher, RViz/MoveIt2, Isaac Sim's ROS2 bridge, or a future
policy node — all with **no changes to this node**.

Project knowledge base:
`/home/control/Obsidian-Frogmouth/Farino-FR3-RPI-KnowledgeBase/`.

## 2. What exists already (reuse, don't reinvent)

- `ros2_ws/src/farino_wave/farino_wave/farino_client.py` — `FarinoClient`, a
  dry-run-aware wrapper over the Fairino Python SDK. Already wraps `connect()`
  (with the port-20003 XML-RPC probe + `is_connect=True` force), `enable()`,
  `disable()`, `stop_motion()`, `move_j()`, `is_estop_or_collision()`.
- `ros2_ws/src/farino_wave/farino_wave/wave_node.py` — the safety-thread pattern
  to copy (`_safety_loop`, 10 Hz `is_estop_or_collision()` → `stop()`).
- Fairino SDK at `ros2_ws/fairino_sdk/Robot.py`. Relevant methods (verified):
  - `GetActualJointPosDegree(flag=1)` → `(0, [j1..j6])` on success, or bare
    `error` int on failure (handle both shapes defensively).
  - `GetActualJointSpeedsDegree(flag=1)` → `(0, [j1..j6])` (deg/s).
  - `ServoJ(joint_pos, axisPos, acc=0, vel=0, cmdT=0.008, filterT=0, gain=0, id=0, cmdType=0)`
    — real-time joint servo; `axisPos` = external-axis list (pass `[0,0,0,0]`),
    `cmdType=0` = XML-RPC (same transport already in use).
  - `MoveJ(...)`, `StopMotion()`, `GetRobotErrorCode()` — already wrapped.
- Robot IP: **192.168.57.2**, command transport XML-RPC on **port 20003**.

## 3. Deliverable: new package `farino_control`

ament_python package alongside `farino_wave`, mirroring its layout. **No custom
`.msg`** — standard message types only, so it stays pure Python.

```
ros2_ws/src/farino_control/
  farino_control/__init__.py
  farino_control/control_node.py
  resource/farino_control
  package.xml          # exec_depend: rclpy std_msgs std_srvs sensor_msgs
                       #              trajectory_msgs farino_wave
  setup.py             # entry_point: arm_control_node = farino_control.control_node:main
  setup.cfg
```

Reuse the client via `from farino_wave.farino_client import FarinoClient` (same
import the planned `policy_node` uses in `docs/future-isaac-lab.md`), hence the
`farino_wave` exec-depend.

## 4. Extend `farino_wave/farino_client.py`

Add these **dry-run-aware** methods/constants next to the existing ones (leave
`WAVE_*`, `move_j`, `connect`, `enable`, `disable`, `stop_motion`,
`is_estop_or_collision` unchanged):

- `JOINT_NAMES = ["j1","j2","j3","j4","j5","j6"]`
- `HOME_POSE = [0, -90, 90, 0, 90, 0]` (degrees; matches the wave `home` pose)
- `read_joints() -> list[float] | None` — wraps `GetActualJointPosDegree(1)`;
  defensive about the `(err,[..])`-vs-bare-`err` return (mirror the guard in
  `is_estop_or_collision`). **Dry-run:** return the last servo/`move_j` target
  (or `HOME_POSE`) so `/joint_states` still publishes.
- `read_joint_speeds() -> list[float] | None` — wraps
  `GetActualJointSpeedsDegree(1)` (optional; for `JointState.velocity`).
- `servo_j(joints, cmdT=0.008)` — wraps `ServoJ(joints, [0,0,0,0], cmdT=cmdT)`.
  **Dry-run:** store as last target, rate-limit logging (no spam at 125 Hz).
- `home()` — blocking `MoveJ(HOME_POSE, ..., blendT=-1)` (reuse `move_j`).

## 5. Node: `arm_control_node` (`control_node.py`)

State model: `DISABLED → ENABLED (holding) → SERVO (streaming)`, plus
`STOPPED`/`ERROR`. **Does not move on boot** (`auto_enable` defaults False).

### ROS2 interface (node namespace `arm_control_node`)

| Name | Type | Dir | Behavior |
|------|------|-----|----------|
| `~/joint_command` | `sensor_msgs/JointState` | sub | Updates the servo-loop target → `ServoJ` (continuous real-time control; Isaac-teleop path) |
| `~/joint_trajectory` | `trajectory_msgs/JointTrajectory` | sub | Executed as a sequence of blended `MoveJ` (discrete point-to-point) |
| `/joint_states` | `sensor_msgs/JointState` | pub | Live feedback @ `publish_rate_hz` from `read_joints()` (digital-twin / closed-loop source) |
| `~/status` | `std_msgs/String` | pub | `disabled` / `enabled` / `servo` / `stopped: …` / `error: …` |
| `~/enable` | `std_srvs/Trigger` | srv | `connect()` + `enable()`; seed servo target = current joints (no jump) |
| `~/disable` | `std_srvs/Trigger` | srv | `disable()` |
| `~/home` | `std_srvs/Trigger` | srv | Blocking `MoveJ` to `HOME_POSE` |
| `~/stop` | `std_srvs/Trigger` | srv | `StopMotion()` + `disable()` |

### Threads (copy the `wave_node.py` pattern)

- **servo loop** @ `servo_rate_hz` (default 125 Hz): when `ENABLED`/`SERVO`, call
  `client.servo_j(target)` each tick. `target` is seeded to current joints on
  enable and updated by `~/joint_command`. Clamp the per-tick change to
  `max_joint_step_deg` so a stale/garbage command (or an Isaac dropout) cannot
  cause a large jump. Hold last target when no new command arrives.
- **safety loop** @ 10 Hz: `client.is_estop_or_collision()` → `stop()`
  (reuse existing logic verbatim).

### Units

ROS convention is **radians** for `JointState`; the SDK uses **degrees**. Convert
both ways. Param `command_units` (`radians` default, or `degrees`) controls the
command/feedback topics.

### Parameters

`robot_ip` (`192.168.57.2`), `auto_enable` (False), `servo_rate_hz` (125),
`publish_rate_hz` (50), `max_joint_step_deg` (5), `command_units` (`radians`),
`home_pose` (defaults to `HOME_POSE`).

## 6. Build & deploy

- **`ros2_ws/Dockerfile`** (line ~20): build both packages —
  `colcon build --packages-select farino_wave farino_control --symlink-install`
  (keeps the emulator image / repo in sync; not required for live Pi dev).
- **`setup/provision.sh`** already tarballs `ros2_ws/src`, so the new package
  ships automatically on re-provision — just confirm it builds.
- **Systemd:** add `setup/04_setup_control_service.sh` writing
  `farino-control.service` (same shape as `setup/03_setup_service.sh`) but
  **disabled by default** — `farino-wave` and `farino-control` both drive the
  same robot, so only one runs at a time. Document the switch:
  `systemctl disable --now farino-wave && systemctl enable --now farino-control`.
- **Docs/KB:** add a `Farino-FR3-RPI-KnowledgeBase/ROS2 farino_control Package.md`
  note linking `[[ROS2 farino_wave Package]]`, `[[Fairino SDK Integration]]`,
  `[[Future - Isaac Lab Policy]]`; update `00 - Farino FR-3 Index.md` and the
  ROS2-interface table in `docs/architecture.md`.

## 7. Network topology (critical for the Isaac hand-off — NOT for the node code)

Isaac Sim and the Pi are on **completely separate networks**, joined only by
multi-hop VPN tunnels — there is no flat L2/L3 between them:

```
[FR-3 arm] ──LAN 192.168.57.x── [Raspberry Pi] ──Wi-Fi── [travel router]
                                                              │ WireGuard tunnel
                                                              ▼
                                                       [home VPN box] ── same LAN ── [dev machine]
                                                              ▲
                                                              │  (separate path)
                              [Isaac Sim server] ──VPN──► [school Wi-Fi network]
```

Implications for the eventual Isaac↔Pi link (handled as a **separate** follow-up,
no control-node code changes):

- **Default DDS discovery won't work.** Fast DDS / Cyclone use **multicast**
  (SPDP) for discovery, which does not cross subnets/NAT/WireGuard. Matching
  `ROS_DOMAIN_ID` alone is insufficient across these hops.
- **Transport options** (choose during Isaac integration):
  1. **zenoh bridge** (`zenoh-bridge-ros2dds` / `rmw_zenoh`) — tunnels ROS2 over a
     single routable TCP connection; cleanest for NAT/VPN/WAN. **Recommended.**
  2. **Fast DDS Discovery Server** — `ROS_DISCOVERY_SERVER` on both ends pointing
     at one reachable unicast rendezvous IP.
  3. CycloneDDS with an explicit unicast **Peers** list.
- **High latency/jitter** over the multi-hop VPN makes a 125 Hz hard servo stream
  from Isaac across the WAN unrealistic. This is exactly why the control loop
  lives **on the Pi**: Isaac sends sparser/lower-rate targets across the WAN, and
  the Pi-side servo loop (holds last target, runs locally at `servo_rate_hz`,
  clamps per-tick step) smooths/interpolates them next to the robot. The node is
  already designed to tolerate this.

**Isaac hand-off (later):** point Isaac's ROS2-bridge `Publish Joint State` at
`~/joint_command` and `Subscribe Joint State` at `/joint_states`; configure one
transport option above on both ends. No node code changes.

## 8. Verification

All on the Pi over the SSH bridge, in `~/ros2_ws`.

**1. Build:**
```bash
cd ~/ros2_ws
source /opt/ros/jazzy/setup.bash
colcon build --packages-select farino_wave farino_control
source install/setup.bash
```

**2. Dry-run lifecycle (no robot motion):**
```bash
FARINO_DRY_RUN=1 ros2 run farino_control arm_control_node &
ros2 topic echo /joint_states                      # feedback streams
ros2 service call /arm_control_node/enable std_srvs/srv/Trigger
ros2 topic pub --once /arm_control_node/joint_command sensor_msgs/msg/JointState \
  '{name: [j1,j2,j3,j4,j5,j6], position: [0,-1.57,1.57,0,1.57,0]}'   # logs ServoJ target
ros2 service call /arm_control_node/home std_srvs/srv/Trigger
ros2 service call /arm_control_node/stop std_srvs/srv/Trigger
```
Confirm: `/joint_states` streams; `~/status` goes disabled→enabled→servo→stopped;
a large jump command logs a clamped step.

**3. Live arm (robot connected):** `systemctl stop farino-wave` first, run
`arm_control_node` (no dry-run), call `~/enable`, publish a **small**
`~/joint_command` delta, verify the arm follows smoothly and `/joint_states`
tracks the real encoders. Keep e-stop in reach; start with a low
`max_joint_step_deg`.
