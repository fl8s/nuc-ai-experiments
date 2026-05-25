# Telegram integration — setup guide

Telegram pushes a notification to your phone every time Virtual
Scott posts a reply. Useful for demos and for spot-checking that
the loop is running without tailing logs.

This document covers what to do on Telegram's side (BotFather +
chat id), how the integration is wired into Virtual Scott, and
the tradeoffs vs. shipping without notifications.

Status: shipped. `vs-tick.py` reads `VS_TELEGRAM_BOT_TOKEN` and
`VS_TELEGRAM_CHAT_ID` from the systemd environment and pushes three
kinds of notification:

- **starting reply** — when the orchestrator picks up a comment and
  dispatches the child agent
- **reply posted** — when the reply lands in WP (verified by GET
  with retry, plus an agent-log fallback)
- **attempt failed** — on `timeout`, `failed` (agent exited non-zero
  and nothing landed), `no_post_detected` (agent exited 0 but no
  reply landed), or `exception`

If either env var is missing, all three calls are silent no-ops —
no Telegram, no error, no effect on the tick.

## What you'll set up

Two pieces, both done from your phone in the Telegram app:

1. **A Telegram bot** that Virtual Scott will use to send you
   messages. Created via Telegram's official @BotFather. You get a
   bot token (looks like `1234567890:AAGmH...`); save it.
2. **Your personal chat id**, so the bot knows where to send the
   notifications. You get this by messaging the bot once from your
   account.

Total time: ~5 minutes. No coding.

## Step-by-step

### 1. Create the bot (via @BotFather)

Open Telegram, search for **@BotFather**, start a chat. Send:

```
/newbot
```

It will prompt you twice:

- **Name** — a human-readable label that shows up in chat headers.
  Something like `Virtual Scott Notifications`.
- **Username** — must end in `bot` and must be globally unique on
  Telegram. Something like `scott_vs_notifier_bot` or
  `<yourname>_vs_bot`.

BotFather replies with a message containing the **bot token**.
Example shape:

```
8123456789:AAH7-LongRandomStringHere_lookslikeBASE64
```

Copy this token. Treat it like a password — anyone with it can
send messages as your bot.

While you're in BotFather, optionally set:
- `/setprivacy` → `Disable` if you ever want the bot to read group
  messages. We don't need this for one-way notifications.
- `/setdescription`, `/setabouttext` — cosmetic, optional.

### 2. Get your personal chat id

In Telegram, open a new chat with **your bot** (search by the
`@<username>` you picked above) and send any message — `hello`
will do.

Then from any machine with curl:

```bash
TOKEN='<the token you just got>'
curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" | python3 -m json.tool
```

In the response, find `"chat":{"id":<NUMBER>,...}`. That number
is your chat id. Save it — it's not secret, but you'll need it.

### 3. Stash both in the sandbox VM

On the sandbox VM, create a systemd user environment file that
Virtual Scott's autonomous loop will read:

```bash
mkdir -p ~/.config/systemd/user/openclaw-gateway.service.d
cat > ~/.config/systemd/user/openclaw-gateway.service.d/telegram.conf <<EOF
[Service]
Environment=VS_TELEGRAM_BOT_TOKEN=8123456789:AAH7-LongRandomStringHere
Environment=VS_TELEGRAM_CHAT_ID=123456789
EOF
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway
```

Replace with your actual values. The conf goes in a `.d` drop-in
so we don't touch the upstream service file.

Verify the daemon sees them:

```bash
systemctl --user show openclaw-gateway -p Environment | tr ' ' '\n' | grep VS_
```

### 4. Smoke-test the bot wiring (independent of Virtual Scott)

Before plumbing it into the agent, confirm the bot+chat id work
end-to-end with a one-liner curl from the VM:

```bash
source <(grep VS_ ~/.config/systemd/user/openclaw-gateway.service.d/telegram.conf | sed 's|Environment=|export |')
curl -s "https://api.telegram.org/bot$VS_TELEGRAM_BOT_TOKEN/sendMessage" \
    -d "chat_id=$VS_TELEGRAM_CHAT_ID" \
    -d "text=Virtual Scott wiring test — if you got this, the bot can reach you."
```

You should get a buzz on your phone within a few seconds. If yes,
Telegram is set up. If no, the token or chat id is wrong.

## How Virtual Scott uses it

### Where the notification call lives

Three places we could put it:

| Option | Where | Pros | Cons |
|--------|-------|------|------|
| A. In `vs-tick.py` (Python) | After `check_reply_landed` confirms a reply | Deterministic; runs after we KNOW the reply landed; can include the WP URL we got back | Telegram call lives in our orchestrator, not the agent |
| B. In `vs-post-reply.sh` (shell) | After the `curl POST` to WP returns 201 | Even closer to the actual post — fires immediately | Mixes notification with comment-posting; harder to disable independently |
| C. In the reply skill (agent) | As a new step 5 after the POST | Agent-native; the message text can be customised by the agent itself | Adds work to the agent's per-turn budget; subject to the same "agent doesn't always do final steps" issues we hit with JSON-escape loops |

**Choice: (A).** Same pattern as the `check_reply_landed` check —
a thin Python helper that runs after the reply is verified. The
agent doesn't know about Telegram; only the orchestrator does. If
Telegram goes down, the reply still gets posted (Telegram call is
best-effort, wrapped in try/except).

Implementation is `_telegram_send(body)` plus three thin wrappers
(`notify_telegram_start`, `notify_telegram_done`,
`notify_telegram_failure`) in `vs-tick.py`. No skill changes, no
SKILL.md edits, no agent re-training. The "starting" notification
fires just before the child-agent subprocess; "reply posted" fires
from the success branch after `check_reply_landed` confirms;
"attempt failed" fires from each failure branch. All three call the
same `_telegram_send` which silently no-ops if creds are missing
and wraps the HTTPS call in try/except so Telegram failures never
affect tick outcomes.

### Kill switch via Telegram?

Original plan called for "reply STOP to the bot to halt the loop,
RESUME to wake it." That's bidirectional and significantly more
complex — needs a polling loop or webhook, message-handling, etc.
**Skip for v1.** The existing `make pause` / `make resume` file-
based kill switch is sufficient when you're at a terminal. Phone-
based halt can come later as a separate skill if it's worth it.

## Risks of adding the Telegram integration

| Risk | Mitigation |
|------|-----------|
| **Telegram bot token leaks** — anyone with it can spam your account. | Token stored in systemd env, not in the repo. Don't commit `telegram.conf` to git. Rotate via `/revoke` in BotFather if leaked. |
| **Notification rate-limit** — Telegram allows 30 messages/sec to one chat. We send at most 1 per 5-min cron tick, so 4 orders of magnitude below the limit. Non-issue. | n/a |
| **Telegram API outage** — bot.sendMessage fails. | Best-effort send: wrapped in try/except. Failure logged at WARN, reply itself still considered successful. Cron loop unaffected. |
| **Outbound HTTPS now required from the sandbox VM.** | The VM already makes outbound HTTPS (to register the OpenClaw scope upgrade endpoint, to fetch packages). One more domain (`api.telegram.org`) doesn't materially expand the threat surface. |
| **Privacy** — every Virtual Scott reply goes to your phone, with comment + reply text. | Intentional. Don't enable Telegram on the future-public-blog version unless you actively want a live feed. |
| **Agent execution complexity** — does Telegram add per-tick latency or model load? | **No.** Telegram call runs in the Python orchestrator AFTER the agent's work is done. Adds ~50ms to the tick (one HTTPS request). No model interaction. The agent is unaware Telegram exists. |
| **Failure mode confusion** — if Telegram works, you see notifications, all is well. If Telegram silently breaks, you might think the loop stopped when it's actually running. | Solved by the existing `tail successes.jsonl` discipline. Telegram is additive, not load-bearing. |

## Net assessment

Telegram integration is **low-risk and low-complexity**. The Python
side is a 10-line helper that wraps `urlopen`. No new skills, no
helper script needed, no JSON-escape concerns. Agent execution
budget is unaffected because the call happens in Python after the
agent has already finished.

The main thing it buys: a real-time pulse on the loop without
sitting at the terminal. For demos that matters a lot — phone
buzzes, point at the screen, "see, it just posted." For day-to-day
operation, it's nice-to-have.

## Setup checklist for a new sandbox

The Python side ships in `vs-tick.py`; all that's needed per
deployment is the bot + env vars:

1. Mint a Telegram bot via BotFather; capture token + chat id
   (steps 1–2 above).
2. Stash both as `VS_TELEGRAM_BOT_TOKEN` / `VS_TELEGRAM_CHAT_ID`
   in the openclaw-gateway systemd env (step 3).
3. Smoke-test the bot wiring with the curl one-liner (step 4).
4. Validate end-to-end with one `make poll-now` against a freshly-
   seeded comment — your phone should buzz within seconds of the
   reply landing in WP.
