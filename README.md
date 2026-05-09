# vas-ruthai-deploy

Integration repo that brings up VAS-MS-V2 (`vas-ms-v2/`) and Ruth AI
(`ruth-ai-vas-ms-v2/`) as a single Docker stack on one host.

## Layout

This repo expects the two app repos to sit alongside it as siblings:

```
<your-checkout-root>/
├── vas-ms-v2/                  # VAS app, has deploy/
├── ruth-ai-vas-ms-v2/          # Ruth AI app
└── vas-ruthai-deploy/          # this repo — run docker compose from here
```

The merged compose uses `include:` to pull VAS service definitions from
`../vas-ms-v2/deploy/docker-compose.yml`. Ruth AI services are inlined
here today because Ruth AI doesn't have its own `deploy/` yet — see the
TODO in the compose file.

## Prerequisites

- Docker Engine 24+ with Compose plugin v2.20+ (required for `include:`)
- NVIDIA Container Toolkit (VAS uses GPU 1 for nvenc; AI uses GPU 0)
- LAN IP for WebRTC clients

## Quick start

```bash
git clone <vas-ms-v2 URL>          ../vas-ms-v2
git clone <ruth-ai-vas-ms-v2 URL>  ../ruth-ai-vas-ms-v2
git clone <this-repo URL>          ./
cd vas-ruthai-deploy
./bootstrap.sh                      # creates .env from template, then up -d
# edit .env and re-run if prompted
```

Or manually:

```bash
cp .env.example .env
# edit .env: at minimum set MEDIASOUP_ANNOUNCED_IP, HOST_IP, all *_PASSWORD
# and *_SECRET vars
docker compose up -d
```

## What gets deployed

| Group | Services |
|---|---|
| VAS (from `../vas-ms-v2/deploy/`) | vas-db, vas-redis, vas-mediasoup, vas-backend, vas-frontend, vas-nginx |
| Ruth AI (inlined here) | ruth-ai-db, ruth-ai-redis, ruth-ai-backend, unified-ai-runtime, ruth-ai-frontend |

Services NOT enabled (intentionally — pre-existing GPU-capacity decision):
`ruth-ai-nlp-chat`, `ollama`, `ollama-init`. To re-enable, restore them
from your git history.

## Ports

| Port | Service |
|---|---|
| `${VAS_HTTP_PORT}` (default 8086) | VAS single entry point (nginx) |
| 3300 | Ruth AI frontend |
| 8090 | Ruth AI backend API |
| 8012 | Unified AI runtime |
| 5433, 5434 | VAS PG, Ruth AI PG |
| 6380, 6382 | VAS Redis, Ruth AI Redis |
| 3001 | MediaSoup signaling (host network) |

## Configuration

All operator-tunable values live in `.env`. The template is
`.env.example` — `cp` it and fill in the REQUIRED vars. The merged
compose fails fast if a required secret is unset.

### .env scope

This `.env` is the **single source of truth** for both VAS and Ruth AI
config when deployed together. Vars that are also in
`vas-ms-v2/deploy/.env.example` get pulled in via `include:`. There is
no need to also create a `.env` inside `vas-ms-v2/deploy/` — that's
only relevant when deploying VAS standalone.

## Operations

### Bring up / down

```bash
docker compose up -d
docker compose down            # keeps volumes
docker compose down -v         # also wipes db data — DESTRUCTIVE
```

### Tail logs

```bash
docker compose logs -f vas-backend
docker compose logs -f ruth-ai-backend
```

### Rebuild a single service

```bash
docker compose up -d --build vas-frontend
docker compose up -d --build ruth-ai-backend
```

## ⚠ Known Limitation: Fresh-DB bootstrap

The VAS Alembic migration chain doesn't currently work from base — this
is a pre-existing application bug. **The merged deploy is safe to run
against an already-bootstrapped VAS database**, but greenfield deploys
require a manual one-time bootstrap. See
`../vas-ms-v2/deploy/README.md` → "Known Limitation: First-Boot
Bootstrap" for the workaround.

This does not affect operators who are migrating an existing live
deploy onto this repo (which is the current case at this site — the
live VAS DB is already populated and stamped at the head Alembic
revision).

## Migration from the pre-restructure layout

If you're switching an existing site from the old `/home/project/docker-compose.yml`
layout to this repo:

1. Stop the old stack:
   `docker compose -f /home/project/docker-compose.yml down`
2. Move the old artifacts aside (don't delete):
   `mv /home/project/docker-compose.yml /home/project/docker-compose.yml.bak-pre-restructure`
   `mv /home/project/nginx /home/project/nginx.bak-pre-restructure`
   `mv /home/project/.env /home/project/.env.bak-pre-restructure`
3. The `.env` in this repo (`vas-ruthai-deploy/.env`) is now the
   working `.env` — it was seeded from the host file during the
   restructure.
4. Bring up the new stack:
   `cd /home/project/vas-ruthai-deploy && docker compose up -d`
5. Verify ports `8086` (VAS) and `3300` (Ruth AI) respond, that all
   services are healthy, and that 12-camera streaming works as before.

## Repository layout (this repo only)

```
vas-ruthai-deploy/
├── docker-compose.yml      # merged compose with `include:` of VAS
├── .env                    # operator-supplied, GITIGNORED
├── .env.example            # template, committed
├── bootstrap.sh            # idempotent first-run helper
├── README.md
└── .gitignore              # .env, *.bak
```

There is **no** `nginx/` directory in this repo. nginx for VAS lives in
`../vas-ms-v2/deploy/nginx/` and travels with the VAS app — when VAS
adds a new route, that change happens in one place. If we ever need
integration-specific routing (e.g., putting Ruth AI behind the same
nginx), that nginx config would land here.
