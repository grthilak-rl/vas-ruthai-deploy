# Deployment Guide — VAS + Ruth AI Integrated Stack

> **Draft status.** This guide is written from the codebase. It will be
> revised against reality during the first guided deployment, which is
> its proving run. Items marked **VERIFY DURING DEPLOYMENT** are
> known-uncertain spots that the proving run must confirm or correct.

This document is for an ops engineer who is comfortable with Linux and
Docker but is not expected to know how VAS or Ruth AI work internally.
Follow it top to bottom on a fresh host.

---

## 1. Overview

You are deploying three things together as one stack:

| Product | Role |
|---|---|
| **VAS** (`vas-ms-v2`) | Video Analytics Service. Pulls RTSP from cameras, transcodes for WebRTC, records HLS to disk, exposes a portal and an API. |
| **Ruth AI** (`ruth-ai-vas-ms-v2`) | The AI/operator app. Reads cameras from VAS, runs inference on live streams and on recorded bookmarks, hosts the customer-facing portal. |
| **Unified AI runtime** (lives inside `ruth-ai-vas-ms-v2`) | Loads the ML model weights and serves `/inference` calls from Ruth's backend and frontend. |

VAS is a standalone product. Ruth AI depends on VAS. The integration
layer (`vas-ruthai-deploy/` — this repo) brings them up together,
wires the credential contract, exposes a single operator-facing
`.env`, and keeps each product's internals untouched.

---

## 2. Prerequisites

### Host

- **OS:** Linux. **VERIFY DURING DEPLOYMENT:** the target host's
  exact distro/version (dev is Ubuntu LTS).
- **Docker Engine 24+** with **Compose plugin v2.20+** — `include:`
  syntax is used in the integration compose and requires v2.20+.
  Check with `docker version` and `docker compose version`.
- **Disk:** several tens of GB free for images plus whatever HLS
  retention you configure (default 7 days hot + 90 days cold). On a
  multi-camera site this can be hundreds of GB.
  **VERIFY DURING DEPLOYMENT:** realistic minimum.
- **RAM:** 8 GB minimum for a small site (4 cameras). 16 GB recommended.
  **VERIFY DURING DEPLOYMENT:** numbers under real load on the dev box.
- **CPU:** modern x86_64 with AVX2. The MCU target i7 is the lower bound.

### Optional: NVIDIA GPU

- If the host has an NVIDIA GPU, install the **NVIDIA Container
  Toolkit** so Docker can hand devices to containers.
  `nvidia-smi` from inside a `docker run --runtime=nvidia ...` test
  container should list the GPU.
- **No GPU on the host is fine** — VAS will encode on CPU and the
  stack will run. Read the next subsection before deciding.

### GPU vs CPU — what changes

| Component | GPU host | No GPU |
|---|---|---|
| VAS video encoder | NVENC (hardware H.264) — very low CPU cost, scales to many cameras | libx264 (software) — ~10-15% of one i7 core per 720p30 stream. 4-6 streams fits an i7 comfortably. |
| Ruth AI runtime — `fall_detection`, `ppe_detection`, `geo_fencing` | YOLO models run on GPU, ~30 ms per frame | **Models will be very slow.** They have no first-class CPU fallback. The pipeline runs but real-time inference will not keep up. **VERIFY DURING DEPLOYMENT:** exact behavior of the runtime on a GPU-less host. |
| Ruth AI runtime — `tank_overflow_monitoring` | Classical OpenCV; GPU irrelevant | Works fine on CPU. |

**Implication:** if there is no GPU and you need fall/PPE/geofencing
to actually detect things, you need to deploy on a GPU host. The
tank-overflow demo is the one model that genuinely runs anywhere.

---

## 3. The three-repo checkout

The integration compose expects all three repos to sit side by side
as siblings. Pick a checkout root and clone them:

```bash
mkdir -p /opt/ruthai
cd /opt/ruthai

git clone <VAS_REPO_URL>          vas-ms-v2
git clone <RUTH_REPO_URL>         ruth-ai-vas-ms-v2
git clone <DEPLOY_REPO_URL>       vas-ruthai-deploy

# Confirm each is on main
( cd vas-ms-v2          && git rev-parse --abbrev-ref HEAD ) # → main
( cd ruth-ai-vas-ms-v2  && git rev-parse --abbrev-ref HEAD ) # → main
( cd vas-ruthai-deploy  && git rev-parse --abbrev-ref HEAD ) # → main
```

The three-repo layout is intentional: VAS and Ruth AI are separate
products with their own release cadence and dependency graph;
`vas-ruthai-deploy/` is the thin integration layer that knows how to
run them together. The compose files use sibling-relative paths
(`../vas-ms-v2/`, `../ruth-ai-vas-ms-v2/`), so keeping the names and
the parent directory is load-bearing.

**VERIFY DURING DEPLOYMENT:** the canonical repository URLs and any
auth (deploy keys, PAT) ops needs to clone them.

`vas-ruthai-deploy/bootstrap.sh` automates this clone-and-config flow
(generates `.env` with `openssl rand` secrets, prompts for `HOST_IP`,
brings the stack up). Pass `--gpu` on a GPU host, `--cpu` otherwise.
If you've exported `VAS_REPO_URL` and `RUTH_REPO_URL`, the script
also clones the sibling repos:

```bash
VAS_REPO_URL=https://... RUTH_REPO_URL=https://... \
  ./bootstrap.sh --gpu      # or --cpu
```

The manual flow above is equivalent and is the source of truth — use
whichever you prefer.

---

## 4. Model weights — read this carefully

The ML model weight files (~837 MB across 16 `.pt` files) are
**gitignored** and **not** pulled by `git clone`. Without them, the AI
models run in stub mode and return "no detections" for every frame.

Source of truth for what files go where:

```
ruth-ai-vas-ms-v2/WEIGHTS.md
```

Summary:

- **Need weights:** `fall_detection`, `ppe_detection`, `geo_fencing`.
- **Does not need weights:** `tank_overflow_monitoring` (classical
  OpenCV, no model file).

Files land under:

```
ruth-ai-vas-ms-v2/ai/yolov8n.pt
ruth-ai-vas-ms-v2/ai/models/<model>/<version>/weights/*.pt
```

Common approach: copy from an existing running deployment with
`rsync`. The exact commands are in `WEIGHTS.md`. After copying,
verify:

```bash
cd ruth-ai-vas-ms-v2
find ai -name "*.pt" -exec ls -lh {} \; | wc -l   # expect 16
```

If you skip this step, expect "Failed to load model" warnings from
the unified runtime container at startup and zero detections at
runtime. Only `tank_overflow_monitoring` will actually work.

**VERIFY DURING DEPLOYMENT:** the rsync source — where the dev box
gets its weights from, and what creds it needs.

---

## 5. Configuration — the `.env`

From `vas-ruthai-deploy/`:

```bash
cp .env.example .env
chmod 600 .env       # contains secrets; restrict reads
```

Then open `.env` and fill in **only the values listed below**.
Everything else has a sane default that you can leave alone until
you have a reason to change it.

### Required (must set)

| Variable | What it is | How to choose a value |
|---|---|---|
| `HOST_IP` | The host's LAN IP that browser clients can reach. Used for WebRTC ICE — `localhost` does NOT work for remote viewers. | `ip -4 addr show` and pick the address browsers reach you on. Example: `10.40.128.10`. |
| `VAS_DB_PASSWORD` | Password for VAS's Postgres user. | `openssl rand -hex 16` |
| `VAS_API_KEY` | API key for service-to-service callers of VAS. | `openssl rand -hex 32` |
| `VAS_JWT_SECRET` | JWT signing key for VAS portal/API tokens. Minimum 32 chars. | `openssl rand -hex 32` |
| `RUTH_POSTGRES_PASSWORD` | Password for Ruth's Postgres user. | `openssl rand -hex 16` |
| `RUTH_JWT_SECRET` | JWT signing key for Ruth's API tokens. | `openssl rand -hex 32` |
| `VAS_CLIENT_SECRET` | **The VAS↔Ruth credential contract.** Set ONCE here. VAS seeds the `ruth-ai-backend` OAuth client with it at startup; Ruth authenticates to VAS with it. No manual API call needed. | `openssl rand -hex 32` |

### The two URLs operators use

The integrated deployment exposes two documented URLs, both on
fixed env-pinned ports:

| URL | Purpose | Port variable |
|---|---|---|
| `http://<HOST_IP>/` | **Ruth portal** — customer-facing app (live monitoring, alerts, etc.) | `RUTH_FRONTEND_HOST_PORT=80` |
| `http://<HOST_IP>:8086/` | **VAS admin** — camera management, RTSP onboarding, stream control | `VAS_HTTP_PORT=8086` |

Operators learn both. Ruth is where day-to-day work happens; VAS
is where cameras get added and configured. No single-entry-point
proxy — the two-URL contract is simpler and the only thing
operators have to remember.

The VAS admin URL is served by `vas-nginx`, VAS's edge proxy. It
fronts the SPA, the HTTP API (`/api/`, `/v1/`, `/v2/`), the
MediaSoup signaling WebSocket (`/ws/`), and HLS segment serving
(`/static/hot/`) on one origin — the same shape VAS standalone
uses. The SPA's same-origin calls (API + WebSocket) depend on this
edge; running vas-frontend without it leaves the SPA unable to
reach the API or open the signaling WebSocket.

vas-nginx in this integrated deployment listens **only** on
`${VAS_HTTP_PORT:-8086}`. The stock `nginx:alpine` image ships a
default `listen 80;` config block that we suppress (mounted-empty)
so it never tries to take host port 80, which Ruth owns. See
`nginx/empty.conf` in this repo.

### Picking values worth knowing

- **`RUTH_FRONTEND_HOST_PORT=80`** — Ruth's portal port. If
  something else on the host is already on :80, set this to
  something ≥ 1024 (e.g. `3300`). On rootless Docker, port 80
  needs `sysctl net.ipv4.ip_unprivileged_port_start=80` or a value
  ≥ 1024.
- **`VAS_HTTP_PORT=8086`** — VAS admin port (the vas-nginx edge).
  Change only if it collides.
- **`HOST_IP`** — required for WebRTC ICE; baked into Ruth's
  frontend bundle as `VITE_VAS_WEBRTC_URL`. VAS's frontend in the
  integrated deployment does *not* bake `HOST_IP` (it resolves the
  API base from `window.location.origin` at runtime via
  vas-nginx). See "Changing HOST_IP after deployment" in
  troubleshooting.

**Do not** set `VAS_VIDEO_CODEC` in `.env`. The compose mode
decides — base compose picks `libx264`, the GPU overlay picks
`h264_nvenc`. See section 6.

### Everything else

Optional knobs (ports, storage paths, retention, the WebRTC URL
construction, log levels, GPU index, NLP timeouts) all have defaults
that work out of the box. Read `.env.example` for the full list with
comments. Touch them only when you have a reason.

`docker compose` will **fail fast** if a required variable is unset
— each one is guarded with `:?`.

---

## 6. GPU vs CPU — choosing the mode

The base compose file is CPU-safe. The GPU overlay
(`docker-compose.gpu.yml`) adds the NVIDIA runtime, the GPU device
reservation, and selects the NVENC encoder.

| Mode | Compose command (run from `vas-ruthai-deploy/`) | Resulting encoder |
|---|---|---|
| **GPU** | `docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d` | `h264_nvenc` |
| **CPU** | `docker compose up -d` | `libx264` |

The encoder choice flows from the compose mode automatically; you do
not set it in `.env`. **Forgetting the GPU overlay on a GPU host**
runs VAS on CPU instead — streams will work but at far higher CPU
cost than necessary.

Going forward, whenever this guide says `docker compose ...`, use
**the same command for both bring-up and any subsequent restarts**.
If you used the GPU overlay once, use it every time on the same host.

---

## 7. Bring-up

### 7a. Bring up VAS first

VAS is the source of truth for cameras and stream URLs. Ruth syncs
from it at startup, so VAS needs to be healthy before Ruth starts.

```bash
cd /opt/ruthai/vas-ruthai-deploy

# Pick ONE of these two depending on your mode (see section 6).
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d \
  vas-db vas-redis vas-mediasoup vas-backend vas-frontend vas-nginx
# OR for CPU mode:
# docker compose up -d \
#   vas-db vas-redis vas-mediasoup vas-backend vas-frontend vas-nginx

# Watch them come up
docker compose ps
docker compose logs -f vas-backend
```

On the first start, VAS runs its Alembic database migrations
(creates schema), seeds the default `vas-portal` OAuth client, and
seeds the `ruth-ai-backend` OAuth client from `VAS_CLIENT_SECRET`.
Expect these log lines:

```
✅ Created default API client: vas-portal
✅ Created Ruth AI OAuth client: ruth-ai-backend
```

Wait for all six VAS containers to report **healthy**:

```bash
docker compose ps   # STATUS column should say "Up (healthy)" for all
curl http://localhost:${VAS_BACKEND_PORT:-8085}/health
# expect: {"status":"healthy","service":"VAS Backend",...}
```

A fresh VAS has zero cameras — that's expected. You'll add them in
section 8 — through Ruth's portal, or directly via the VAS API.

### 7b. Bring up Ruth AI + the AI runtime

Once VAS is healthy:

```bash
# Same -f flags you used for VAS, plus the Ruth services
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d \
  ruth-ai-db ruth-ai-redis ruth-ai-backend unified-ai-runtime ruth-ai-frontend
# OR for CPU mode:
# docker compose up -d \
#   ruth-ai-db ruth-ai-redis ruth-ai-backend unified-ai-runtime ruth-ai-frontend

docker compose ps
docker compose logs -f ruth-ai-backend
```

Ruth runs its own migrations, opens its VAS client (using
`VAS_CLIENT_SECRET` to authenticate), and **auto-syncs devices from
VAS** at startup. If VAS has no cameras yet, the sync is a no-op
and Ruth continues. Expect log lines confirming the VAS client
connected and devices sync ran (zero or more devices).

The unified AI runtime loads the model weights. With weights present
expect `Loaded model: fall_detection` etc.; without them expect
`Failed to load model: <name>` warnings. The runtime stays healthy
either way — it just serves stub responses for the unloaded models.

Wait for all five Ruth services to report **healthy**:

```bash
docker compose ps
curl http://localhost:8090/api/v1/health
# expect: a JSON object with overall status "healthy"
```

### 7c. Shortcut — bring everything up in one command

If you trust the dependencies to handle ordering (Compose's
`depends_on` plus the health gates do), the whole thing comes up
with a single command:

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
# OR for CPU mode:
# docker compose up -d
```

For the first deployment on a host, prefer the two-step flow above
(7a then 7b) — it makes failures easier to localize. `bootstrap.sh`
also does the single-command bring-up after generating `.env`.

---

## 8. Adding cameras

A fresh VAS has no cameras. Add them through the VAS admin portal
(or its API). Ruth auto-syncs from VAS at startup and on demand.

### Through the VAS portal (recommended)

1. Open the VAS portal:
   `http://<HOST_IP>:${VAS_HTTP_PORT:-8086}/`.
2. Navigate to the **Devices** page.
3. Add a camera: name + RTSP URL (`rtsp://user:pass@ip[:port]/path`).
4. Start the stream from the Devices page; confirm it appears LIVE.

### Through the VAS API

```bash
curl -X POST "http://<HOST_IP>:${VAS_BACKEND_PORT:-8085}/api/v1/devices" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Camera 1",
    "rtsp_url": "rtsp://user:pass@10.40.128.99/live1s1.sdp"
  }'
```

The legacy `/api/v1/devices/*` endpoints do not require auth. The
newer `/v2/*` endpoints require an OAuth Bearer token.

**VERIFY DURING DEPLOYMENT:** the exact UI flow on the current
VAS frontend, including whether "Start streaming" must be clicked
manually after creating a device.

### Sync to Ruth

After cameras are added in VAS, Ruth picks them up automatically:

- **On Ruth's next startup** the lifespan hook re-runs the device
  sync. So `docker compose restart ruth-ai-backend` is a reliable
  way to force a sync.
- **VERIFY DURING DEPLOYMENT:** whether the running Ruth backend
  also polls/refreshes devices on a schedule, or whether restart is
  the operator's tool. (There's a `POST /internal/sync/devices`
  endpoint but the standard UX is unclear without testing.)

---

## 9. Verification checklist

After bring-up + camera add, walk through this list. All items
should pass before you call the deployment done.

- [ ] `docker compose ps` shows all containers as `Up (healthy)`.
  Expected names: `vas-ms-v2-{db,redis,mediasoup,backend,frontend,nginx}`,
  `ruth-ai-vas-{postgres,redis,backend,frontend}`,
  `ruth-ai-unified-runtime`.
- [ ] `curl http://<HOST_IP>:${VAS_BACKEND_PORT:-8085}/health` returns
  `{"status":"healthy",...}`.
- [ ] `curl http://localhost:8090/api/v1/health` returns Ruth's
  health JSON with overall status `healthy`. NLP chat will show as
  `"status": "disabled"` in the component list — that's expected and
  does not affect the rollup (see Troubleshooting).
- [ ] **OAuth handshake working** — Ruth's logs do not show repeated
  `VASAuthenticationError` or token-refresh failures. Tail
  `ruth-ai-backend` for a minute after startup; if there are no auth
  errors, the contract is good.
- [ ] **Devices synced** — `curl http://localhost:8090/api/v1/devices`
  returns the cameras you added to VAS.
- [ ] **AI models healthy** —
  `curl http://localhost:8012/health` (unified runtime) returns
  healthy. With weights present, **VERIFY DURING DEPLOYMENT** that
  the per-model health endpoints (`/models/status` or equivalent
  on Ruth's backend) report fall/ppe/geo loaded.
- [ ] **Ruth portal loads** at
  `http://<HOST_IP>:${RUTH_FRONTEND_HOST_PORT:-80}/`. (If port 80,
  the URL has no `:port` suffix.)
- [ ] **VAS admin portal works end-to-end** at
  `http://<HOST_IP>:${VAS_HTTP_PORT:-8086}/`. "Loads" is not
  enough — open the Streams or Devices page and confirm in the
  browser DevTools:
  - No `Failed to discover streams: Request timeout` in the
    console.
  - No `WebSocket connection timeout` /
    `getRouterRtpCapabilities` timeout from mediasoup-client.
  - Camera feeds actually start and render (assuming at least one
    camera is configured and live).
  These three pass when vas-nginx is correctly fronting the SPA's
  same-origin API + `/ws/` routes. If any fail, see
  troubleshooting → "VAS UI loads but feeds time out".
- [ ] **Live Camera Monitoring** — open Ruth → Camera Monitoring
  → select a camera. WebRTC connects and live video plays. Enable
  fall/PPE/tank — overlays draw on the frame.
- [ ] **Bookmark Monitoring** — create a bookmark in VAS (Bookmark
  in the live view, or via API). In Ruth → Bookmark Monitoring,
  the bookmark appears in the dropdown. Pick a model, press play
  — overlays draw on the recorded video.

---

## 10. Troubleshooting

Likely failure modes and what they mean.

### Ruth's VAS client is in a retry loop / `VASAuthenticationError`

The `VAS_CLIENT_SECRET` in `.env` does not match what VAS thinks the
client's secret is. The seeding code reconciles the DB row to the
`.env` value on **VAS backend start**, so:

1. Confirm `.env` has `VAS_CLIENT_SECRET=` set to a non-empty value.
2. `docker compose restart vas-backend` — watch its logs for either
   `Created Ruth AI OAuth client` or
   `Reconciled Ruth AI OAuth client ... updated secret`. Either
   means the DB row now matches the env.
3. Then `docker compose restart ruth-ai-backend` so Ruth picks up
   the fresh credential.

### Streams up but VAS pegs a CPU core per camera

You're on a GPU host but forgot the GPU overlay. The VAS encoder is
running libx264 in software. Bring the stack down and back up with
the overlay (section 6).

### Port 80 already in use / `docker compose up` fails with port bind error

Something else on the host is already on port 80. The integrated
deployment is designed so vas-nginx listens **only** on
`${VAS_HTTP_PORT:-8086}` (via the empty `nginx/empty.conf` mounted
over the stock `default.conf`), so vas-nginx should not contest
:80. If it does, the `nginx/empty.conf` mount is missing or has
been undone — check `docker compose config` output for the
`/etc/nginx/conf.d/default.conf` mount on `vas-nginx`.

If a host-level nginx, Apache, or unrelated container owns :80,
either stop it or set `RUTH_FRONTEND_HOST_PORT=3300` (or any free
port ≥ 1024) in `.env` and re-up.

### VAS UI loads but feeds time out / "Request timeout" / "WebSocket connection timeout"

This is the failure mode when vas-nginx is missing or not
fronting the SPA. The VAS SPA assumes same-origin routing for its
HTTP API and the MediaSoup signaling WebSocket; without
vas-nginx the SPA's calls to `/api/v1/*` and the `/ws/...`
handshake go to the Next.js server, which doesn't proxy them.

Check:

```bash
docker compose ps vas-nginx                              # Up (healthy)?
curl -I http://<HOST_IP>:${VAS_HTTP_PORT:-8086}/         # 200?
curl -I -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://<HOST_IP>:${VAS_HTTP_PORT:-8086}/ws/mediasoup   # 101 Switching Protocols?
```

If the WebSocket check doesn't get a `101`, vas-nginx is either
not running or its `/ws/` location block isn't loaded — restart it
and confirm `/etc/nginx/conf.d/vas.conf` was generated correctly
from the template.

### Ruth runtime starts but every frame returns 0 detections

Model weights are missing. The runtime container fell back to stub
mode. Follow section 4, then `docker compose restart unified-ai-runtime`.
`tank_overflow_monitoring` is unaffected (no weights needed).

### Compose refuses to start: "external volume not found"

You skipped section 7a. Run:

```bash
docker volume create vas-ms-v2-postgres-data
docker volume create vas-ms-v2-redis-data
```

### Ruth's NLP chat shows as "disabled" in the health JSON

That's the intended steady state for this integration. NLP chat
(`ruth-ai-nlp-chat`, `ollama`) is intentionally not deployed — the
integration compose sets `NLP_CHAT_ENABLED=false` on the Ruth
backend. Ruth's health endpoint reports that component with
`status: "disabled"`, and the **overall rollup excludes disabled
components**, so the top-level status remains `healthy` regardless
of NLP. The "disabled" entry in the JSON is informational, not a
warning.

To re-enable NLP chat later, restore the `ruth-ai-nlp-chat` and
`ollama` services in the compose and remove `NLP_CHAT_ENABLED=false`.

### MediaSoup / WebRTC won't connect from a remote browser

`HOST_IP` is set to `localhost` / `127.0.0.1` / an interface the
browser cannot reach. Set it to the host's LAN IP, then **rebuild
the Ruth frontend image** (see "Changing HOST_IP after deployment"
below).

### Changing HOST_IP after deployment

**Known limitation.** Ruth's frontend bakes `VITE_VAS_WEBRTC_URL`
into its JS bundle at Docker build time. Changing `HOST_IP` in
`.env` and restarting the frontend container is NOT enough — the
old IP is still in the JS the browser downloads.

To pick up a new `HOST_IP`:

```bash
docker compose build ruth-ai-frontend
docker compose up -d ruth-ai-frontend
```

VAS's frontend does NOT need a rebuild — in the integrated
deployment it resolves its API base from `window.location.origin`
at runtime via vas-nginx, so it follows whatever host the operator
loads it from.

VAS's mediasoup container reads `HOST_IP` at runtime (via
`MEDIASOUP_ANNOUNCED_IP`), so a plain restart suffices:

```bash
docker compose restart vas-mediasoup
```

---

## Quick reference

| Action | Command |
|---|---|
| Bring up (GPU mode) | `docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d` |
| Bring up (CPU mode) | `docker compose up -d` |
| Show status | `docker compose ps` |
| Tail one service | `docker compose logs -f <service>` |
| Restart one service | `docker compose restart <service>` |
| Stop everything | `docker compose down` |
| Stop and wipe Ruth data (dangerous) | `docker compose down -v` (this destroys *both* product databases) |

| Endpoint | URL | Port var |
|---|---|---|
| Ruth portal | `http://<HOST_IP>/` (if port 80, no `:port`) | `RUTH_FRONTEND_HOST_PORT=80` |
| VAS admin portal | `http://<HOST_IP>:8086/` | `VAS_HTTP_PORT=8086` |
| VAS health | `http://<HOST_IP>:8086/health` (via vas-nginx) | `VAS_HTTP_PORT=8086` |
| Ruth health | `http://<HOST_IP>:8090/api/v1/health` | `RUTH_BACKEND_HOST_PORT=8090` |
| Unified AI runtime health | `http://<HOST_IP>:8012/health` | `RUTH_UNIFIED_RUNTIME_HOST_PORT=8012` |

### Full host-port map

| Service | Host port | Variable | Notes |
|---|---|---|---|
| Ruth frontend | 80 | `RUTH_FRONTEND_HOST_PORT` | Operator-facing |
| Ruth backend | 8090 | `RUTH_BACKEND_HOST_PORT` | |
| Unified AI runtime | 8012 | `RUTH_UNIFIED_RUNTIME_HOST_PORT` | |
| Ruth Postgres | 5434 | `RUTH_DB_HOST_PORT` | |
| Ruth Redis | 6382 | `RUTH_REDIS_HOST_PORT` | |
| VAS edge (vas-nginx) | 8086 | `VAS_HTTP_PORT` | Operator-facing; fronts SPA + API + `/ws/` + HLS |
| VAS frontend | 127.0.0.1:3200 | `VAS_FRONTEND_HOST_PORT` | Loopback only; behind vas-nginx |
| VAS backend | 8085 | `VAS_BACKEND_PORT` | Host network |
| VAS Postgres | 5433 | `VAS_DB_HOST_PORT` | |
| VAS Redis | 6380 | `VAS_REDIS_HOST_PORT` | |
| MediaSoup WebRTC | 3001 + 20000-20999 RTC | `MEDIASOUP_PORT`, `MEDIASOUP_RTC_MIN_PORT/MAX_PORT` | Host network |
