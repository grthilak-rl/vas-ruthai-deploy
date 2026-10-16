# Deployment Guide — VAS + Ruth AI Integrated Stack

**Deploy by reading this one page.** Copy-paste the Quick Deploy blocks
top to bottom. Everything below Quick Deploy is reference — only read it
if a step fails.

---

## Quick Deploy

> Run everything from `vas-ruthai-deploy/`. Replace `10.40.128.10` with
> **your host's LAN IP** (the address browsers reach this host on — run
> `ip -4 addr show` if unsure). Pick the **GPU** or **CPU** bring-up line
> in step 4; everything else is identical.

### 1. Clone the three repos as siblings

```bash
mkdir -p /opt/ruthai && cd /opt/ruthai
git clone <VAS_REPO_URL>    vas-ms-v2
git clone <RUTH_REPO_URL>   ruth-ai-vas-ms-v2
git clone <DEPLOY_REPO_URL> vas-ruthai-deploy
cd vas-ruthai-deploy
```

### 2. Get the model weights (~837 MB, gitignored)

```bash
# Copy from an existing deployment. Source path + creds: see
# ../ruth-ai-vas-ms-v2/WEIGHTS.md
rsync -av --progress user@SOURCE_HOST:/home/project/ruth-ai-vas-ms-v2/ai/yolov8n.pt   ../ruth-ai-vas-ms-v2/ai/
rsync -av --progress user@SOURCE_HOST:/home/project/ruth-ai-vas-ms-v2/ai/models/      ../ruth-ai-vas-ms-v2/ai/models/

# Verify: expect 16
find ../ruth-ai-vas-ms-v2/ai -name "*.pt" | wc -l
```

(Skip only if you just want the `tank_overflow_monitoring` demo — it needs
no weights. All other models return zero detections without them.)

### 2b. Create the host storage directories (uid 1000)

Both are bind-mounted into the Ruth backend, which runs as `appuser`
(uid 1000). Each failure is contained to one feature rather than the
stack — but both fail *silently from the outside*, so create them up front.

```bash
sudo mkdir -p /mnt/storage/ruth-models /mnt/storage/ruth-backups
sudo chown 1000:1000 /mnt/storage/ruth-models /mnt/storage/ruth-backups

# Verify as the container sees them (expect "writable" twice):
docker run --rm -u 1000:1000 \
  -v /mnt/storage/ruth-models:/store \
  -v /mnt/storage/ruth-backups:/var/backups/ruth-ai \
  alpine sh -c 'test -w /store && echo "store writable";
                test -w /var/backups/ruth-ai && echo "backups writable"'
```

| Directory | Mounted at | If missing / not writable |
|---|---|---|
`/mnt/storage/ruth-models` | `/store` | Model Management API returns 503 |
`/mnt/storage/ruth-backups` | `/var/backups/ruth-ai` | "Start new project" refuses (it will not archive without a verified `pg_dump`) |

Override either with `RUTH_MODEL_STORE_HOST_DIR` / `RUTH_BACKUP_HOST_DIR`
in `.env`. Backup dumps are ~30 MB each and are **never pruned
automatically** — rotate them off-box.

### 3. Create `.env` — set the IP, auto-fill the 6 secrets

```bash
cp .env.example .env

# Set HOST_IP and MEDIASOUP_ANNOUNCED_IP to the SAME LAN IP (both required).
sed -i 's/^HOST_IP=.*/HOST_IP=10.40.128.10/' .env
sed -i 's/^MEDIASOUP_ANNOUNCED_IP=.*/MEDIASOUP_ANNOUNCED_IP=10.40.128.10/' .env

# Fill all 6 secrets in place with random values.
for v in VAS_DB_PASSWORD VAS_API_KEY VAS_JWT_SECRET \
         RUTH_POSTGRES_PASSWORD RUTH_JWT_SECRET VAS_CLIENT_SECRET; do
  sed -i "s|^${v}=.*|${v}=$(openssl rand -hex 32)|" .env
done

# Verify NONE of the required vars are blank (this command should print NOTHING):
grep -E '^(HOST_IP|MEDIASOUP_ANNOUNCED_IP|VAS_DB_PASSWORD|VAS_API_KEY|VAS_JWT_SECRET|RUTH_POSTGRES_PASSWORD|RUTH_JWT_SECRET|VAS_CLIENT_SECRET)=' .env

chmod 600 .env
```

> `.env.example` has no `MEDIASOUP_ANNOUNCED_IP=` line, so the first `sed`
> above won't match it. If the verify `grep` flags it, append the line:
> `echo "MEDIASOUP_ANNOUNCED_IP=10.40.128.10" >> .env` (same IP as HOST_IP).

### 4. Bring up the stack — pick ONE line

```bash
# GPU host (NVENC encoder — needs NVIDIA Container Toolkit):
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d

# CPU host (software encoder):
docker compose up -d
```

> Whichever line you pick, use the **same** `docker compose [-f ...]` flags
> for every later command (`ps`, `logs`, `restart`, `down`).

### 5. Watch it come healthy

```bash
docker compose ps        # wait until every row says "Up (healthy)"
```

Expected 11 containers: `vas-ms-v2-{db,redis,mediasoup,backend,frontend,nginx}`,
`ruth-ai-vas-{postgres,redis,backend,frontend}`, `ruth-ai-unified-runtime`.

### 6. Add a camera (VAS has none on a fresh deploy)

Open the **VAS admin portal** → `http://10.40.128.10:8086/` → **Devices** →
add name + RTSP URL (`rtsp://user:pass@ip[:port]/path`) → **Start**, confirm LIVE.
Then sync it into Ruth:

```bash
docker compose restart ruth-ai-backend
```

### 7. Verify

```bash
curl http://10.40.128.10:8086/health        # VAS:  {"status":"healthy",...}
curl http://localhost:8090/api/v1/health    # Ruth: overall status "healthy"
curl http://localhost:8012/health           # AI runtime: healthy
curl http://localhost:8090/api/v1/devices   # your camera appears here
```

Then in a browser:
- **Ruth portal** → `http://10.40.128.10/` → Camera Monitoring → pick the
  camera → live video plays, fall/PPE/tank overlays draw.
- **VAS admin** → `http://10.40.128.10:8086/` → open a stream → feed renders,
  no "Request timeout" / "WebSocket connection timeout" in the browser console.

**Done.** If any step failed, read the matching section in Reference below.

---
---

# Reference

Everything below is background and recovery. You do not need it for a
clean deploy.

## Before you start — checklist

- [ ] **Docker Engine 24+** and **Compose plugin v2.20+** (`include:` needs
  v2.20+). Check: `docker version` and `docker compose version`.
- [ ] **Weights source** reachable — a host you can `rsync` the `.pt` files
  from, with creds. See `../ruth-ai-vas-ms-v2/WEIGHTS.md`.
- [ ] **The host's LAN IP** — the address browsers reach this host on
  (`ip -4 addr show`). Not `localhost`/`127.0.0.1` — WebRTC advertises this
  IP to remote viewers.
- [ ] Disk: tens of GB for images + HLS retention (default 7d hot + 90d cold;
  hundreds of GB on a multi-camera site). RAM: 8 GB min / 16 GB recommended.
- [ ] **GPU (optional):** for real-time AI you need an NVIDIA GPU + NVIDIA
  Container Toolkit. CPU-only runs, but see "GPU vs CPU" below.

`bootstrap.sh` automates clone + secret-gen + bring-up if you prefer a script
to the manual Quick Deploy; the manual flow is the source of truth.

## Required `.env` variables

`docker compose` **fails fast** if any of these is unset — each is guarded
with `:?`. Quick Deploy step 3 fills all of them.

| Variable | Value |
|---|---|
| `HOST_IP` | Host's LAN IP (browser-reachable). |
| `MEDIASOUP_ANNOUNCED_IP` | **Same LAN IP as `HOST_IP`.** Both are required — see note below. |
| `VAS_DB_PASSWORD` | random — `openssl rand -hex 32` |
| `VAS_API_KEY` | random |
| `VAS_JWT_SECRET` | random (≥ 32 chars) |
| `RUTH_POSTGRES_PASSWORD` | random |
| `RUTH_JWT_SECRET` | random |
| `VAS_CLIENT_SECRET` | random — the VAS↔Ruth credential contract; set once, used by both sides |

### Why both `HOST_IP` and `MEDIASOUP_ANNOUNCED_IP` (the #1 deploy stall)

Setting `HOST_IP` alone is **not** enough, despite the `.env.example`
comment suggesting one knob. The merged compose maps `HOST_IP` →
`MEDIASOUP_ANNOUNCED_IP` for the mediasoup container, but the included base
file (`../vas-ms-v2/deploy/docker-compose.yml`) carries its own hard guard:

```yaml
MEDIASOUP_ANNOUNCED_IP: ${MEDIASOUP_ANNOUNCED_IP:?must be set in .env ...}
```

Compose interpolates **every** `${...}` in the merged document before the
override picks a winner, so that `:?` guard fires during interpolation even
when `HOST_IP` is set. Confirmed empirically: with only `HOST_IP` set,
`docker compose config` aborts with
`required variable MEDIASOUP_ANNOUNCED_IP is missing a value`. Setting both
to the same IP resolves cleanly. **Set both.**

### Other vars

All other vars (ports, storage path, retention, log levels, GPU index, NLP
timeouts, the `VAS_WEBRTC_URL` construction) have working defaults. Read
`.env.example` for the annotated full list. Do **not** set `VAS_VIDEO_CODEC` —
the compose mode chooses it (see GPU vs CPU).

## GPU vs CPU

The base compose is CPU-safe. The GPU overlay (`docker-compose.gpu.yml`) adds
the NVIDIA runtime + device reservation and selects the NVENC encoder. You
choose the mode by the bring-up command (Quick Deploy step 4), not by editing
files.

| Mode | Bring-up | Encoder |
|---|---|---|
| GPU | `docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d` | `h264_nvenc` |
| CPU | `docker compose up -d` | `libx264` |

What actually changes:

| Component | GPU host | CPU host |
|---|---|---|
| VAS video encoder | NVENC, very low CPU, many cameras | libx264, ~10–15% of one i7 core per 720p30 stream; 4–6 streams fit an i7 |
| Ruth AI `fall_detection`, `ppe_detection`, `geo_fencing` | YOLO on GPU, ~30 ms/frame | very slow — no first-class CPU fallback; will not keep up in real time |
| Ruth AI `tank_overflow_monitoring` | classical OpenCV | works fine on CPU |

**Implication:** no GPU → only the tank-overflow model genuinely runs in real
time. **Forgetting the GPU overlay on a GPU host** silently runs VAS on CPU —
streams work but burn a core per camera.

> The `unified-ai-runtime` service reserves GPU **0** in the base compose; the
> VAS NVENC overlay uses `NVENC_GPU_INDEX` (default **1**). On a **single-GPU
> host**, set `NVENC_GPU_INDEX=0` in `.env` so both share GPU 0.

## The two operator URLs

| URL | Purpose | Port var |
|---|---|---|
| `http://<HOST_IP>/` | **Ruth portal** — customer-facing app | `RUTH_FRONTEND_HOST_PORT=80` |
| `http://<HOST_IP>:8086/` | **VAS admin** — camera management / RTSP onboarding | `VAS_HTTP_PORT=8086` |

There's no single entry-point proxy: Ruth is day-to-day work, VAS is where
cameras get added. The VAS admin URL is served by `vas-nginx`, VAS's edge
proxy, which fronts the SPA, the HTTP API, the MediaSoup signaling WebSocket
(`/ws/`), and HLS (`/static/hot/`) on one origin. The SPA's same-origin API
and WebSocket calls depend on this edge — without it, feeds time out.

`vas-nginx` listens **only** on `${VAS_HTTP_PORT:-8086}`; the stock
`nginx:alpine` `listen 80;` block is masked by `nginx/empty.conf` so it never
contests host port 80 (Ruth owns 80).

## Bring-up details

Quick Deploy step 4 brings everything up at once; `depends_on` + health gates
order it. To localize a first-deploy failure, bring VAS up first, wait healthy,
then Ruth:

```bash
# VAS first (substitute your -f flags)
docker compose up -d vas-db vas-redis vas-mediasoup vas-backend vas-frontend vas-nginx
# then Ruth
docker compose up -d ruth-ai-db ruth-ai-redis ruth-ai-backend unified-ai-runtime ruth-ai-frontend
```

On first VAS start: Alembic migrations run, the `vas-portal` OAuth client is
seeded, and the `ruth-ai-backend` client is seeded from `VAS_CLIENT_SECRET`
(`✅ Created Ruth AI OAuth client: ruth-ai-backend`). Ruth then runs its own
migrations and auto-syncs devices from VAS at startup (a no-op if VAS has no
cameras yet). The unified runtime loads weights — `Loaded model: ...` with
weights present, `Failed to load model: ...` (stub mode) without; it stays
healthy either way.

## Full host-port map

| Service | Host port | Variable | Notes |
|---|---|---|---|
| Ruth frontend | 80 | `RUTH_FRONTEND_HOST_PORT` | operator-facing |
| Ruth backend | 8090 | `RUTH_BACKEND_HOST_PORT` | |
| Unified AI runtime | 8012 | `RUTH_UNIFIED_RUNTIME_HOST_PORT` | |
| Ruth Postgres | 5434 | `RUTH_DB_HOST_PORT` | |
| Ruth Redis | 6382 | `RUTH_REDIS_HOST_PORT` | |
| VAS edge (vas-nginx) | 8086 | `VAS_HTTP_PORT` | operator-facing; SPA + API + `/ws/` + HLS |
| VAS frontend | 127.0.0.1:3200 | `VAS_FRONTEND_HOST_PORT` | loopback only; behind vas-nginx |
| VAS backend | 8085 | `VAS_BACKEND_PORT` | host network |
| VAS Postgres | 5433 | `VAS_DB_HOST_PORT` | |
| VAS Redis | 6380 | `VAS_REDIS_HOST_PORT` | |
| MediaSoup WebRTC | 3001 + 20000–20999 RTC | `MEDIASOUP_PORT`, `MEDIASOUP_RTC_MIN/MAX_PORT` | host network |

## Common commands

| Action | Command |
|---|---|
| Status | `docker compose ps` |
| Tail one service | `docker compose logs -f <service>` |
| Restart one service | `docker compose restart <service>` |
| Stop everything | `docker compose down` |
| Stop + wipe ALL data (destroys both product DBs) | `docker compose down -v` |

---

## Troubleshooting

> This section is large enough that splitting it into a separate
> **TROUBLESHOOTING.md** would keep this page focused on the happy path —
> recommended if it grows further.

### `docker compose` aborts: "MEDIASOUP_ANNOUNCED_IP is missing a value"

You set `HOST_IP` but not `MEDIASOUP_ANNOUNCED_IP`. Set both to the same LAN
IP (see "Why both" above), then re-run.

### Ruth's VAS client retry-loops / `VASAuthenticationError`

`VAS_CLIENT_SECRET` in `.env` doesn't match what VAS has stored. VAS
reconciles the DB row to the `.env` value on backend start:

1. Confirm `.env` has a non-empty `VAS_CLIENT_SECRET`.
2. `docker compose restart vas-backend` — watch for `Created Ruth AI OAuth
   client` or `Reconciled Ruth AI OAuth client ... updated secret`.
3. `docker compose restart ruth-ai-backend` to pick up the fresh credential.

### Streams work but VAS pegs a CPU core per camera

GPU host without the GPU overlay → libx264 in software. Bring the stack down
and back up with `-f docker-compose.gpu.yml`.

### `docker compose up` fails with a port-80 bind error

Something else owns host :80. `vas-nginx` shouldn't contest it (it's masked to
:8086 via `nginx/empty.conf`); if it does, check `docker compose config` for
the `/etc/nginx/conf.d/default.conf` mount on `vas-nginx`. If a host nginx/
Apache/other container owns :80, stop it or set
`RUTH_FRONTEND_HOST_PORT=3300` (any free port ≥ 1024) in `.env` and re-up.

### VAS UI loads but feeds time out ("Request timeout" / "WebSocket timeout")

`vas-nginx` isn't fronting the SPA. The SPA needs same-origin routing for its
API and the MediaSoup signaling WebSocket. Check:

```bash
docker compose ps vas-nginx                      # Up (healthy)?
curl -I http://<HOST_IP>:8086/                    # 200?
curl -I -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://<HOST_IP>:8086/ws/mediasoup              # 101 Switching Protocols?
```

No `101` → restart `vas-nginx` and confirm `/etc/nginx/conf.d/vas.conf` was
generated from the template.

### Every frame returns 0 detections

Weights missing → runtime in stub mode. Re-do Quick Deploy step 2, then
`docker compose restart unified-ai-runtime`. `tank_overflow_monitoring` is
unaffected.

### Ruth's NLP chat shows "disabled" in the health JSON

Intended. NLP chat (`ruth-ai-nlp-chat`, `ollama`) is not deployed here
(`NLP_CHAT_ENABLED=false`); the health rollup excludes disabled components, so
overall stays `healthy`. Informational, not a warning.

### WebRTC won't connect from a remote browser

`HOST_IP`/`MEDIASOUP_ANNOUNCED_IP` is `localhost`/`127.0.0.1`/an unreachable
interface. Set both to the LAN IP. Then, because Ruth's frontend bakes
`VITE_VAS_WEBRTC_URL` into its bundle at **build** time, a restart isn't
enough:

```bash
docker compose build ruth-ai-frontend
docker compose up -d ruth-ai-frontend
```

VAS's frontend needs no rebuild (resolves its API base from
`window.location.origin` at runtime via vas-nginx). VAS's mediasoup reads the
IP at runtime, so a plain `docker compose restart vas-mediasoup` suffices there.
