# developer-infra

Кроссплатформенная изолированная dev-среда на базе **Ubuntu 24.04** в Docker:
- **VPN-туннель (`sing-box 1.12` TUN)** с динамическим обновлением подписки (VLESS Reality/gRPC + Hysteria2), балансировкой протоколов, параллельным TCP pre-probe (`SO_MARK=255`), `urltest` + `selector`, и жёстким **IPv4 + IPv6 + Docker DNS (`127.0.0.11`) kill-switch** (`vpn-ctl`).
- **Встроенный VPN Status Dashboard (`http://127.0.0.1:9099`)** внутри контейнера — стартовая вкладка Chromium с живым статусом `sing-box`, активной нодой, пингом, внешним IP и последними ошибками (без проброса наружу).
- **Chromium** (нативное окно на Windows через **WSLg** с чистым отключением fallback-демонов, или полностью изолированный **noVNC** на Linux / Hyper-V / удалённых серверах).
- **code-server** (VS Code в браузере с обязательной аутентификацией).
- **Изолированный AI-стек (`OmniRoute` + `Claude Code`)** внутри контейнера с персистентными volumes и маршрутизацией всего трафика через `sing-tun`.

---

## 1. Требования

- **Docker Engine + Docker Compose v2** (`docker compose version`).
- **Windows:** Docker Desktop (WSL2 backend для нативного окна WSLg; либо Hyper-V backend в режиме `headless`).
- **Linux Desktop / Remote Server:** Docker Engine с доступом к `/dev/net/tun` и `NET_ADMIN`.

---

## 2. Быстрый старт

### Шаг 1. Подготовка `.env`
```bash
git clone https://github.com/Macsik121/developer-infra
cd developer-infra
cp .env.example .env
```

Откройте `.env` и обязательно задайте:
- `CODE_SERVER_PASSWORD` (минимум 6 символов, без `CHANGE_ME` / `devpassword123`);
- `VNC_PASSWORD` (минимум 6 символов, для входа в noVNC);
- `VPN_SUBSCRIPTION_URL` — ссылка на динамическую подписку (например, `https://sub.example.com/...`), либо оставьте пустой для работы от локального `./sing-box/config.json` (шаблон — в `sing-box/config.json.example`).

> **Важно про `VPN_ALLOW_INSECURE`, `VPN_MTU` и `VPN_PROBE_NODES`:**
> - По умолчанию `VPN_ALLOW_INSECURE=0` — ноды с `insecure=1` / `allowInsecure=1` / self-signed `pcs=` пропускаются (`skipped_insecure=...`). Если часть нод провайдера (например, Hysteria2) использует self-signed сертификаты и вы им доверяете, выставьте `VPN_ALLOW_INSECURE=1`.
> - `VPN_MTU=1280` гарантирует работу без blackhole-фрагментации, даже если на хосте параллельно включён другой VPN/TUN.
> - `VPN_PROBE_NODES=1` перед запуском проверяет TCP-доступность до 120 кандидатов (деприоритизируя RU/LTE/мост-ноды) и загружает в `sing-box` рабочие и быстрые ноды.

### Шаг 2. Проверка портов и быстрый двухэтапный запуск (`lite` → `full`, Pull-First GHCR)

Чтобы не зависеть от нестабильного интернета при локальной сборке (`apt`/PPA/GitHub) и не ждать установку тяжёлых инструментов (`Node.js 22`, `code-server`, `Claude Code`, `OmniRoute`) до проверки VPN, предусмотрены два multi-stage профиля (`DEV_INFRA_PROFILE` в `.env` или флаг `-Profile` / `--profile`) и **автоматический pull готовых multi-arch образов (`linux/amd64`, `linux/arm64`) из GHCR**:
- **`lite`** (`${DEV_INFRA_IMAGE}:lite`) — только сеть, `sing-box` VPN, X11/noVNC и **Chromium** (мгновенный старт из GHCR без `apt`/PPA).
- **`full`** (`${DEV_INFRA_IMAGE}:full`, по умолчанию) — добавляет `code-server`, `Node.js 22`, `OmniRoute` и `Claude Code` (при локальной сборке на 100% переиспользует BuildKit-кэш `lite`).

По умолчанию `run-env.ps1` / `run-env.sh` работают в режиме **Pull-First**: сначала пытаются скачать `${DEV_INFRA_IMAGE}:${DEV_INFRA_PROFILE}` (по умолчанию `ghcr.io/macsik121/developer-infra`), а если образ недоступен (офлайн, форк ещё не опубликован или пакет приватный) — автоматически откатываются на локальную сборку BuildKit. Для принудительной локальной сборки используйте `-LocalBuild` / `--local-build`, для запуска уже скачанного/собранного образа — `-NoBuild` / `--no-build`.

> **Для владельца репозитория / форка (GHCR + Offline tarball):**
> - GitHub Actions workflow `.github/workflows/release-images.yml` автоматически собирает и публикует multi-arch теги `:lite`, `:full`, `:latest` и `vX.Y.Z` в `ghcr.io/<owner>/<repo>` при пуше в `main` или теге `v*`.
> - После первой публикации откройте **GitHub → Packages → `developer-infra` → Package settings → Change visibility → Public**, чтобы `docker pull` работал без `docker login`.
> - Для передачи образа офлайн («флешкой») запустите workflow `Release Multi-Arch GHCR Images` вручную (`workflow_dispatch`) с галочкой **`export_lite_tarball=true`** и загрузите на целевом ПК через `docker load -i developer-infra-lite-amd64.tar.gz`, затем `.\run-env.ps1 -Profile lite -NoBuild -AutoPort`.

На Windows (особенно с Hyper-V/WinNAT) порты вроде `8080` могут попадать в системный `excludedportrange` (`WSAEACCES`). Перед запуском или автоматически при старте используйте встроенный preflight:

#### Windows (PowerShell, Docker Desktop + WSL2/WSLg)
```powershell
# Однократно после распаковки архива снять блокировку Windows MOTW:
Get-ChildItem -Filter *.ps1 | Unblock-File

# Проверить занятость портов, владельцев и наличие хостового VPN:
.\run-env.ps1 -CheckPorts

# Этап 1 (быстрый старт из GHCR): поднять только VPN + Chromium и проверить сеть:
.\run-env.ps1 -Profile lite -AutoPort -Detach
.\diag-env.ps1

# Этап 2 (после успешной проверки VPN): поднять полный образ IDE + AI-стек:
.\run-env.ps1 -Profile full -AutoPort

# Принудительная локальная сборка из Dockerfile (без pull):
.\run-env.ps1 -Profile lite -AutoPort -LocalBuild

# Повторный запуск уже скачанного/собранного образа без pull/build:
.\run-env.ps1 -NoBuild -AutoPort
```

#### Windows (Hyper-V или без WSLg — только noVNC)
```powershell
.\run-env.ps1 -Mode headless -Profile lite -AutoPort -Detach
.\run-env.ps1 -Mode headless -Profile full -AutoPort
```

#### Linux Desktop / Удалённый Linux-сервер (изолированный noVNC)
```bash
chmod +x run-env.sh vpn-ctl.sh diag-env.sh collect-logs.sh scripts/smoke-test.sh
./run-env.sh --check-ports
./run-env.sh --profile lite --auto-port --detach
./diag-env.sh
./run-env.sh --profile full --auto-port
# Принудительная локальная сборка: ./run-env.sh --profile lite --auto-port --local-build
```

#### Удалённый Linux-сервер через SSH-туннель
Контейнер по умолчанию слушает только `BIND_HOST=127.0.0.1`. Подключайтесь через SSH port-forwarding:
```bash
ssh -L 8080:127.0.0.1:8080 -L 6901:127.0.0.1:6901 -L 20128:127.0.0.1:20128 user@remote-server
```

---

## 3. Доступ к сервисам

| Сервис | Адрес (по умолчанию) | Аутентификация |
| :--- | :--- | :--- |
| **code-server (VS Code)** | `http://127.0.0.1:8080` | `CODE_SERVER_PASSWORD` из `.env` |
| **Chromium (noVNC)** | `http://127.0.0.1:6901/vnc.html` | `VNC_PASSWORD` из `.env` |
| **OmniRoute UI** | `http://127.0.0.1:20128` | Локальный доступ (`127.0.0.1`) |
| **VPN Status Dashboard** | `http://127.0.0.1:9099` *(только внутри Chromium/контейнера)* | Read-only (без секретов) |

Стартовая страница Chromium настраивается через `CHROMIUM_START_URL` (по умолчанию `http://127.0.0.1:9099`).

---

## 4. Управление VPN и Kill-Switch (`vpn-ctl`)

Пользователь `coder` (и AI-агент `Claude Code`) **не имеет `sudo`**, не видит секретов из `.env` и не может отключить kill-switch. Внутри контейнера `coder` доступен read-only `vpn-ctl status` (включая активную ноду, задержку, живой IP и последние ошибки). Изменение режимов выполняется **с хоста**:

| Действие | Windows (PowerShell) | Linux / macOS |
| :--- | :--- | :--- |
| Статус VPN, активная нода, живой IP | `.\vpn-ctl.ps1 status` | `./vpn-ctl.sh status` |
| Активная egress-политика (allowlist) | `.\vpn-ctl.ps1 policy` | `./vpn-ctl.sh policy` |
| Жёсткий kill-switch (дефолт, TUN) | `.\vpn-ctl.ps1 strict` | `./vpn-ctl.sh strict` |
| Авто-fallback при падении VPN (TUN) | `.\vpn-ctl.ps1 fallback` | `./vpn-ctl.sh fallback` |
| Режим прокси без TUN (`127.0.0.1:2080`) | `.\vpn-ctl.ps1 proxy` | `./vpn-ctl.sh proxy` |
| Прямой выход через сеть/VPN хоста | `.\vpn-ctl.ps1 direct` | `./vpn-ctl.sh direct` |
| Принудительно обновить подписку + pre-probe | `.\vpn-ctl.ps1 update` | `./vpn-ctl.sh update` |
| Замерить задержку всех нод (`urltest`) | `.\vpn-ctl.ps1 retest` | `./vpn-ctl.sh retest` |
| Нумерованный список нод / выбор по номеру | `.\vpn-ctl.ps1 select` / `.\vpn-ctl.ps1 select 2` | `./vpn-ctl.sh select` / `./vpn-ctl.sh select 2` |

> **Политика доменов для AI-агента (`VPN_AGENT_POLICY`, opt-in):**
> - По умолчанию `VPN_AGENT_POLICY=open` — обычный безлимитный выход через VPN.
> - При `VPN_AGENT_POLICY=allowlist` `sing-box` пропускает TCP/UDP и DNS **только** к доменам из пресетов `VPN_ALLOW_PRESETS` (`ai,git,pkg,docs` или `none`) + `VPN_ALLOW_DOMAINS` (и служебных `ipinfo.io` / `www.gstatic.com` / хоста подписки), отклоняя остальные подключения и DNS-запросы (`action: reject`).

> **Совместная работа с VPN на хосте:**
> - **Независимый VPN контейнера (дефолт `strict`):** контейнер строит собственный `sing-tun` (MTU `1280`, `fwmark 0xff`), полностью независимый от отключений VPN на хосте.
> - **Если на хосте уже включён VPN и хочется использовать его IP:** выполните `.\vpn-ctl.ps1 direct` (весь трафик контейнера пойдёт через сеть/TUN хоста).
> - **Только точечный прокси без контейнерного TUN:** выполните `.\vpn-ctl.ps1 proxy` и запускайте браузер через `open-chromium --proxy` (или `HTTP_PROXY=http://127.0.0.1:2080`).

---

## 5. Шпаргалка по ежедневной работе (Day-2 Operations)

| Задача | Команда на хосте |
| :--- | :--- |
| Зайти в работающий контейнер как `coder` | `docker compose exec -it -u coder -w /home/coder/workspace ubuntu-dev bash` |
| Зайти в контейнер с правами `root` *(пароль не нужен — `sudo` удалён для `coder`)* | `docker compose exec -it -u root ubuntu-dev bash` |
| Посмотреть состояние всех сервисов `supervisord` | `docker compose exec -u root ubuntu-dev supervisorctl status` |
| Открыть Chromium повторно после закрытия | `docker compose exec -u coder ubuntu-dev open-chromium` *(или `open-chromium --proxy`)* |
| Посмотреть логи `sing-box` / updater / watchdog | `docker compose exec -u root ubuntu-dev tail -n 50 /var/log/supervisor/sing-box.err.log` |
| Логи подписки и TCP pre-probe | `docker compose exec -u root ubuntu-dev tail -n 50 /var/log/supervisor/vpn-sub-updater.out.log` |
| Остановить контейнер *(volumes сохраняются)* | `docker compose down` |

---

## 6. Работа с OmniRoute и Claude Code (изолированно)

Весь AI-стек (`omniroute` + `claude`) работает **только внутри контейнера** под управлением `supervisord`, а его состояние сохраняется в named volumes (`claude-state`, `omniroute-state`).

### Настройка провайдера в OmniRoute
1. Откройте `http://127.0.0.1:20128` в браузере (или внутри Chromium в контейнере).
2. Перейдите в **Providers → API Key Compatible Providers → Add OpenAI Compatible Key** (или Anthropic Compatible).
3. Укажите `prefix`, `provider-id-suffix`, `api type`, `base url` и ваш API-ключ → **Save** → **Retest**.
4. При необходимости добавьте ключ в `.env` как `ANTHROPIC_AUTH_TOKEN` (либо вводите интерактивно при запуске).

### Запуск Claude Code
**С Windows (тонкий wrapper — не запускает Node/Claude на хосте):**
```powershell
.\start-claude.ps1
.\start-claude.ps1 -Command "claude" -Model 1
.\start-claude.ps1 -AddModel
```

**Внутри контейнера (Linux / code-server терминал):**
```bash
start-claude
start-claude -c "claude" -m 1
start-claude --add-model
```
Реестр моделей хранится в `~/.config/omniroute/claude_models.json` (named volume `omniroute-state`).

---

## 7. Мультиинстансный / мультипользовательский режим

Каждый экземпляр изолируется отдельным `.env` файлом с уникальными `COMPOSE_PROJECT_NAME`, `WORKSPACE_DIR` и портами (или с флагом `--auto-port` / `-AutoPort`):

```bash
cp .env.example .env.dev2
# Задайте в .env.dev2:
#   COMPOSE_PROJECT_NAME=devbox-dev2
#   WORKSPACE_DIR=./workspace-dev2
#   CODE_SERVER_PORT=8081
#   NOVNC_PORT=6902
#   OMNIROUTE_PORT=20129
#   CPUS=2 / MEM_LIMIT=4g / SHM_SIZE=1g   # пресет Shared Server

./run-env.sh --env-file .env.dev2 --detach
./vpn-ctl.sh --env-file .env.dev2 status
```

> **Заметка для серверов с 15+ контейнерами:** Настройте `default-address-pools` в `/etc/docker/daemon.json`:
> ```json
> {
>   "default-address-pools": [
>     { "base": "10.200.0.0/16", "size": 24 }
>   ]
> }
> ```

---

## 8. Верификация и тестирование

### Автотесты репозитория
На **Linux / WSL**:
```bash
python3 -m unittest discover -s tests -v
```
На **Windows (PowerShell)**:
- Быстрый прогон (автоматически пропускает POSIX bash-тесты): `python -m unittest discover -s tests -v`
- Полный 100% прогон **включая POSIX-скрипты** внутри образа `:lite` (или `:full`):
```powershell
docker run --rm --entrypoint python3 -v "$($PWD.Path):/repo:ro" -w /repo ghcr.io/macsik121/developer-infra:lite -m unittest discover -s tests -v
```

### Живой Smoke-Test и полная системная диагностика
```bash
./scripts/smoke-test.sh
# С активной проверкой блокировки IPv4 + Docker DNS (127.0.0.11) при остановке sing-box:
./scripts/smoke-test.sh --test-killswitch
```

**Полный аудит системы + сбор логов (работает с хоста на Windows и Linux, сохраняет отчёт в `diagnostics/`):**
```powershell
# Windows (PowerShell):
.\diag-env.ps1                     # полный аудит: supervisor, сеть (L3/DNS/L7 TUN + :2080), vpn-ctl, SO_MARK=255 и все логи
.\diag-env.ps1 -LogScope ask       # полный аудит + интерактивный выбор группы логов
.\collect-logs.ps1                 # отдельный интерактивный сборщик логов (all / vpn / gui / dev / один пакет)
.\collect-logs.ps1 -Scope vpn -Lines 50
```
```bash
# Linux / macOS / WSL:
./diag-env.sh                      # полный аудит системы
./collect-logs.sh                  # интерактивный сборщик логов
./collect-logs.sh --scope vpn --lines 50
```
Все собранные диагностические файлы автоматически маскируют секреты/токены и не попадают в git (`diagnostics/` в `.gitignore`).

---

## 9. Troubleshooting

- **Нет интернета при поднятом `sing-tun` (`DEGRADED_NO_EGRESS` или `ping` проходит, а `curl`/Chromium падают):**
  1. Запустите `.\diag-env.ps1` (или `./diag-env.sh`) — скрипт проверит `supervisorctl`, маршрутизацию, реальный L7-выход через TUN и прокси `:2080`, прямой TCP `SO_MARK=255` до нод и сложит подписанные логи в `diagnostics/diag-<timestamp>/`.
  2. Выполните `.\vpn-ctl.ps1 status` — проверьте `Reachable` и `Recent Errors`.
  3. Прогоните `.\vpn-ctl.ps1 retest` и `.\vpn-ctl.ps1 select` → выберите рабочую ноду по номеру (`.\vpn-ctl.ps1 select 2`).
  4. Запустите `.\vpn-ctl.ps1 update` — TCP pre-probe автоматически отсеет недоступные ноды и выберет рабочие (при «мёртвом» туннеле выполняется авто-восстановление через `bootstrap-allow` + `fwmark 0xff`).
  5. Если в логе `skipped_insecure > 0`, установите `VPN_ALLOW_INSECURE=1` в `.env` и перезапустите контейнер.
- **Конфликт портов / `WSAEACCES` на Windows (`bind: An attempt was made to access a socket in a way forbidden`):**
  - Запустите `.\run-env.ps1 -CheckPorts`, чтобы увидеть точную причину (процесс, другой контейнер `developer-infra` или `WinNAT excludedportrange`), и запускайте через `.\run-env.ps1 -AutoPort`.
- **Ошибка `KILLSWITCH_ERROR` в статусе:** ядро хоста не поддерживает `xt_mark`. Обновите ядро WSL2 (`wsl --update`) или временно переключитесь на `direct`.
- **Чёрный экран в noVNC или медленный Chromium под WSLg:**
  - Убедитесь, что для Windows WSL2 используется `docker-compose.wslg.yaml` (дефолт `run-env.ps1`), а для Hyper-V/Linux — `docker-compose.headless.yaml` (`-Mode headless` / дефолт `run-env.sh`).
  - Для WSLg (`:0`) сервисы `xvfb`/`fluxbox`/`x11vnc`/`novnc` намеренно завершаются со статусом `EXITED` (это норма, не ошибка).
  - Если Chromium грузит CPU под WSLg, задайте `CHROMIUM_DISABLE_GPU=1` в `.env`.
- **Ошибка сборки `registry-1.docker.io` / `lookup ... on [::1]:53: connection refused` (без предварительного VPN на хосте):**
  1. **Не собирайте образ локально без надобности:** свежие `run-env.sh` / `run-env.ps1` сначала тянут готовый образ `${DEV_INFRA_IMAGE}:lite` из GHCR (в обход Docker Hub).
  2. **Сборка без Docker Hub:** `Dockerfile` больше не использует `# syntax=docker/dockerfile:1` (нет запроса в `docker.io/docker/dockerfile:1`), а базовый образ по умолчанию берётся с официального Canonical AWS ECR (`BASE_IMAGE=public.ecr.aws/ubuntu/ubuntu:24.04`). При необходимости задайте в `.env` локальные зеркала:
     ```env
     BASE_IMAGE=dockerhub.timeweb.cloud/library/ubuntu:24.04
     APT_MIRROR=https://mirror.yandex.ru/ubuntu
     NPM_REGISTRY=https://registry.npmmirror.com
     ```
  3. **Если видите `lookup ... on [::1]:53: connection refused` на Linux/Ubuntu VM (например, `osboxes`):** у хоста/демона Docker сломан DNS (`/etc/resolv.conf`). Пропишите DNS и (опционально) зеркала в `/etc/docker/daemon.json` и перезапустите Docker:
     ```json
     {
       "dns": ["1.1.1.1", "8.8.8.8"],
       "registry-mirrors": [
         "https://dockerhub.timeweb.cloud",
         "https://mirror.gcr.io"
       ]
     }
     ```
     ```bash
     sudo systemctl restart docker
     ```
- **Проверка конфигурации Compose перед запуском:**
  ```bash
  docker compose -f docker-compose.yaml -f docker-compose.wslg.yaml config
  docker compose -f docker-compose.yaml -f docker-compose.headless.yaml config
  ```
