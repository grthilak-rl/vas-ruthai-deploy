# vas-ruthai-deploy

Integration repository that brings up [VAS-MS-V2](https://github.com/grthilak-rl/vas-ms-v2)
and [Ruth AI](https://github.com/grthilak-rl/ruth-ai-vas-ms-v2) as a
single Docker stack on one host.

## Layout

This repo expects the two product repos to sit alongside it as siblings:

```
<your-checkout-root>/
├── vas-ms-v2/                  # VAS app, has its own deploy/
├── ruth-ai-vas-ms-v2/          # Ruth AI app + unified AI runtime
└── vas-ruthai-deploy/          # this repo — run docker compose from here
```

The merged compose uses `include:` to pull VAS service definitions
from `../vas-ms-v2/deploy/docker-compose.yml`. Ruth AI services and
the unified AI runtime are inlined here today.

## Deployment

The authoritative deployment procedure is **[DEPLOYMENT.md](DEPLOYMENT.md)**.

Follow it top to bottom for a fresh host. It covers:

- Prerequisites (Docker, optional NVIDIA Container Toolkit, GPU vs CPU)
- Cloning the three repos
- Model weights (gitignored, must be copied)
- `.env` configuration (the seven required values, generated)
- GPU vs CPU mode selection
- Bring-up, camera registration, verification, troubleshooting

`bootstrap.sh` in this directory automates the first-run setup
(clones siblings, generates `.env`, brings the stack up). See its
header for usage and flags.
