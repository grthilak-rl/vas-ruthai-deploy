# Switching project server TCP congestion control to BBR

Operational runbook for the architect to execute on the project-server **host**
(not inside any container). This change improves HTTP throughput between the
project server (`10.40.128.10`) and the operator subnet (`10.1.1.0/24`) when
the path is lossy, which is the current observed condition.

## 1. Why

Diagnostic on 2026-06-02 found that TCP sockets from the project server to the
operator have:

- ~200 ms RTT (`minrtt: 203-208 ms` per `ss -tin`)
- ~1.0-1.5% sustained retransmission rate
- Congestion window stuck at **10-24 segments** under CUBIC, far below the
  bandwidth-delay product the path could otherwise support

CUBIC reacts to every loss event by halving `cwnd` and re-entering slow start,
which works for short-RTT congestion but performs poorly on long-RTT paths
with low-rate random loss. On this path, CUBIC tops out near **60 KB/s per
socket**; aggregate effective throughput to a single operator hovers at
150-200 KB/s — barely enough for the 1 Mbps bookmark video target bitrate,
and below it on every packet-loss spike.

BBR (Bottleneck Bandwidth and Round-trip propagation time) models the actual
path bandwidth and RTT independently of loss. Random loss does not collapse
its sending rate. On a 200 ms RTT path with 1.5% loss, BBR typically
sustains 5-10× CUBIC's throughput, often filling the bottleneck-link's true
capacity.

This change benefits **all HTTP traffic** from the project server to the
operator subnet (bookmark video, API responses, recordings, OpenAPI), not
just bookmark playback. **UDP traffic — including WebRTC media — is
unaffected**, because UDP has no congestion control algorithm.

## 2. Check current value

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
```

Expected current values:

- `net.ipv4.tcp_congestion_control = cubic` (Ubuntu/Debian default)
- `net.ipv4.tcp_available_congestion_control = reno cubic …`

If `bbr` does **not** appear in the available list, load the kernel module
and persist it across reboots:

```bash
sudo modprobe tcp_bbr
echo 'tcp_bbr' | sudo tee /etc/modules-load.d/bbr.conf
```

Re-check `tcp_available_congestion_control` — `bbr` should now be in the
list. The module is part of every mainline kernel ≥ 4.9, so this should
succeed on any modern Ubuntu/Debian host.

## 3. Apply (non-persistent, runtime only)

Use this first to verify the effect without persisting across reboots:

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
sudo sysctl -w net.core.default_qdisc=fq
```

`fq` (fair queueing) is BBR's recommended pacing qdisc. Without `fq`, BBR
still works but doesn't pace as smoothly, which can produce small jitter on
the operator side. Setting it costs nothing.

These changes apply to **new TCP connections only**. Sockets established
before the change keep CUBIC until they reconnect.

## 4. Verify

Confirm the kernel parameters:

```bash
sysctl net.ipv4.tcp_congestion_control     # expected: bbr
sysctl net.core.default_qdisc              # expected: fq
```

Confirm new sockets are using BBR. After the sysctl takes effect, any newly
opened TCP socket from the project server appears in `ss -ti` with a `bbr`
entry on the per-socket info line (CUBIC sockets show `cubic` there):

```bash
ss -tin state established 'dst 10.1.1.214' | grep -E '(bbr|cubic)' | head
```

Expected output mixes `bbr` (new) and `cubic` (existing) until the latter
reconnect. Bookmark playback opened after the sysctl change will use BBR
from the first byte.

To force a cleaner picture, trigger a fresh playback session from an
operator after the change — the new `<video>` Range requests will all be on
BBR sockets.

## 5. Persist across reboots

Create `/etc/sysctl.d/99-vas-tcp-bbr.conf` with the following exact contents:

```ini
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
```

Apply (this is idempotent — safe to re-run):

```bash
sudo sysctl -p /etc/sysctl.d/99-vas-tcp-bbr.conf
```

Confirm reload:

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

If you also added the `modprobe` step in section 2, the kernel module
auto-loads on boot via `/etc/modules-load.d/bbr.conf`, so the sysctl will
have BBR available at startup.

## 6. Rollback procedure

Runtime rollback (immediate, no service disruption — existing BBR sockets
finish their lifetime on BBR, new sockets open on CUBIC):

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
sudo sysctl -w net.core.default_qdisc=fq_codel
```

Persistent rollback:

```bash
sudo rm /etc/sysctl.d/99-vas-tcp-bbr.conf
```

If you also want to remove the module auto-load (rarely needed — the module
is harmless when not selected):

```bash
sudo rm /etc/modules-load.d/bbr.conf
```

No container restart, no service restart, no operator-visible disruption at
any step. If something goes wrong, you can revert without touching VAS or
Ruth at all.

## 7. Expected improvement

On the current path (~200 ms RTT, ~1.5% loss):

| Algorithm | Effective throughput per socket | Bookmark 1 Mbps playback |
|---|---|---|
| **CUBIC** (current) | ~60 KB/s | stutters every ~1 s |
| **BBR** (expected) | 300-600+ KB/s | smooth, well above the 125 KB/s real-time rate |

If the bottleneck-link's actual capacity is higher than 1 Mbps per flow, BBR
will fill that capacity. If the bottleneck is a hard rate limit at the
edge, BBR will track it. In either case, the per-socket throughput becomes
limited by the *path* rather than by CUBIC's loss reaction.

Confirm in DevTools after the change: bookmark Range responses that
currently take 30-180 seconds should drop to a few seconds for the same
byte count.

## 8. What this does not fix

- **The underlying packet loss.** That's still a network/IT issue between
  the project-server site and the operator site (VPN tunnel, ISP, MTU
  clamping — under investigation in a separate work stream).
- **UDP / WebRTC.** TCP congestion control does not apply. Live stream
  fan-out via MediaSoup runs on UDP and behaves the same before and after.
- **Bookmark video architecture.** Switching bookmark playback to HLS
  segmentation (matching live and historical streams) would be inherently
  more robust on lossy paths because each segment is a fresh short-lived
  TCP connection. This is a deferred architectural improvement; the BBR
  change is the small, reversible operational win that costs nothing while
  the network work happens.

## 9. Related work

- Bookmark video token TTL raised from 5 to 30 minutes
  (`vas-ms-v2/backend/app/services/auth_service.py`,
  branch `fix/bookmark-video-token-ttl-30min`). Independent of BBR but
  ships in the same operational window — together they remove both
  symptoms (mid-playback 403s and slow Range transfers) without touching
  the underlying network path.
