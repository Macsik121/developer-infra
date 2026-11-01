# Instructions to start development

Dockerized Ubuntu 24.04 dev box: Chromium (proxied via sing-box TUN), code-server, Claude Code.

## Prerequisites

- Docker Engine + Compose v2 (`docker compose version`)
- **Windows**: Docker Desktop with WSL2 backend
- **Linux**: `xhost` (for `x11-xserver-utils`) — not needed for noVNC access, only if you switch to native window later

Install Docker if missing: https://docs.docker.com/engine/install/

## Start

```bash
git clone https://github.com/Macsik121/developer-infra
cd developer-infra
```

**Windows (PowerShell):**

```powershell
.\run-env.ps1
```

**Linux:**

```bash

bash run-env.sh

```

What this does: `docker compose down` (if exists) → `docker compose up -d --build`.

On first run, `sing-box` is installed automatically by `setup-vpn.sh` inside the container. Wait ~30–60 s.

## Access

| Service | URL |
|---|---|
| Chromium (via noVNC) | <http://localhost:6901> |
| code-server | <http://localhost:8080> (password: `devpassword123` — change before exposing externally) |

Chromium is already running inside noVNC when the page loads. Traffic goes through sing-box transparently; do **not** add `--proxy-server`.

## Verify

```bash

docker exec -it ubuntu24-dev-box bash

supervisorctl status

# sing-box RUNNING, xvfb RUNNING, code-server RUNNING, chromium RUNNING

ip a show sing-tun          # TUN interface UP

curl -s https://ipinfo.io   # should show proxy IP, not your real one

```

If `curl` shows your real IP, sing-box is down — see Troubleshooting.

## Manual scripts (optional, in `/etc/sing-box/`)

- `test-connection.sh` — prints current egress IP through sing-box.
- `start-claude.sh` — launches Claude Code configured for the Omniroute provider.
&#x20; Requires `OMNIROUTE_API_KEY` to be set in the container (e.g. via `docker exec -e OMNIROUTE_API_KEY=... ubuntu24-dev-box bash`).

`setup-vpn.sh` runs automatically — **do not run it manually** unless sing-box is stuck; see Troubleshooting.

## Troubleshooting

- **`chromium: no internet` in noVNC** → `docker exec -it ubuntu24-dev-box bash`, then `curl -s https://ipinfo.io`. If that fails, sing-box is down:

&#x20; ```bash

&#x20; supervisorctl status

&#x20; tail -n 50 /var/log/supervisor/sing-box.err.log

&#x20; ```

- **noVNC shows black screen** → `supervisorctl status xvfb fluxbox x11vnc`. Restart with `supervisorctl restart xvfb`.

- **`setup-vpn.sh` failed at first start** (404, network) → exec into the container, fix `VERSION=` in `/etc/sing-box/setup-vpn.sh`, then `supervisorctl restart sing-box`.

- **Container recreates and loses everything** → expected; mount `./workspace` for persistent data.

```
