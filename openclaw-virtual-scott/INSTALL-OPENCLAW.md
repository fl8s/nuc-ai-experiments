# Installing the OpenClaw daemon

Prereqs for the Virtual Scott experiment. One-time setup on the
sandbox VM that will run the OpenClaw daemon. The NUC's
`code-assistant` pod (which serves the model) is a separate concern
— see [../code-assistant/README.md](../code-assistant/README.md).

Tested on Ubuntu 24.04 inside a Proxmox VM. The Virtual Scott
experiment shares this daemon with the
[../openclaw/](../openclaw/) HN-opinions experiment — if you've
already followed that project's install, **skip to the
[README.md](README.md) for this project**; the daemon is the same.

## 1. System packages

```bash
# On Ubuntu/Debian:
sudo apt update
sudo apt install -y curl make python3 jq ca-certificates

# On Fedora:
sudo dnf install -y curl make python3 jq ca-certificates
# (or rpm-ostree install -y curl make python3 jq ca-certificates && systemctl reboot)
```

`make`, `curl`, `python3`, and `jq` are all used by this repo's
Makefile and helper scripts.

## 2. Node.js 24

OpenClaw requires Node 24 (recommended) or 22.19+. Ubuntu's default
`nodejs` package is too old:

```bash
# On Ubuntu/Debian:
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs

# On Fedora:
sudo dnf install -y nodejs

node --version    # confirm v24.x.x
```

## 3. Install OpenClaw

```bash
sudo npm install -g openclaw@latest
openclaw --version
```

## 4. Run onboarding — and POINT IT AT THE NUC FROM STEP ONE

```bash
openclaw onboard --install-daemon
```

The wizard asks a series of questions. The non-obvious one:

- **Model provider:** **pick `custom` / `openai-compatible` /
  `self-hosted`** (whatever your version calls it) and enter the
  NUC's `code-assistant` endpoint directly:
  - **baseURL:** `http://<NUC_IP>:30083/v3`
  - **API key:** `sk-local` (the value doesn't matter; OVMS ignores it)
  - **Model id:** `qwen3-coder`

  Do NOT pick OpenAI / Anthropic / Google as a placeholder, even if
  you plan to "override the config later." The wizard's **Hatch**
  step runs a live LLM call against whatever provider you picked,
  and a cloud placeholder there will either fail (no auth) or send a
  prompt to a remote model — neither of which fits the
  local-inference-only premise.

- **Channels:** skip everything (WebChat is part of the gateway,
  not a channel — it's always available).

- **Hatch:** pick **"hatch in terminal"** (not "later"). Picking
  "later" leaves a `BOOTSTRAP.md` in the agent workspace that the
  agent treats as an active task on every prompt, which derails
  skill execution. See [../OPENCLAW-NOTES.md](../OPENCLAW-NOTES.md)
  for the background.

When onboarding finishes, the daemon runs as a systemd user service:

```bash
systemctl --user status openclaw-gateway
openclaw daemon status
```

Note the gateway port (default 18789). WebChat at `http://localhost:18789/webchat`.

## 5. (Optional) Grant the CLI admin scopes

By default the `openclaw` CLI on the same machine only has
`operator.pairing` scope, which means commands like `openclaw cron
add` and `openclaw agents config` get rejected with a "scope upgrade
pending approval" error and silently fall back to embedded mode.

The autonomous loop needs CLI access to `cron add`/`enable`/`run`,
so granting admin scopes up front saves debugging time:

```bash
# Grant operator.admin/read/write to the CLI device.
# Mirror what the browser/admin device already has.
CLI_ID=$(jq -r '.deviceId' ~/.openclaw/identity/device-auth.json)
NEW_SCOPES='["operator.admin","operator.read","operator.write","operator.pairing"]'

jq --arg id "$CLI_ID" --argjson scopes "$NEW_SCOPES" '
  .[$id].scopes = $scopes
  | .[$id].approvedScopes = $scopes
  | .[$id].tokens.operator.scopes = $scopes
' ~/.openclaw/devices/paired.json > /tmp/paired.new && \
  mv /tmp/paired.new ~/.openclaw/devices/paired.json

jq --argjson scopes "$NEW_SCOPES" \
  '.tokens.operator.scopes = $scopes' \
  ~/.openclaw/identity/device-auth.json > /tmp/dauth.new && \
  mv /tmp/dauth.new ~/.openclaw/identity/device-auth.json

echo '{}' > ~/.openclaw/devices/pending.json
systemctl --user restart openclaw-gateway
sleep 4 && openclaw cron list   # should now succeed
```

The alternative is to approve the scope upgrade from the WebChat
admin UI. Editing the device store directly is faster, and the
trust boundary is the VM itself.

## 6. PATH check

If `which openclaw` is empty after install, npm's global bin dir
isn't on your `$PATH`:

```bash
npm prefix -g          # e.g. /usr/local or ~/.npm-global
# ensure <prefix>/bin is on $PATH
```

## What's next

[README.md](README.md) takes over from here. It assumes the daemon
is running and walks through creating the Virtual Scott agent on
top of it.
