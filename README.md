# Instructions to start development

Dockerized Ubuntu 24.04 dev box: Chromium (proxied via sing-box TUN), code-server, Claude Code.

## Prerequisites

- Docker Engine + Compose v2 (`docker compose version`)
- **Windows**: Docker Desktop with WSL2 backend
- **Linux**: `xhost` (for `x11-xserver-utils`) — not needed for noVNC access, only if you switch to native window later

Install Docker if missing: https://github.com/Macsik121/setup-vpn

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
chmod +x run-env.sh

./run-env.sh

```

What this does: `docker compose down` (if exists) → `docker compose up -d --build`.

On first run, `sing-box` is installed automatically by `setup-vpn.sh` inside the container. Wait ~30–60 s.

## Access

| Service | URL |
|---|---|
| Chromium (via noVNC) | <http://localhost:6901/vnc.html> |
| code-server | <http://localhost:8080> (password: `devpassword123` — change before exposing externally) |

Chromium is already running inside noVNC when the page loads. Traffic goes through sing-box transparently; do **not** add `--proxy-server`.

### Host window (WSLg)

On Windows, Chromium opens as a **separate window on the desktop** — it draws straight onto WSLg's X server `:0`, which `docker compose` reaches through the `/run/desktop/mnt/host/wslg/.X11-unix` bind. noVNC shows that same desktop, so resizing the host window changes the browser view too.

Requires Docker Desktop with the WSL2 backend and GUI apps (the default). Smoke test — the `TMPDIR` part is required, otherwise `docker exec` mounts a temp dir over `/tmp` and hides the X socket:

```powershell
MSYS_NO_PATHCONV=1 TMPDIR=$env:TEMP docker exec -e DISPLAY=:0 ubuntu24-dev-box xeyes
```

If no `X0` socket is mounted, Xvfb on `:99` starts automatically and noVNC still works.

Chromium opens **once**, when the container starts. Closing the window closes it — it does not pop back. To open it again:

```powershell
docker exec ubuntu24-dev-box open-chromium
```

or `docker exec ubuntu24-dev-box supervisorctl start chromium`.

**Linux hosts:** use `xhost +local:docker` and bind-mount `/tmp/.X11-unix:/tmp/.X11-unix` instead of the WSLg path.

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

```bash

supervisorctl status
tail -n 50 /var/log/supervisor/sing-box.err.log

```

- **`http://localhost:6901` shows a directory listing instead of the browser** → the URL is missing the client page. Open <http://localhost:6901/vnc.html>. The image ships an `index.html` that redirects there, so a bare `/` works too after a rebuild.

- **noVNC shows black screen** → `supervisorctl status xvfb fluxbox x11vnc`. Restart with `supervisorctl restart xvfb`.

- **`setup-vpn.sh` failed at first start** (404, network) → exec into the container, fix `VERSION=` in `/etc/sing-box/setup-vpn.sh`, then `supervisorctl restart sing-box`.

- **Container recreates and loses everything** → expected; mount `./workspace` for persistent data.
