# Infraestrutura no Mac mini

Como o Watch Pilot fica **no ar depois de um reboot**, sem depender de login gráfico,
de systemd (não existe no macOS) nem de cliques manuais.

## O que tem de sobreviver a um arranque

Três coisas independentes. Perder qualquer uma deixa `https://watch.kluser.me` em 404
ou 502:

| # | Peça | Quem a garante |
|---|---|---|
| 1 | `uvicorn` a escutar em `127.0.0.1:8765` | LaunchDaemon `com.watchpilot.hub` |
| 2 | rota `watch.kluser.me` no túnel + CNAME na zona | o *watchdog* dentro do mesmo daemon |
| 3 | runner/zona do túnel (`cfx-kluser-me-bbc49a`) | o watchdog, via `domain.py up` |

## O obstáculo: TCC e `/Volumes`

Um job de `launchd` — **mesmo como root** — recebe `Operation not permitted` ao ler
`/Volumes/Ext2TB` no macOS 27. A única sessão que herda a Full Disk Access é a do
`sshd-keygen-wrapper`. Por isso o daemon **não** corre o hub diretamente: abre um SSH
para `127.0.0.1` com uma chave dedicada cujo `authorized_keys` tem

```
command="/Users/minim1/.local/bin/watch-pilot-hub.sh",restrict,from="127.0.0.1,::1"
```

e o hub nasce **dentro** dessa sessão, com FDA. É o mesmo padrão que o
`com.ondokai.mac-kluser-web` já usa para o `mac.kluser.me`.

## O daemon

```
/Library/LaunchDaemons/com.watchpilot.hub.plist   (root:wheel 644, UserName=minim1)
   └── /usr/bin/ssh -i ~/.ssh/watchpilot_hub_ed25519 -T minim1@127.0.0.1
          └── command=~/.local/bin/watch-pilot-hub.sh
                 ├── nohup setsid ~/.local/bin/watch-pilot-route.sh   (watchdog)
                 └── uvicorn app.main:app --host 127.0.0.1 --port 8765 (foreground)
```

- `RunAtLoad` + `KeepAlive` + `ThrottleInterval=20` + `ProcessType=Background`.
- Logs em `~/.local/state/watchpilot/{launchd,uvicorn,route-watch}.log` (nunca em
  `/var/log`, que daria `EX_CONFIG`).
- O uvicorn corre como **filho** e não por `exec`: assim o trap do wrapper leva-o
  abaixo quando a sessão termina. Com `exec`, um `bootout`/reboot deixava um órfão a
  segurar a porta e o arranque seguinte morria com `address already in use`.
- Antes de carregar, o instalador liberta a porta de processos não supervisionados
  (`lsof -tiTCP:8765 -sTCP:LISTEN`).

Instalar ou atualizar:

```bash
sudo bash scripts/install-launchd.sh          # idempotente
sudo launchctl print system/com.watchpilot.hub | grep -E "state|runs"
```

## O watchdog de rota

`scripts/watch-pilot-route.sh` (instalado em `~/.local/bin/`), em ciclo de 30 s:

1. lê a porta do router da zona em
   `~/.local/state/cloudflare-agent-skill/zones/kluser.me/runtime.json`;
2. pergunta ao router local por `Host: watch.kluser.me`;
3. se obtiver **404** (rota apagada) ou **000** (router morto), re-afirma a rota com
   `domain.py up … --name watch --no-gate --no-persist`;
4. a cada 5 min confirma a edge (`https://watch.kluser.me/__health`); duas falhas
   seguidas forçam a re-afirmação.

Respeita `~/.local/state/kluserme/heal-pause` (escrito por `kluserme off`/defcon) e
nunca toca no apex, nas Page Rules, no `mac.kluser.me` nem no `defcon4`.

## Medido neste Mac mini

Teste feito a partir de um estado frio (serviço parado, rota apagada, porta livre):

| Instante | Estado |
|---|---|
| +5 s | hub a responder `200` em `127.0.0.1:8765` |
| +20 s | rota recriada no túnel (`runtime.json` volta a listar `watch.kluser.me`) |
| +42 s | `https://watch.kluser.me/__health` → `200` (propagação DNS da edge) |
| — | `launchctl print` mostra `runs = 1` (sem ciclo de reinícios) |

## Portas

| Porta | Dono |
|---|---|
| `3080` | DSH (`linux.kluser.me` / `mac.kluser.me`) — **reservada** |
| `8787` | Trello Orbit — **reservada** |
| `8790` | kill-switch DEFCON — **reservada** |
| `8765` | **Watch Pilot hub** (este projeto) |

O hub escuta só em `127.0.0.1`; o acesso público passa exclusivamente pelo túnel.

## TOTP em duas camadas

- **Edge (`kluser.me`)**: o zone-runner põe um formulário TOTP em todas as rotas e
  responde `401` a *qualquer* método não-GET sem cookie — um relógio não consegue
  preencher esse formulário. Por isso `watch.kluser.me` está em `exempt` no `auth.json`
  do zone-dir (backup ao lado, 0600, hot-reload em 500 ms). É feito uma vez por
  `scripts/publish.sh` / `scripts/exempt-host.py`.
- **Aplicação**: o hub verifica `X-Watch-TOTP` em **cada** pedido (RFC 6238, SHA1,
  6 dígitos, 30 s, ±1 período), com guarda de replay monotónica por chave e
  rate-limit de 5 falhas/300 s.

## Comandos de bolso

```bash
# estado
sudo launchctl print system/com.watchpilot.hub | grep -E "state|runs"
tail -f ~/.local/state/watchpilot/route-watch.log
curl -s http://127.0.0.1:8765/__health
curl -s -o /dev/null -w '%{http_code}\n' https://watch.kluser.me/__health

# republicar à mão (o watchdog faz isto sozinho)
scripts/publish.sh

# parar por completo
sudo launchctl bootout system /Library/LaunchDaemons/com.watchpilot.hub.plist
pkill -f watch-pilot-route.sh
```
