# Virtual Scott — an AI that answers blog comments on its own

A small experiment in running an autonomous AI agent on local
hardware. The agent reads new comments on a WordPress blog, decides
which are worth a reply, drafts the reply, and posts it — every
five minutes, without anyone watching. Inference runs on an Intel
NUC; no calls leave the local network.

This document is for two readers: blog visitors who want to
understand what's going on, and future-me coming back to remember
how the moving parts fit together. For background on the OpenClaw
daemon itself, see [../OPENCLAW-NOTES.md](../OPENCLAW-NOTES.md).

## 1. Motivation and overview

The motivating idea: I write a blog, comments accumulate, I'm slow
to answer them. An LLM agent with my voice could reply on my
behalf, signed as "Virtual Scott" so commenters know which is
which. Two constraints make this an experiment rather than a
product:

- **All inference must run locally.** No cloud APIs. The model
  serving the agent lives in a k3s pod called `code-assistant` on
  an Intel NUC (Panther Lake, iGPU-served Qwen3-Coder-30B-A3B
  INT4 via OpenVINO Model Server). See
  [../code-assistant/](../code-assistant/) for that side of the
  stack.
- **The blog being commented on must be sandboxed.** This is a
  toy WordPress instance running in k3s on a separate Proxmox VM,
  populated with copies of real blog posts and synthetic test
  comments. Nothing in this experiment touches the real public
  blog.

### How the three WordPress users fit together

There are three WP accounts in the sandbox. Understanding them is
the easiest way to understand the data flow:

| User | Role | What it represents |
|------|------|--------------------|
| `scott` | Admin | The real human (me). Owns the blog, authors posts, has admin REST access used by the [medium-import/](medium-import/) tooling to bulk-load posts. The agent never posts as `scott`. |
| `virtual-scott` | Editor | The agent's identity. Every reply is authenticated as this user. Editor role is just enough to publish comments without going through moderation. Replies are signed `— Virtual Scott` in the body so commenters see the disclosure regardless of WP author UI. |
| `some-commenter` | Subscriber | The synthetic "reader" used during testing. Canonical test fixtures (in [fixtures/some-commenter-comments.json](fixtures/some-commenter-comments.json)) post under this account so the agent has something to reply to. |

A demo cycle looks like this:

1. `some-commenter` leaves a question on a post — e.g. "What other
   models could be used for this?"
2. Every five minutes a cron job inside the OpenClaw daemon fires
   the **tick** skill.
3. The tick discovers the new comment (filtering out anything by
   `scott`, by `virtual-scott`, or already-replied-to).
4. The tick spawns a child agent run of the **reply** skill,
   targeting that comment id.
5. The reply skill: fetches the comment + parent post, drafts a
   reply matching the persona, runs a self-check against the
   "things I don't know" list, then POSTs the reply via the WP
   REST API authenticated as `virtual-scott`.
6. The new comment appears on the blog, signed `— Virtual Scott`.

The autonomous loop is rate-limited to one reply per tick by
default, so a backlog of 5 comments takes about 25 minutes to
drain. That cap is configurable; it exists because the model takes
30–90 seconds per reply and running many sequential turns blows
the agent's per-turn time budget.

### Hardware layout

```
┌──────────────────────────┐         ┌─────────────────────────┐
│ Intel NUC (Panther Lake) │ ←HTTP─  │ Sandbox Proxmox VM      │
│                          │         │ ub2404-openclaw         │
│  k3s pod: code-assistant │         │                         │
│  OVMS → iGPU             │         │  k3s pod: WordPress     │
│  Qwen3-Coder-30B INT4    │         │  k3s pod: MariaDB       │
│                          │         │                         │
│  198.0.0.47:30083/v3     │         │  systemd: openclaw      │
└──────────────────────────┘         │  gateway daemon         │
                                     │  + virtual-scott agent  │
                                     │                         │
                                     │  198.0.0.45:30080       │
                                     │  (WordPress NodePort)   │
                                     └─────────────────────────┘
                                              ↑
                                  any LAN host:
                                  workstation browser,
                                  demo laptop, etc.
```

Both VMs are on the home LAN — "sandboxed" here means "local-LAN,
not public internet", not "loopback-only." The demo laptop can
hit `http://198.0.0.45:30080` directly to see the blog and the
auto-posted replies.

## 2. Agent design

### Where the files live

The repo (this directory) is the canonical source for everything.
Files get deployed to the sandbox VM via `make upload` (rsync) and
then materialised into the OpenClaw agent's workspace by `make
install-persona` / `make install-skill` / `make install-fixtures`.
Substitutions happen at install time — the repo source has
placeholders like `__WP_HOST__` and `__VS_WP_AUTH_B64__`; the
installed copies on the VM have the real values.

| In the repo | Installed to | What |
|-------------|--------------|------|
| `PERSONA.md` | `~/.openclaw/workspace-virtual-scott/SOUL.md` | The agent's voice and "what I do/don't know" rules. Copied to SOUL.md because that's the filename OpenClaw auto-loads into the system prompt. |
| `agent-workspace/IDENTITY.md` | `~/.openclaw/workspace-virtual-scott/IDENTITY.md` | Short identity record: name, vibe, signing rules. |
| `agent-workspace/USER.md` | `~/.openclaw/workspace-virtual-scott/USER.md` | What the agent should know about real-Scott. |
| `skills/virtual-scott-reply/SKILL.md` | `~/.openclaw/workspace-virtual-scott/skills/virtual-scott-reply/SKILL.md` | The per-comment reply procedure. |
| `skills/virtual-scott-poll/SKILL.md` | `~/.openclaw/workspace-virtual-scott/skills/virtual-scott-poll/SKILL.md` | Manual "what's replyable" discovery tool. Read-only. |
| `skills/virtual-scott-tick/SKILL.md` | `~/.openclaw/workspace-virtual-scott/skills/virtual-scott-tick/SKILL.md` | Cron-fired entry point. Delegates to the Python orchestrator. |
| `agent-workspace/scripts/vs-post-reply.sh` | `~/.openclaw/workspace-virtual-scott/scripts/vs-post-reply.sh` | POST helper for the reply skill. Reads reply body from stdin, builds JSON via `jq`, curls to WP. Keeps shell/JSON escaping out of the agent's hands. |
| `agent-workspace/scripts/vs-tick.py` | `~/.openclaw/workspace-virtual-scott/scripts/vs-tick.py` | The autonomous-loop orchestrator. Holds a single-instance fcntl lock so concurrent cron ticks never race. Checks kill switch, fetches + filters comments, dispatches the reply skill via child `openclaw agent` invocations, verifies via WP REST that each reply actually landed, and pushes Telegram notifications (start / reply posted / failure) if `VS_TELEGRAM_BOT_TOKEN` and `VS_TELEGRAM_CHAT_ID` are set. |
| `fixtures/some-commenter-comments.json` | `~/.openclaw/workspace-virtual-scott/fixtures/some-commenter-comments.json` | Canonical test comments used by `make seed-comments`. |

### The autonomous-loop architecture

The split between what runs as a skill (LLM-driven) vs what runs as
a script (deterministic) matters because Qwen3-Coder tends to
narrate the steps of a multi-step loop in prose rather than execute
them. So:

- **Per-comment reply work runs in the LLM.** Drafting prose,
  applying persona rules, applying the topic gate (in-wheelhouse /
  hedge / decline) — that's the model's job and where it adds value.
- **The loop around it is Python.** Discovery, filtering,
  rate-limiting, dispatch, success verification — all in
  `vs-tick.py`. Predictable and debuggable.
- **The bridge between them is `openclaw agent` invocations.** The
  Python script `subprocess.run`s a fresh child agent for each
  candidate comment, giving each its own session with a clean
  context. The child runs the reply SKILL.md and exits.

Cron tick → Python orchestrator → child agent → reply skill → POST
helper → WP.

### The skill bodies

The reply skill is four atomic steps: GET comment, GET post,
compose reply, POST via helper. Step 3 opens with a **topic gate**
that classifies the comment as in-wheelhouse (full substantive
answer — the default), hedge (open with "I haven't worked much
with X, so this is a guess, but..." then attempt anyway), or
decline (medical/legal/financial advice or crypto/finance — short
polite refusal). The default is in-wheelhouse, so the gate has to
*affirmatively* push a comment into hedge or decline — this biases
the agent toward answering rather than punting on questions it
actually knows.

The POST step uses `exec` with a single-quoted heredoc piped into
`vs-post-reply.sh`. Earlier versions had the agent hand-craft a
`curl -X POST -d '{...}'` one-liner; that requires three layers of
escaping (text → JSON → shell-quoted arg) and the model gets stuck
trying different escapes for many minutes. The heredoc + helper
sidesteps all three layers — the agent only writes plain text.

## 3. WordPress lifecycle

All the commands below are `make` targets in this directory's
[Makefile](Makefile). Run from the sandbox VM unless noted.

**Install / reinstall (idempotent):**

```bash
make install            # apply manifest, wait for ready, run wp core install,
                        # create users (scott, virtual-scott, some-commenter),
                        # configure homepage as title list, disable comment moderation
make creds              # print admin user + password
make url                # print the LAN-reachable WP URL
```

**Get the REST API tokens we need elsewhere:**

```bash
make scott-app-password           # for medium-import (admin scope)
make virtual-scott-app-password   # for the agent (Editor scope)
make passwords                    # show both stored tokens
```

Both tokens are cached in a k8s secret (`openclaw-app-passwords` in
the `wordpress` namespace) so subsequent calls return the same
value instead of minting a new one.

**Load blog posts:**

Use the [medium-import/](medium-import/) workflow. Scrapes the real
blog once to a local cache, then bulk-imports to the sandbox via
REST. See its own [README](medium-import/README.md) for the
two-step download + upload.

**Manage comments (for repeatable demos):**

```bash
make wipe-comments      # delete every WP comment (destructive)
make seed-comments      # POST 4 canonical some-commenter comments
make reset-comments     # both in one step — fresh demo state
```

The canonical fixtures live in
[fixtures/some-commenter-comments.json](fixtures/some-commenter-comments.json).
Edit there to change the test rubric.

**Uninstall:**

```bash
make uninstall                          # remove deployments; PVCs survive
kubectl delete namespace wordpress      # full wipe including data
```

## 4. OpenClaw lifecycle

**Prereqs:** OpenClaw daemon installed (see [INSTALL-OPENCLAW.md](INSTALL-OPENCLAW.md))
and the NUC `code-assistant` pod up.

**Create the agent and install its files (idempotent):**

```bash
make create-agent                  # openclaw agents add virtual-scott
make install-persona               # PERSONA.md → SOUL.md + IDENTITY/USER + remove BOOTSTRAP.md
make install-skill                 # all three skills + the two helper scripts
make install-fixtures              # fixture scripts for wipe/seed
make agent-status                  # verify the agent is registered and workspace is populated
```

**Smoke-test the agent:**

```bash
openclaw agent --agent virtual-scott --message "Hello — what do you know about edge AI on NUCs?"
```

Expect a dry, first-person reply signed `— Virtual Scott`. First
call is slow (cold OVMS path, ~10–15s before tokens stream).

**Reply to a specific comment by id (manual):**

```bash
openclaw agent --agent virtual-scott --message \
  'Read /home/smbaker/.openclaw/workspace-virtual-scott/skills/virtual-scott-reply/SKILL.md and execute its 4 steps for COMMENT_ID=N.'
```

**Autonomous loop:**

```bash
make install-cron       # register the every-5-minute cron job (disabled)
make enable-cron        # start firing
make cron-status        # next-fire time, last-fire time, status
make cron-runs          # last 10 cron run history (set N=20 for more)

make cron-run           # fire one tick now via cron (debug)
make poll-now           # fire one tick now WITHOUT cron (deterministic — runs vs-tick.py directly)

make pause              # kill switch: next ticks become no-ops
make resume             # un-pause

make disable-cron       # stop firing without removing the job
make uninstall-cron     # remove the job
```

Per-tick outcomes land in two JSONL files under
`~/.openclaw/workspace-virtual-scott/runs/`:

- `successes.jsonl` — one entry per reply that actually landed in WP
- `failures.jsonl` — one entry per failed or no-post-detected attempt

The autonomous loop is rate-limited to one reply per tick by
default (`VS_MAX_REPLIES_PER_CYCLE=1`). Bump for one-shot backlog
drain: `VS_MAX_REPLIES_PER_CYCLE=5 make poll-now`.

## 5. Troubleshooting

**The autonomous loop appears stuck.** First check `make pause`
hasn't been left on — `ls ~/.openclaw/workspace-virtual-scott/PAUSED`.
Then `make cron-status` to see if the cron is enabled. Then
`pgrep -af vs-tick.py` to see if a tick is currently in flight
(they take a couple of minutes when there's work).

**Replies aren't landing despite ticks reporting success.** Tail
the failure log: `tail ~/.openclaw/workspace-virtual-scott/runs/failures.jsonl`.
Look for `action: no_post_detected` entries — those mean the
child agent exited 0 but never actually POSTed (almost always
because the model hit its internal time budget mid-compose).
The full per-attempt trace is at `/tmp/vs-reply-<comment-id>.log`.

**Agent CLI complains about "scope upgrade pending approval".** The
CLI device's local scopes haven't been elevated. Either:
(a) Patch the device store directly per
[INSTALL-OPENCLAW.md](INSTALL-OPENCLAW.md) "Grant the CLI admin scopes"
(recommended; the autonomous loop needs this anyway), or
(b) Ignore it — embedded-mode fallback works for most agent
invocations, just noisy.

**WP REST returns 401 with `rest_not_logged_in`.** The
`WP_ENVIRONMENT_TYPE=local` env var isn't being set on the WP
container. By default WordPress refuses App-Password REST auth
over non-HTTPS unless the environment type is `local` or
`development`. The manifest sets this; check it's still there if
you've reapplied: `kubectl exec -n wordpress deploy/wordpress -- env | grep WP_ENVIRONMENT_TYPE`.

**The agent picked the wrong topic-gate bucket.** Step 3's topic
gate classifies the comment as in-wheelhouse / hedge / decline based
on the model's reading. Misclassifications happen in both directions:
in-wheelhouse comments occasionally get a hedge opener they don't
need, and (rarer) genuinely out-of-wheelhouse questions skip the
hedge. The gate defaults to in-wheelhouse if the model is unsure, so
the failure mode skews toward over-answering rather than over-
deflecting. Tighter classification would mean a longer skill body or
a larger model — both deferred.

**Cron job UUID vs name confusion.** Several `openclaw cron`
subcommands (run, enable, disable, rm) want the job's UUID, not its
name. The Makefile targets handle this for you (each looks up the
UUID via `openclaw cron show <name>`); when invoking openclaw
directly, get the UUID from `openclaw cron show virtual-scott-tick`.

**Cold start is slow.** First model call after the `code-assistant`
pod restarts hits a ~13-second GPU compile. Subsequent calls
stream in 150ms TTFT range.

**Daemon logs and forensic state:**

```bash
# OpenClaw daemon log (gateway, agent, tools all in one stream):
journalctl --user -u openclaw-gateway.service -f

# Per-tick orchestrator output (manual or cron):
tail -f /tmp/vs-reply-*.log

# Agent session JSONL (full message + tool-call history):
ls ~/.openclaw/agents/virtual-scott/sessions/

# Cron history via openclaw:
make cron-runs N=50
```

**Full reset (clean slate for demos):**

```bash
make pause                  # halt the autonomous loop
make reset-comments         # wipe WP comments + reseed canonical 4
make resume                 # restart the loop; next tick will start processing
```

If you want a deeper wipe — agent state, session history, the works:

```bash
make pause
openclaw agents delete virtual-scott    # drops agent + workspace
make create-agent install-persona install-skill install-fixtures
make resume
```
