# Instructions to start development



Dockerized Ubuntu 24.04 dev box: Chromium (proxied via sing-box TUN), code-server, Claude Code.



\## Prerequisites



\- Docker Engine + Compose v2 (`docker compose version`)

\- \*\*Windows\*\*: Docker Desktop with WSL2 backend

\- \*\*Linux\*\*: `xhost` (for `x11-xserver-utils`) — not needed for noVNC access, only if you switch to native window later



\## docker environment setup



```bash / powershell



git clone https://github.com/Macsik121/developer-infra



cd developer-infra



```



(if there's not docker on the system, come and take it: https://github.com/Macsik121/setup-vpn)



build the image and start the container

\*On windows:\* run

```powershell .\\run-env.ps1 ```



\*On Linux:\* run

```bash ./run-env.sh ```



\## Container workflow



access terminal after docker environment setup through: docker exec -it ubuntu24-dev-box bash



\### terminal 1

```bash



cd /etc/sing-box



chmod +x setup-vpn.sh



./setup-vpn



```



\### terminal 2

```bash



cd /etc/sing-box



chmod +x test-connection.sh



./test-connection



```



\### terminal 3 - specifically after setting up omniroute custom provider, you start claude

```bash



chmod +x start-claude.sh



./start-claude



```



\### Omniroute custom provider setup



1\. get your api keys



2\. setup omniroute



```bash omniroute ```



2.1. Go to: Providers -> API Key Compatible Providers -> Add OpenAI Compatible Key(if doesn't work, try Anthropic compatible).



2.2. Далее указываем:

prefix: ...

provider-id-suffix: ...

api type: responses api

base url: https://...

api key: один из купленных



Заходим на только что созданного провайдера.



2.3. + Add



В форме:

name: your-API-key

API Key: your-API-key



Click "Save".



Retest -> Test message



3\. write \~/.claude/settings.json and replace "your-custom-model-id" with the model name you copied from omniroute.



Example:

{

&#x20; "switchModelsOnFlag": false,

&#x20; "modelOverrides": {

&#x20;   "claude-sonnet-5": "your-custom-model-id",

&#x20;   "claude-haiku-5.5": "your-custom-model-id",

&#x20;   "claude-opus-5.5": "your-custom-model-id"

&#x20; }

}

