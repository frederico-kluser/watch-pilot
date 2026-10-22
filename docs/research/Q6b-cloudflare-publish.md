---
tipo: resposta-pesquisa
pergunta: "Q6b — publicar o hub FastAPI local como watch.kluser.me no Mac mini, sem tocar no apex"
criado: 2026-10-22
maquina: "macmini minim1 · macOS 27.0 (26A428) · arm64 · Darwin 27.0.0"
estado: respondida
confianca: alta (medido nesta máquina; nada de Cloudflare foi alterado)
---

# Q6b — mecânica de publicação local (`watch.kluser.me` no Mac mini)

> Todas as observações foram feitas **nesta** máquina (macmini `minim1`) em 2026-10-22, em modo
> **read-only**: `domain.py list`/`--help`, leitura do zone-dir, `ps`, `dig`, `GET` pela edge e
> um probe de TCC com LaunchAgent temporário (criado e removido). **Nada** foi publicado, alterado
> ou derrubado; o apex, `www`, Page Rules e o túnel do Acer não foram tocados.

## 0. TL;DR — o comando e as 3 obrigações

**Porta recomendada: `8420`** (livre agora; `3080`/`8787`/`8790` são reservadas do kluser.me e
`8765` está ocupada por outro processo).

```bash
# 1) app local a correr em 127.0.0.1:8420 (senão o `up` publica na mesma e reporta app-down)
# 2) publicar (NÃO usar --persist: não há systemd; ver §4)
CLOUDFLARE_EXPOSE_WILDCARD=0 CLOUDFLARE_EXPOSE_DOMAIN=kluser.me \
  /usr/bin/python3 /Volumes/Ext2TB/Agent-Skills/cloudflare-agent-skill/scripts/expose-port/domain.py \
  up 'http://127.0.0.1:8420' --domain kluser.me --name watch --no-gate --no-persist

# 3) OBRIGATÓRIO: isentar o host do TOTP do zone-runner (senão a app recebe 401 em todo o POST)
#    ver §3 — sem este passo a URL fica inútil para a app do Watch.
```

Três factos que mudam o plano:

1. **`auth.json` está LIGADO** neste Mac (`enabled:true`, `exempt:["defcon4.kluser.me"]`). Toda a
   rota nova nasce **atrás do form TOTP** → `POST /api/*` de um cliente móvel leva **401 seco**.
   Publicar exige acrescentar `watch.kluser.me` ao `exempt` (§3).
2. **Já existe o curinga `*.kluser.me`**, mas é **do Acer** (`cfx:281dd0` → túnel
   `ed6d24d7-…cfargotunnel.com`). Hoje `https://watch.kluser.me/` devolve **404 “Nada publicado”**
   do router do Acer. O `up` no Mac cria o **CNAME próprio** de `watch.kluser.me` → túnel do Mac
   (`0a5203f8-…`), sem tocar no curinga nem no apex.
3. **Persistência só via launchd** — e um job de launchd **não lê `/Volumes/Ext2TB`** (TCC; medido,
   §5). O padrão que funciona nesta máquina (e que já mantém o `mac.kluser.me`) é
   **LaunchDaemon → `ssh` para 127.0.0.1 → forced command** (§5).

## 1. Q6b.1 — comando exato, env e o que acontece por baixo

### 1.1 Comando

```bash
CLOUDFLARE_EXPOSE_WILDCARD=0 CLOUDFLARE_EXPOSE_DOMAIN=kluser.me \
  /usr/bin/python3 /Volumes/Ext2TB/Agent-Skills/cloudflare-agent-skill/scripts/expose-port/domain.py \
  up 'http://127.0.0.1:8420' \
  --domain kluser.me --name watch --no-gate --no-persist
```

Alternativas de forma (equivalentes, o script normaliza o alvo):

```bash
… up 8420 --name watch …            # porta nua
… up localhost:8420 --name watch …  # 127.0.0.1/localhost/::1 contam como o MESMO upstream
… up 'http://127.0.0.1:8420/api' …  # path preservado → https://watch.kluser.me/api
```

`--name watch` → `hostname_for("watch","kluser.me")` → `watch.kluser.me` (1 nível abaixo da zona;
o Universal SSL grátis só cobre `*.kluser.me`). FQDN (`--name watch.kluser.me`) também é aceito.

### 1.2 Env vars — o que é mesmo preciso

| Variável | Necessária? | Porquê |
|---|---|---|
| `CLOUDFLARE_EXPOSE_WILDCARD=0` | **Sim, obrigatório nesta máquina** | Regra do `macmini`/`kluser-me`: se o Mac criar/roubar `*.kluser.me`, parte o `trello`/`linux` do Acer. Hoje é inócuo (a zona já existe e `zone.json` tem `wildcard_id: None`, logo `ensure_zone()` sai cedo), mas fica como trava para qualquer recriação de zona. |
| `CLOUDFLARE_EXPOSE_DOMAIN=kluser.me` | Não (já está) | Já gravado em `~/.config/cloudflare-agent-skill/config.env`. Explícito não faz mal. |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | **Não** | Carregados sozinhos de `~/.config/cloudflare-agent-skill/credentials.env` (0600, presente: token de 53 chars). Precedência: env → `credentials.env` → `config.env`. |
| `CLOUDFLARE_SKILL_DIR` | **Não** para o `domain.py` | É lido **só** pelo `kluser.py` (ver §1.5). O `domain.py` não conhece esta variável. |
| `CLOUDFLARE_CREDENTIALS_FILE` | Não | Só para apontar outro ficheiro de credenciais. |
| `CFX_STATE_DIR` / `XDG_STATE_HOME` | Não | Mudariam o zone-dir (`~/.local/state/cloudflare-agent-skill/zones/kluser.me`) — **não** usar. |

### 1.3 O que o `up` faz, por ordem

1. `prepare()`: acha `cloudflared` (`/opt/homebrew/bin/cloudflared` 2026.8.2) e Node
   (`/Users/minim1/.local/bin/node` v24.19.0); já há credencial → sem login no browser.
2. `resolve_domain()`: `--domain` > `CLOUDFLARE_EXPOSE_DOMAIN` (config.env) → `kluser.me`.
3. `local_alive()`: aviso se nada escuta em `127.0.0.1:8420` (publica mesmo assim).
4. `Lock()` (`flock` em `~/.local/state/cloudflare-agent-skill/.lock`).
5. `ensure_zone("kluser.me")`: **já existe** `zone.json` + `creds.json` → reutiliza o túnel
   `cfx-kluser-me-bbc49a` (`0a5203f8-3f73-4cdc-9d7d-20a30eeb4437`) e **não** mexe no curinga.
6. `prune_stale()`: apaga rotas **efémeras de um boot anterior** (ver §4 — isto apaga o CNAME do
   `watch` depois de um reboot!).
7. DNS: `ensure_host_dns()` → `dns_records(zid,"watch.kluser.me")` filtra por **nome exato**, por isso
   o curinga **não** aparece. Hoje **não há registo exato** (medido via API, read-only) → `dns_upsert()`
   cria `CNAME watch.kluser.me` → `0a5203f8-….cfargotunnel.com`, `proxied:true`, `ttl:1`,
   `comment: "cfx:bbc49a: cloudflare-agent-skill domain.py …"` (`bbc49a` = tag do Mac). Nada de
   `--force` é preciso.
8. `save_routes()` (`routes.json` v11 → v12), `apply_runner()`:
   - `systemd_ok()` = **False** (não há `systemctl` em macOS) → arranca/reutiliza o
     `zone-runner.mjs` como processo **`setsid`** em background com log em `runner.log`;
   - router já vivo (pid 86536, `proxy_port: 59625`) → manda **SIGHUP** (reload das rotas, ~50 ms).
9. `wait_runner()`: espera o `runtime.json` refletir `routes_version` novo.
10. `probe()` (pela edge, sem DNS recursivo): pergunta o A record ao **autoritativo** da zona
    (`cleo.ns.cloudflare.com`) e liga-se ao IP da edge por socket+TLS com SNI = host (`edge_get`);
    confirma `/__cfx-health` → `x-cfx-proxy: ok` e depois faz `GET /` real.
11. Imprime o contrato: bloco com host/upstream/túnel/modo/verificação e, na última linha,
    **`URL=https://watch.kluser.me/`** (+ `down` command). `--json` dá o mesmo em JSON.

### 1.4 O que fica onde (paths absolutos)

| Item | Caminho |
|---|---|
| Skill (fonte de verdade) | `/Volumes/Ext2TB/Agent-Skills/cloudflare-agent-skill/scripts/expose-port/domain.py` |
| Atalho equivalente | `/Users/minim1/.dsh/skills/cloudflare-agent-skill` → symlink para o anterior |
| Zone-dir | `/Users/minim1/.local/state/cloudflare-agent-skill/zones/kluser.me/` |
| Rotas | `…/routes.json` (0600) · runtime do router: `…/runtime.json` · log: `…/runner.log` |
| Router (zone-runner) | `/Volumes/Ext2TB/Agent-Skills/cloudflare-agent-skill/scripts/expose-port/zone-runner.mjs` |
| Cloudflared config | `…/cloudflared.yml` (reescrito a cada start) |
| Credenciais | `~/.config/cloudflare-agent-skill/{credentials.env,config.env}` (0600) |

### 1.5 Via `kluser.py` (inventário) — **não funciona tal e qual neste Mac**

`/Volumes/Ext2TB/Agent-Skills/kluser-me-agent-skill/scripts/kluser.py` é a via “com inventário”
(`add watch http://127.0.0.1:8420 --no-gate`), mas hoje falha por dois motivos:

- `SKILL_CANDIDATES` só tem caminhos `/home/ondokai/…` → precisa de
  `CLOUDFLARE_SKILL_DIR=/Volumes/Ext2TB/Agent-Skills/cloudflare-agent-skill` (é **aqui**, e só aqui,
  que esta env var existe).
- `add` tem `--persist` **default `True`** → no Mac o `domain.py` morre com
  `Erro: --persist precisa de systemd --user (não disponível aqui)` (exit **3**). Seria preciso
  `--no-persist`.
- Não há registo local (`~/.config/kluser-me/routes.json` **não existe** neste Mac; o inventário
  canónico vive no Acer). Um `add` aqui criaria um registo novo com uma única entrada.

→ **Recomendação:** publicar com `domain.py` (§1.1) e registar no inventário do Acer
(`python3 scripts/kluser.py add watch http://127.0.0.1:8420 --no-gate --no-persist --note "Watch Pilot hub (macmini)"`)
quando fizer sentido — é o mesmo `up`, mas com registo.

## 2. Q6b.2 — o que está publicado neste Mac agora

`python3 …/domain.py list` (saída literal, 2026-10-22 13:05 -03):

```text
zona kluser.me · túnel cfx-kluser-me-bbc49a · sem curinga · router no ar (4 conexões)
  mac.kluser.me                http://127.0.0.1:3080      efémero      cname    no ar
```

`list --json`:

```json
{"zones":[{"zone":"kluser.me","tunnel":"cfx-kluser-me-bbc49a","wildcard":false,"running":true,
"connections":4,"routes":[{"host":"mac.kluser.me","alias_of":null,"upstream":"http://127.0.0.1:3080",
"persist":false,"gate":false,"dns":"cname","stale":false,"live":true}]}],"untracked_cloudflared":[]}
```

| Facto | Valor medido |
|---|---|
| Zona / zone-dir | `kluser.me` · `/Users/minim1/.local/state/cloudflare-agent-skill/zones/kluser.me` (0700) |
| Túnel | `cfx-kluser-me-bbc49a` = `0a5203f8-3f73-4cdc-9d7d-20a30eeb4437` (4 conexões: gru08/gru05/gru21) |
| Router | pid 86536 · `proxy_port: 59625` · `routes_version: 11` · `ready: true` |
| cloudflared | pid 86543 · `/opt/homebrew/bin/cloudflared 2026.8.2` · ingress catch-all → `127.0.0.1:59625` |
| Rotas | **só** `mac.kluser.me` → `127.0.0.1:3080` (efémera, `gate:false`, DNS = CNAME próprio) |
| `zone.json` | `wildcard_id: None` (este Mac **não** tem o curinga) · `machine tag: bbc49a` |
| `auth.json` | **EXISTE** 0600 — `enabled: true`, `totp{secret_hex 40 hex, digits 6, period 30, skew 1}`, `exempt: ["defcon4.kluser.me"]` |
| `inject.json` | **EXISTE** 0600 — `routes.linux.kluser.me.token`, `routes.mac.kluser.me.token` (43 chars; é o `?token=` do DSH) |
| `auth-state.json` | existe (replay/rate-limit do runner, 0600) |
| `systemctl` | **ausente** (`systemd_ok() == False`) |
| Túnel **do Acer** (não deste Mac) | `ed6d24d7-4742-4b02-b638-96f823775dbe.cfargotunnel.com`, tag `cfx:281dd0` |

DNS da zona (leitura read-only pela API v4, 2026-10-22):

| Nome | Registo | Comentário |
|---|---|---|
| `kluser.me` (apex) | CNAME proxied → túnel do **Acer** | `cfx:281dd0: …` (fallback dormente do DSH) |
| `*.kluser.me` | CNAME proxied → túnel do **Acer** | `cfx:281dd0: …` |
| `watch.kluser.me` | **sem registo exato** (hoje servido pelo curinga) | — |
| `www.kluser.me` | sem registo exato (coberto pelo curinga) | — |

Estado público atual (probes `GET`, nada alterado):

```text
GET https://watch.kluser.me/                 -> 404  "Nada publicado em watch.kluser.me."   (router do Acer)
GET https://watch.kluser.me/__cfx-health     -> 200  x-cfx-proxy: ok                       (router do Acer)
GET https://mac.kluser.me/__cfx-health       -> 200  x-cfx-proxy: ok                       (router do Mac)
```

## 3. Q6b.3 — TOTP do runner × API do Watch × `--no-gate`

### 3.1 O que o overlay faz (medido, no router local, sem passar pela Cloudflare)

Com `auth.json` como está hoje (`enabled:true`, `exempt:["defcon4.kluser.me"]`), um host **sem
isenção** comporta-se assim — testado com `Host: mac.kluser.me` contra `127.0.0.1:59625`:

```text
GET  /        -> 401  text/html  (form TOTP que faz POST /__cfx_totp__)   <- browser consegue
POST /api/x   -> 401  text/plain "401 Unauthorized — autenticação TOTP necessária"  <- cliente NÃO consegue
```

Ordem no `zone-runner.mjs`: `/__cfx-health` (isento, 200) → **TOTP** (`totpRequired(route) =
auth.enabled && !auth.exempt.has(route.host)`) → gate `?key=` → injecção `?token=` → proxy.
WebSocket: TOTP primeiro, 401 direto (sem form).

**Consequência para o Watch:** o cliente watchOS/iOS fala JSON (`POST /api/…`, provavelmente com
`Authorization`/TOTP próprios) e **nunca** preenche um form HTML nem guarda cookie
`__cfx_totp` (12 h, `HttpOnly; Secure; SameSite=Strict`). Sem isenção, **todo o POST morre em 401
seco** e a app não tem como se autenticar. O `?key=` também não resolve nada (é gate de browser).

### 3.2 `--no-gate` existe (confirmado no `--help`)

`domain.py up --help` (literal):

```text
  --gate, --no-gate     senha ?key= à frente da app (para apps SEM auth
                        própria)
```

`--gate`/`--no-gate` são `argparse.BooleanOptionalAction` com `default=None` (herda o que a rota já
tinha; rota nova → `False`). **`--no-gate` só desliga o `?key=`; NÃO desliga o TOTP do runner** —
o TOTP vive em `auth.json`, fora do `routes.json` (um `up` reescreve a rota inteira e apagaria
qualquer chave extra; por isso o overlay mora em ficheiros próprios).

### 3.3 Passo obrigatório (hot-reload 500 ms, sem restart)

```bash
ZDIR="$HOME/.local/state/cloudflare-agent-skill/zones/kluser.me"
/usr/bin/python3 - "$ZDIR/auth.json" <<'PY'
import json, os, sys, tempfile
p = sys.argv[1]
doc = json.load(open(p))
host = "watch.kluser.me"
if host not in doc.get("exempt", []):
    doc.setdefault("exempt", []).append(host)
tmp = p + ".tmp"
with open(tmp, "w") as fh:
    json.dump(doc, fh, indent=1)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
print("exempt =", doc["exempt"])
PY
```

Não imprimir/alterar `totp.secret_hex`; não reiniciar o runner (o watch de 500 ms recarrega; o
`runner.log` passa a `auth reloaded (exempt: 2)`).

### 3.4 Segurança resultante

Sem `?key=` e sem TOTP do runner, a única auth é a **TOTP própria da app** sobre TLS da edge. É o
mesmo modelo do `trello.kluser.me` (que vive só com TOTP). Para subir o nível sem mexer no runner:
**Cloudflare Access** à frente do host (identidade SSO), que a skill recomenda para produção.

## 4. Q6b.4 — verificação ponta-a-ponta e efémero vs `--persist`

### 4.1 Verificação (do mais próximo para o mais distante)

```bash
ZDIR="$HOME/.local/state/cloudflare-agent-skill/zones/kluser.me"
RP=$(/usr/bin/python3 -c "import json;print(json.load(open('$ZDIR/runtime.json'))['proxy_port'])")

# 1) rota existe no ROUTER DESTE Mac? (a sonda com Host não toca na Cloudflare)
#    404 = sem rota · 200/401/502 = rota existe   (401 só antes de isentar o TOTP)
/usr/bin/curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: watch.kluser.me' "http://127.0.0.1:$RP/"

# 2) a app responde em loopback?
/usr/bin/curl -s -i --max-time 5 http://127.0.0.1:8420/ | head -5

# 3) health do router (isento de auth, é o probe do domain.py)
/usr/bin/curl -s -i --max-time 10 https://watch.kluser.me/__cfx-health | head -6
#    esperado: HTTP/2 200 · content-type: text/plain · x-cfx-proxy: ok

# 4) a app PELA EDGE (a prova real)
/usr/bin/curl -s -i --max-time 10 https://watch.kluser.me/ | head -15
```

Códigos esperados (e como ler cada um):

| Vista | Significado |
|---|---|
| `200` + `x-cfx-proxy: ok` em `/__cfx-health` | há **um** router cfx a responder. ⚠️ **Não prova que é o deste Mac** — o curinga do Acer também responde 200 a este path (medido em `watch.kluser.me` antes de publicar). |
| `404` + `<p>Nada publicado em watch.kluser.me.</p>` | a rota **não** existe no router que está a servir → ainda é o curinga do Acer (ou `up` falhou). |
| `502` + `x-cfx-proxy: upstream-down` | rota existe no router do Mac, **app local morta** → subir o serviço. |
| `HTTP/2 200/303/…` da app (sem `Nada publicado`) | publicado e a app a responder. 404/401 **da app** são resposta legítima dela. |
| `401` + form “verificação TOTP” (GET) | TOTP do runner ativo no host → falta o `exempt` do §3.3. |
| `401` seco (POST) | idem, e é o sintoma que **parte** o cliente do Watch. |

Assinatura de sucesso sem ambiguidade:

```bash
/usr/bin/curl -s https://watch.kluser.me/ | grep -q "Nada publicado em watch.kluser.me" \
  && echo "AINDA no curinga do Acer (esperar a edge, 8–33 s)" || echo "OK: o Mac está a servir"
```

Prova de que o CNAME é deste Mac (leitura da API, sem alterar nada): o registo
`watch.kluser.me` deve ter `content = 0a5203f8-3f73-4cdc-9d7d-20a30eeb4437.cfargotunnel.com` e
`comment` a começar por `cfx:bbc49a:`; e `python3 …/domain.py list` passa a mostrar
`watch.kluser.me   http://127.0.0.1:8420   efémero   cname   no ar`.

⚠️ **Tanque na verificação do próprio `up`:** `probe()` aceita `x-cfx-proxy: ok` de **qualquer**
router cfx e só falha em `{000,502,503,504,530}`. Como o curinga do Acer responde `200` ao health e
`404` ao path, o `up` pode imprimir `verificação HTTPS 404 pela edge … a app respondeu` e ainda não
estar a servir pelo Mac. A prova válida é o passo 4 acima (corpo **sem** “Nada publicado”), não a
linha do `up`.

### 4.2 Efémero vs `--persist` (macOS não tem systemd)

- `--persist` → `apply_runner()` faz `if any_persist and not use_systemd: die(…)` →
  **`Erro: --persist precisa de systemd --user (não disponível aqui)`**, exit **3**. `systemctl`
  não existe neste Mac (`systemd_ok() == False`), logo **`--persist` é impossível aqui**.
- **Efémero** (o modo que fica): a rota leva `boot_id` (`boot-1792512856` neste boot) e:
  1. o `zone-runner.mjs` + `cloudflared` são processos `setsid` **sem supervisor** → morrem no
     reboot/crash;
  2. no `up` seguinte (de **qualquer** rota), `prune_stale()` remove rotas com `boot_id` antigo **e
     apaga o CNAME próprio** dessas rotas (só se ainda apontar para o nosso túnel);
  3. `<porta>.kluser.me` deixa de existir → o nome volta a cair no curinga → **404 do router do
     Acer**.
- **Portanto:** depois de cada reboot, `watch.kluser.me` só volta se **alguém correr o `up` outra
  vez** — e a **ordem importa**: o watchdog do `mac.kluser.me` corre `up --name mac` no arranque e,
  ao fazê-lo, `prune_stale()` apaga a rota+CNAME do `watch`. O `up --name watch` tem de correr
  **depois** (ou o script do `watch` tem de reassertar a rota ciclicamente — é o que o §5.4 faz).
- Isto é exatamente a razão pela qual o `mac.kluser.me` é “efémero” na tabela da skill: quem o
  ressuscita é o **LaunchDaemon + `mac-kluser-web.sh`**, não o `domain.py`.
- **No boot atual, o `up --name watch` não estraga o `mac`:** a rota `mac.kluser.me` tem
  `boot_id: "boot-1792512856"` = boot corrente e o router está vivo → `route_alive()` é `true`, não
  é prunada. O `up` mexe só na entrada do host pedido, faz `version+1` e manda SIGHUP ao router
  (reload de todas as rotas, ~50 ms).

## 5. Q6b.5 — sobreviver a logout/reboot no macOS 27 (launchd)

### 5.1 LaunchAgent vs LaunchDaemon nesta máquina

| | LaunchAgent (`~/Library/LaunchAgents`, domínio `gui/<uid>`) | LaunchDaemon (`/Library/LaunchDaemons`, domínio `system`) |
|---|---|---|
| Arranca no boot **sem** login gráfico | **Não** (`autoLoginUser` **não** está definido; `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser` → key not found) | **Sim** (já com `UserName=minim1`) |
| Lê `/Volumes/Ext2TB` | **Não** — medido (§5.2) | **Não** — medido (é o mesmo TCC) |
| Override de ficheiros do sistema | não | sim (precisa `sudo`) |

→ **LaunchDaemon** (como o `com.ondokai.mac-kluser-web`), e **o processo que toca em
`/Volumes/Ext2TB` tem de nascer dentro de uma sessão SSH** (é a única sessão com Full Disk Access
desta máquina).

### 5.2 TCC do volume removível — medido (2026-10-22, macOS 27.0 / 26A428)

LaunchAgent temporário (`com.watchpilot.tccprobe`, removido depois) a correr `/bin/sh` no domínio
`gui/501`:

```text
ls /Volumes/Ext2TB                       -> ls: Operation not permitted
cat …/watch-pilot/server/pyproject.toml  -> cat: Operation not permitted
touch /Volumes/Ext2TB/.dsh-tccprobe      -> WRITE DENIED
python -V (venv no /Volumes)             -> Python 3.13.15      (execve passa)
python -c "… read file …"                -> bloqueia/denied     (open() de conteúdo não passa)
```

Ou seja: **nem ler** o projeto, quanto mais importar a app. A sessão SSH (esta, `SSH_CONNECTION=
127.0.0.1 59553 127.0.0.1 22`) **lê e escreve** `/Volumes/Ext2TB` sem problema (é a FDA herdada do
`sshd-keygen-wrapper`, portão G5 da skill `macmini`). O DSH a servir o `mac.kluser.me` é a prova
viva: `node /Volumes/Ext2TB/Projects/deepseek-harness/apps/cli/lib/bin.js web --no-open`, e o
watchdog `/Volumes/Ext2TB/Agent-Skills/macmini/scripts/mac-kluser-web.sh` corre dentro de um
`sshd-session`.

### 5.3 Skeleton do plist (copiar para `/Library/LaunchDaemons/com.watchpilot.hub.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- watch-pilot hub — mantém o uvicorn (:8420) e a rota watch.kluser.me vivos
     após reboot/logout. PORQUE SSH LOCAL: um job de launchd (mesmo root) não
     lê /Volumes/Ext2TB (TCC de volume removível); a sessão SSH é a única com
     FDA. PORQUE LaunchDaemon: auto-login está OFF (LaunchAgent só correria
     com sessão GUI). root:wheel 644. -->
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.watchpilot.hub</string>
  <key>UserName</key>         <string>minim1</string>

  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string>
    <string>-F</string>                       <string>/dev/null</string>
    <string>-i</string>                       <string>/Users/minim1/.ssh/watchpilot_hub_ed25519</string>
    <string>-o</string>                       <string>IdentitiesOnly=yes</string>
    <string>-o</string>                       <string>BatchMode=yes</string>
    <string>-o</string>                       <string>PreferredAuthentications=publickey</string>
    <string>-o</string>                       <string>StrictHostKeyChecking=accept-new</string>
    <string>-o</string>                       <string>ServerAliveInterval=30</string>
    <string>-o</string>                       <string>ServerAliveCountMax=3</string>
    <string>-o</string>                       <string>ConnectTimeout=10</string>
    <string>-T</string>                       <string>minim1@127.0.0.1</string>
  </array>

  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>ThrottleInterval</key> <integer>20</integer>
  <key>ProcessType</key>      <string>Background</string>
  <key>WorkingDirectory</key> <string>/Users/minim1</string>

  <!-- logs SEMPRE no disco interno: o launchd abre estes ficheiros como o
       utilizador do job; /var/log ou /Volumes dariam EX_CONFIG/permission denied -->
  <key>StandardOutPath</key>   <string>/Users/minim1/.local/state/watchpilot/launchd.log</string>
  <key>StandardErrorPath</key> <string>/Users/minim1/.local/state/watchpilot/launchd.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>WATCHPILOT_PORT</key> <string>8420</string>
  </dict>
</dict>
</plist>
```

Instalação (a chave e o forced command são o que dão a FDA ao script):

```bash
# a) chave dedicada + forced command (backup do authorized_keys primeiro)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ -f ~/.ssh/watchpilot_hub_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C watchpilot-hub-fda \
  -f ~/.ssh/watchpilot_hub_ed25519
chmod 600 ~/.ssh/watchpilot_hub_ed25519
cp -p ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-$(date +%Y%m%d-%H%M%S)
CMD='command="export WATCHPILOT_DAEMON=1; until [ -x /Users/minim1/.local/bin/watch-pilot-hub.sh ]; do sleep 5; done; exec /Users/minim1/.local/bin/watch-pilot-hub.sh",restrict,from="127.0.0.1,::1"'
{ grep -v 'watchpilot-hub-fda' ~/.ssh/authorized_keys 2>/dev/null; printf '%s %s\n' "$CMD" "$(cat ~/.ssh/watchpilot_hub_ed25519.pub)"; } \
  > ~/.ssh/authorized_keys.tmp && mv -f ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# b) instalar o daemon
sudo install -o root -g wheel -m 644 infra/launchd/com.watchpilot.hub.plist /Library/LaunchDaemons/com.watchpilot.hub.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.watchpilot.hub.plist
sudo launchctl print system/com.watchpilot.hub | head -20        # state = running
# se aparecer "Bootstrap failed: 5: Input/output error":
sudo launchctl enable system/com.watchpilot.hub && sudo launchctl bootstrap system /Library/LaunchDaemons/com.watchpilot.hub.plist
# atualizar o plist = bootout + bootstrap (kickstart NÃO relê o ficheiro):
#   sudo launchctl bootout system/com.watchpilot.hub && sudo launchctl bootstrap system /Library/LaunchDaemons/com.watchpilot.hub.plist
# teste de reboot:  sudo launchctl kickstart -k system/com.watchpilot.hub
# desinstalar:      sudo launchctl bootout system/com.watchpilot.hub && sudo rm /Library/LaunchDaemons/com.watchpilot.hub.plist
```

> Os dois blocos acima foram validados ao extraí-los deste documento:
> `plutil -lint` → **OK** e `bash -n` → **OK** (sintaxe).

### 5.4 Wrapper que o forced command executa (`/Users/minim1/.local/bin/watch-pilot-hub.sh`, 0755)

Disco **interno** (não precisa de FDA para ser lido; tudo o que está em `/Volumes` é aberto aqui
dentro, na sessão SSH). Faz três coisas: arranca/relança o uvicorn, reasserta a rota, e sai quando a
sessão SSH morre (para o `KeepAlive` do launchd abrir outra).

```bash
#!/bin/bash
# watch-pilot hub — corre DENTRO da sessão sshd (FDA) que o LaunchDaemon com.watchpilot.hub abre.
set -uo pipefail
export HOME=/Users/minim1 USER=minim1 LOGNAME=minim1 LANG=en_US.UTF-8
export PATH="/Users/minim1/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CLOUDFLARE_EXPOSE_WILDCARD=0 CLOUDFLARE_EXPOSE_DOMAIN=kluser.me

PORT="${WATCHPILOT_PORT:-8420}"
PUB_HOST=watch.kluser.me
PROJ=/Volumes/Ext2TB/Projects/watch-pilot/server
PY="$PROJ/.venv/bin/python"                       # 3.13.15 (uv)
DOMAIN_PY=/Volumes/Ext2TB/Agent-Skills/cloudflare-agent-skill/scripts/expose-port/domain.py
ZDIR="$HOME/.local/state/cloudflare-agent-skill/zones/kluser.me"
STATE="$HOME/.local/state/watchpilot"
LOG="$STATE/hub.log"
mkdir -p "$STATE" && chmod 700 "$STATE"
touch "$LOG" && chmod 600 "$LOG"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

# instância única
LOCK="$STATE/hub.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  old=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "${old:-}" ] && kill -0 "$old" 2>/dev/null; then log "já existe instância (pid $old) — sair"; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" || exit 1
fi
printf '%s\n' $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# sessão SSH morta => reparentado para o launchd: sair para o próximo cliente assumir
ORIG_PPID=$(ps -o ppid= -p $$ | tr -d ' ')
[ "${WATCHPILOT_DAEMON:-0}" = 1 ] && [ "$ORIG_PPID" = 1 ] && { log "sem sessão SSH (ppid 1) — sair"; exit 0; }

port_listening() { /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; }

start_server() {   # uvicorn com caminho absoluto; logs no disco interno
  port_listening && return 0
  log "a arrancar uvicorn em 127.0.0.1:$PORT"
  ( cd "$PROJ" && nohup "$PY" -m uvicorn app.main:app \
      --host 127.0.0.1 --port "$PORT" --log-level info \
      >>"$STATE/uvicorn.log" 2>&1 </dev/null & echo $! >"$STATE/uvicorn.pid" )
}

ensure_route() {   # rota da zona: ausente(404) => publicar; 000 => zona em baixo, esperar
  local rp code
  rp=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['proxy_port'])" "$ZDIR/runtime.json" 2>/dev/null) || {
    log "sem runtime.json (zona em baixo) — aguardar o watchdog do mac"; return 0; }
  code=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: $PUB_HOST" "http://127.0.0.1:$rp/")
  case "$code" in
    404) log "rota ausente no router (404) — domain.py up --name watch"
         /usr/bin/python3 "$DOMAIN_PY" up "http://127.0.0.1:$PORT" --domain kluser.me \
           --name watch --no-gate --no-persist >>"$LOG" 2>&1 || log "up falhou rc=$?" ;;
    000) log "router não responde (000) — aguardar" ;;
    *)   : ;;   # 200 / 401 (TOTP) / 502 (app down) => rota existe
  esac
}

while :; do
  now=$(ps -o ppid= -p $$ | tr -d ' ')
  [ -n "$ORIG_PPID" ] && [ "$now" != "$ORIG_PPID" ] && { log "sessão SSH terminou (ppid $ORIG_PPID → $now) — sair"; exit 0; }
  start_server
  ensure_route
  sleep 20
done
```

Notas de operação:

- **Nunca** montar `config.yml`/units do túnel à mão (proibido pela skill): o túnel/roteador são do
  `domain.py`, e o `up --name watch` é idempotente (rota existente → SIGHUP, ~0,2 s).
- O ciclo de 20 s resolve o §4.2: quando o watchdog do `mac` faz `up --name mac` no arranque e
  `prune_stale()` apaga a rota do `watch`, o ciclo seguinte (≤20 s) volta a publicá-la.
- Alternativa mínima (menos bonita): acrescentar uma linha `domain.py up --name watch …` **depois**
  do `up --name mac` dentro de `mac-kluser-web.sh` (~linha 209). Fica tudo num sítio, mas mistura o
  watchdog do `kluser.me` com um projeto de app — preferível o daemon separado.
- Logs: `~/.local/state/watchpilot/{launchd.log,hub.log,uvicorn.log}` (0600). Nada em `/var/log`
  (o launchd abriria como `minim1` → `EX_CONFIG`).

## 6. Bloqueios e riscos encontrados

| # | Bloqueio | Impacto | Correção |
|---|---|---|---|
| B1 | `auth.json.enabled=true`, `exempt=["defcon4.kluser.me"]` | **App do Watch inutilizável** (401 em todo o POST/WS) | acrescentar `watch.kluser.me` ao `exempt` (§3.3) |
| B2 | LaunchAgent/Daemon **não** lê `/Volumes/Ext2TB` (TCC, medido) | uvicorn do venv externo não arranca por launchd direto | padrão SSH local + forced command (§5.3/§5.4) |
| B3 | Sem `systemd` → `--persist` exit 3 | rota morre no reboot; `prune_stale` apaga o CNAME do `watch` no próximo `up` | LaunchDaemon que reasserta a rota (§5.4) |
| B4 | Curinga `*.kluser.me` do Acer responde `200` ao `/__cfx-health` | o probe do próprio `up` pode dar falso positivo (`HTTPS 404 … a app respondeu`) | validar pelo corpo sem “Nada publicado” (§4.1) |
| B5 | `kluser.py add` defaults (`--persist`, `SKILL_CANDIDATES`) não servem no Mac | `add` falha exit 3 / exit 3 “skill não encontrada” | usar `domain.py` + `CLOUDFLARE_SKILL_DIR` e `--no-persist` (§1.5) |
| B6 | Portas 3080/8787/8790 reservadas | um projeto na 8790 já disparou o kill-switch do defcon (incidente 2026-10-11) | usar `8420` (livre, verificado) |

## 7. Anexo — referência rápida

| Comando | Efeito |
|---|---|
| `domain.py up <url> --name watch --no-gate --no-persist` | publica/atualiza a rota (idempotente) |
| `domain.py list [--json]` | rotas vivas + cloudflared não geridos (read-only) |
| `domain.py down watch.kluser.me` | tira a rota (404 imediato) + apaga o CNAME próprio (**não executado**) |
| subcomandos existentes | `up`, `down`, `list`, `setup`, `purge`, `selftest` (não há mais nenhum) |
| `server/.venv/bin/python -V` | `Python 3.13.15` (fastapi 0.159.1, uvicorn 0.54.0) |
| `lsof -nP -iTCP:8420 -sTCP:LISTEN` | vazio = porta livre |

Comandos usados nesta pesquisa (todos read-only): `domain.py list`, `domain.py list --json`,
`domain.py up --help`, leitura do zone-dir (`zone.json`, `routes.json`, `runtime.json`,
`cloudflared.yml`, chaves de `auth.json`/`inject.json` — **sem** imprimir segredos), `ps`,
`dig @cleo.ns.cloudflare.com`, `curl` GET (local + edge), `GET /zones/…/dns_records` na API v4, e um
LaunchAgent temporário `com.watchpilot.tccprobe*` (criado, lido e removido — nada mais mudou).
