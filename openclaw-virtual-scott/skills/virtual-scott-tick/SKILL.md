---
name: virtual-scott-tick
description: Autonomous tick — invoked by the OpenClaw cron job every 5 minutes. Runs the deterministic Python orchestrator that discovers replyable comments and dispatches the reply skill for each. Not meant to be invoked manually outside of `openclaw cron run virtual-scott-tick` or `make poll-now`.
user-invocable: false
---

# Autonomous tick

Cron-fired entry point for the autonomous Virtual Scott loop. This
skill's whole job is to delegate to the deterministic Python
orchestrator at
`~/.openclaw/workspace-virtual-scott/scripts/vs-tick.py`.

The orchestrator handles: kill-switch check, WP REST discovery,
filtering, rate-limit cap, per-candidate dispatch to a child agent
running `virtual-scott-reply`, and success/failure logging into
`runs/successes.jsonl` / `runs/failures.jsonl`.

**Why the logic lives in Python, not in this skill body:** LLM-driven
orchestration of an N-iteration loop with branching is unreliable.
Deterministic shell/Python is the right tool for the loop layer; the
LLM is the right tool for the per-comment reasoning layer. Each per-
comment reply IS a full agent invocation of `virtual-scott-reply` —
so the autonomous behavior is still openclaw-native, just with a thin
deterministic conductor.

## What to do

Run exactly one tool call. That's the entire skill.

- **Tool:** `exec`
- **Command:**
  ```
  python3 /home/smbaker/.openclaw/workspace-virtual-scott/scripts/vs-tick.py
  ```

The script's stdout is human-readable; report it verbatim in your
reply to the user.

If the exit code is non-zero, also report stderr. Do not retry. Do
not try to do the orchestration in your own reasoning instead of
running the script.

## Kill switch

If the file `~/.openclaw/workspace-virtual-scott/PAUSED` exists, the
script prints a "PAUSED" line and exits 0 without doing anything.
Pause: `touch ~/.openclaw/workspace-virtual-scott/PAUSED`. Resume:
`rm ~/.openclaw/workspace-virtual-scott/PAUSED`. The Makefile
exposes `make pause` and `make resume`.

## Configuration

Two env vars, both optional, both honored by the Python script:

- `VS_MAX_REPLIES_PER_CYCLE` (default 1): cap on replies per tick.
- `VS_AGENT_TIMEOUT_SEC` (default 600): timeout per child agent
  invocation.

These can be set in the cron job's env (via OpenClaw cron config)
or directly when running `make poll-now`.
