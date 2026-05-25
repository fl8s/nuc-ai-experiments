#!/usr/bin/env python3
"""
vs-tick.py — one autonomous tick of the Virtual Scott poller.

Invoked from `skills/virtual-scott-tick/SKILL.md` which is fired by
the OpenClaw cron job named `virtual-scott-tick` every 5 minutes.
Also runnable directly for manual testing (`make poll-now`).

What it does, in order:

1. Check the kill switch file
   `~/.openclaw/workspace-virtual-scott/PAUSED`. If present, exit
   immediately with a log line.
2. Take an exclusive non-blocking lock on `runs/vs-tick.lock`. If
   another vs-tick.py is already running, log a line and exit 0.
   The model is single-tenant on the iGPU; concurrent ticks would
   just race in their post-processing and confuse the accounting.
3. GET all approved comments from the sandbox WP REST API
   (public read, no auth required).
4. Filter candidates per the same rules as `virtual-scott-poll`:
   skip self (author=2), skip virtual-scott anon-named, skip blog
   owner (author=1), skip WP's default seed, skip pure filler, and
   skip anything already replied to per WP OR per our local
   successes.jsonl (guards the WP eventual-consistency window
   between POSTing a reply and that reply showing up in subsequent
   GET /comments queries).
5. For each candidate (capped at `VS_MAX_REPLIES_PER_CYCLE`, default
   1), shell out to `openclaw agent` and have it run the
   `virtual-scott-reply` skill for that comment id. Each child
   invocation is a separate agent session.
6. After each child agent run, verify the reply actually landed —
   poll both the WP REST endpoint and the agent log on every
   iteration (up to 6 iterations, 5s backoff). Either signal is
   sufficient. Verification runs regardless of the agent's exit
   code, since the agent can fail its final report step after a
   successful POST.
7. Log each attempt to `runs/successes.jsonl` or
   `runs/failures.jsonl` in the workspace.
8. Push Telegram notifications if VS_TELEGRAM_BOT_TOKEN and
   VS_TELEGRAM_CHAT_ID are set: a "starting" ping when work begins on
   a comment, a "reply posted" ping when the reply lands in WP, and a
   "attempt failed" ping on each failure path (timeout / failed /
   no_post_detected / exception). Best-effort: Telegram failures are
   logged at WARN and never affect the tick.

This script is intentionally NOT a SKILL.md — agent multi-step
orchestration is unreliable. The trigger fires a wrapper skill whose
only step is "run this script and report its output." All real
orchestration lives here, in Python where it's deterministic.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

WORKSPACE      = Path.home() / ".openclaw" / "workspace-virtual-scott"
PAUSED_FILE    = WORKSPACE / "PAUSED"
RUNS_DIR       = WORKSPACE / "runs"
FAILURES_LOG   = RUNS_DIR / "failures.jsonl"
SUCCESSES_LOG  = RUNS_DIR / "successes.jsonl"
TICK_LOCK_FILE = RUNS_DIR / "vs-tick.lock"
REPLY_SKILL    = WORKSPACE / "skills" / "virtual-scott-reply" / "SKILL.md"

WP_HOST = "__WP_HOST__"
WP_BASE = f"http://{WP_HOST}:30080/wp-json/wp/v2"

# Default 1 reply per tick. With 5-min cron intervals that's effectively
# 12 replies/hour max — comfortably under any reasonable rate budget for
# the sandbox, and well within the agent's per-turn time budget. Raise
# via VS_MAX_REPLIES_PER_CYCLE if processing a comment backlog.
MAX_REPLIES = int(os.environ.get("VS_MAX_REPLIES_PER_CYCLE", "1"))
AGENT_TIMEOUT_SEC = int(os.environ.get("VS_AGENT_TIMEOUT_SEC", "600"))

FILLER_PATTERNS = [
    re.compile(r"^thanks?!?\.?$", re.I),
    re.compile(r"^nice (post|article|read)", re.I),
    re.compile(r"^(great|good|cool|awesome|amazing) (post|article|stuff|read)", re.I),
    re.compile(r"^first!?$", re.I),
]


def ts():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log(msg):
    print(f"[{ts()}] {msg}", flush=True)


def write_jsonl(path, entry):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(entry) + "\n")


def is_filler(content_html):
    text = re.sub(r"<[^>]*>", "", content_html)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) < 25:
        return True
    return any(p.search(text) for p in FILLER_PATTERNS)


def fetch_comments():
    url = f"{WP_BASE}/comments?status=approve&per_page=100&order=desc&orderby=date"
    req = Request(url)
    with urlopen(req, timeout=30) as resp:
        return json.load(resp)


def load_local_replied_cids():
    """Comment ids we've already successfully replied to, per our own
    successes.jsonl. This is the local ground truth and is checked in
    addition to the WP REST query: WP's GET /comments occasionally lags
    a freshly-POSTed reply by a minute or two, and in that window the
    candidate filter would otherwise re-dispatch the same comment to a
    new child agent and cause a duplicate reply."""
    cids = set()
    if not SUCCESSES_LOG.exists():
        return cids
    with open(SUCCESSES_LOG) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("action") in ("replied", "replied_with_agent_error"):
                cids.add(e.get("comment_id"))
    return cids


def filter_candidates(comments, skip_cids=None):
    skip_cids = skip_cids or set()
    candidates = []
    for c in comments:
        if c.get("author") == 2:
            continue  # self (authenticated)
        if c.get("author_name") == "Virtual Scott":
            continue  # self (anon-named artifact)
        if c.get("author") == 1:
            continue  # blog owner
        if c.get("author") == 0 and c.get("author_name") == "A WordPress Commenter":
            continue  # WP default seed
        if any(o.get("parent") == c["id"] and o.get("author") == 2 for o in comments):
            continue  # already replied by self (per WP)
        if c["id"] in skip_cids:
            continue  # already replied per local successes.jsonl
        if is_filler(c.get("content", {}).get("rendered", "")):
            continue  # pure filler
        candidates.append(c)
    return sorted(candidates, key=lambda c: c["id"])


def acquire_tick_lock():
    """Take an exclusive non-blocking lock on the tick lockfile so only
    one vs-tick.py runs at a time. Returns the open file handle on
    success (caller MUST keep the reference alive — the OS releases the
    lock when the file is closed / process exits). Returns None if
    another tick already holds it; the caller should log and exit."""
    TICK_LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fh = open(TICK_LOCK_FILE, "w")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fh.close()
        return None
    fh.write(f"{os.getpid()}\n")
    fh.flush()
    return fh


def reply_via_child_agent(comment_id):
    session_id = f"tick-reply-{comment_id}-{int(time.time())}"
    msg = (
        f"Read {REPLY_SKILL} and execute its steps for "
        f"COMMENT_ID={comment_id}. Use the helper script at "
        f"~/.openclaw/workspace-virtual-scott/scripts/vs-post-reply.sh "
        f"for step 4. Apply the topic gate at the top of step 3 "
        f"(decline / hedge / in-wheelhouse) before composing. Do not "
        f"skip step 4."
    )
    log_path = Path(f"/tmp/vs-reply-{comment_id}.log")
    with open(log_path, "w") as logf:
        result = subprocess.run(
            ["openclaw", "agent", "--agent", "virtual-scott",
             "--session-id", session_id, "--message", msg],
            stdout=logf, stderr=subprocess.STDOUT,
            timeout=AGENT_TIMEOUT_SEC,
        )
    return result.returncode, session_id, log_path


def _scan_log_for_reply(log_path):
    """Search the agent log for the agent's own success patterns.
    Returns dict with id if found, else None. Cheap; safe to call
    repeatedly inside the WP-retry loop."""
    if not log_path or not Path(log_path).exists():
        return None
    try:
        text = Path(log_path).read_text(errors="ignore")
    except OSError:
        return None
    m = re.search(r"Posted comment (\d+) as a reply", text)
    if not m:
        m = re.search(r"#comment-(\d+)", text)
    if m:
        return {"id": int(m.group(1)), "link": None, "source": "agent_log_report"}
    if "__STATUS__201" in text:
        ids = re.findall(r'"id"\s*:\s*(\d+)', text)
        if ids:
            return {"id": int(ids[-1]), "link": None, "source": "agent_log_status201"}
    return None


def check_reply_landed(comment_id, log_path=None):
    """Did a virtual-scott reply actually land for `comment_id`?

    Polls both the WP REST endpoint and the agent log on every
    iteration (6 attempts, 5s backoff = 30s max wait). Either
    signal is sufficient. The log scan runs first each iteration
    because the agent's "Posted comment N as a reply" line often
    appears in the log before WP indexes the new comment.

    Returns dict with id (and optionally link) if found, else None."""
    url = f"{WP_BASE}/comments?parent={comment_id}&status=approve&per_page=10"
    for attempt in range(6):
        # Log scan first — cheap, no network, catches the case where
        # the agent has just finished writing its final report.
        landed = _scan_log_for_reply(log_path)
        if landed:
            return landed
        # WP REST query — slower but authoritative once WP indexes.
        try:
            with urlopen(Request(url), timeout=15) as resp:
                for c in json.load(resp):
                    if c.get("author") == 2:
                        return {"id": c["id"], "link": c.get("link")}
        except Exception:
            pass
        if attempt < 5:
            time.sleep(5)
    return None


def _telegram_send(body):
    """Best-effort push to Telegram. Silent no-op if creds missing.
    Never raises — Telegram failure must not affect tick outcome."""
    token = os.environ.get("VS_TELEGRAM_BOT_TOKEN")
    chat_id = os.environ.get("VS_TELEGRAM_CHAT_ID")
    if not token or not chat_id:
        return
    try:
        urlopen(
            Request(
                f"https://api.telegram.org/bot{token}/sendMessage",
                data=urlencode({"chat_id": chat_id, "text": body}).encode(),
            ),
            timeout=10,
        )
    except Exception as e:
        log(f"  WARN: Telegram notify failed: {e}")


def notify_telegram_start(cid, post_id, author_name, comment_text):
    snippet = re.sub(r"<[^>]*>", "", comment_text or "").strip()
    _telegram_send(
        f"Virtual Scott — starting reply\n\n"
        f"Comment {cid} (post {post_id}) by {author_name or 'unknown'}:\n"
        f"\"{snippet[:300]}\""
    )


def notify_telegram_done(comment_text, reply_text, wp_link):
    snippet = re.sub(r"<[^>]*>", "", comment_text or "").strip()
    _telegram_send(
        "Virtual Scott — reply posted\n\n"
        f"Comment: {snippet[:200]}\n\n"
        f"Reply: {(reply_text or '').strip()[:400]}\n\n"
        f"{wp_link or ''}"
    )


def notify_telegram_failure(cid, action, detail=""):
    """Best-effort failure ping. The cron loop will retry on its own,
    but the start-notify already buzzed — this completes the picture so
    the user isn't left wondering why the DONE never came."""
    msg = f"Virtual Scott — attempt failed ({action})\n\nComment {cid}"
    if detail:
        msg += f"\n{detail}"
    msg += "\n\nCron will retry on the next tick."
    _telegram_send(msg)


def fetch_reply_text(reply_id):
    """Pull the new reply's body back from WP for the Telegram payload.
    Falls back to None on any error — Telegram is best-effort."""
    if not reply_id:
        return None
    try:
        with urlopen(Request(f"{WP_BASE}/comments/{reply_id}"), timeout=10) as resp:
            data = json.load(resp)
        return re.sub(r"<[^>]*>", "", data.get("content", {}).get("rendered", "")).strip()
    except Exception:
        return None


def load_logged_reply_ids():
    """Set of WP reply ids that we've already recorded in
    successes.jsonl. Used to detect orphans — replies that landed in
    WP but never got a success entry (and therefore never got a
    done-Telegram)."""
    ids = set()
    if not SUCCESSES_LOG.exists():
        return ids
    with open(SUCCESSES_LOG) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            wp_reply_id = e.get("wp_reply_id")
            if wp_reply_id:
                ids.add(wp_reply_id)
    return ids


def backfill_orphan_replies(comments):
    """Find virtual-scott replies in WP that have no successes.jsonl
    entry, write a synthetic success entry for each, and fire a
    catch-up done-Telegram. This recovers the case where a previous
    tick's check_reply_landed gave up too early but the reply
    actually landed."""
    logged = load_logged_reply_ids()
    by_id = {c["id"]: c for c in comments}
    recovered = 0
    for c in comments:
        if c.get("author") != 2:
            continue  # only virtual-scott's own replies
        if c["id"] in logged:
            continue  # already recorded
        parent_id = c.get("parent")
        if not parent_id or parent_id == 0:
            continue
        parent = by_id.get(parent_id)
        if not parent:
            continue
        log(f"  backfill: WP reply {c['id']} (parent {parent_id}) has no success entry — recovering")
        entry = {
            "ts": ts(),
            "comment_id": parent_id,
            "post_id": parent.get("post"),
            "author_name": parent.get("author_name"),
            "action": "replied_backfill",
            "wp_reply_id": c["id"],
            "wp_reply_link": c.get("link"),
            "note": "backfill — reply visible in WP but no prior success entry",
        }
        write_jsonl(SUCCESSES_LOG, entry)
        parent_html = parent.get("content", {}).get("rendered", "")
        reply_text = re.sub(r"<[^>]*>", "",
                            c.get("content", {}).get("rendered", "")).strip()
        notify_telegram_done(parent_html, reply_text, c.get("link"))
        recovered += 1
    if recovered:
        log(f"Backfilled {recovered} orphan repl{'y' if recovered == 1 else 'ies'}.")
    return recovered


def main():
    if PAUSED_FILE.exists():
        log(f"PAUSED ({PAUSED_FILE.name} present) — skipping cycle")
        return 0

    # Only one vs-tick.py at a time. We can only do one reply at a time
    # anyway (model is single-tenant on the iGPU); concurrent ticks just
    # race and confuse the accounting. Lock is held for the lifetime of
    # this process and released automatically on exit.
    lock = acquire_tick_lock()
    if lock is None:
        log("Another vs-tick.py is already running; exiting.")
        return 0

    log("Fetching comments...")
    try:
        comments = fetch_comments()
    except Exception as e:
        log(f"ERROR fetching comments: {e}")
        write_jsonl(FAILURES_LOG, {
            "ts": ts(), "phase": "fetch_comments", "error": str(e),
        })
        return 1

    # Catch up on any replies that landed in WP but never made it
    # into successes.jsonl (and therefore never got a done-Telegram).
    # Runs before the candidate filter so the backfilled successes
    # entries also feed load_local_replied_cids() below.
    backfill_orphan_replies(comments)

    skip_cids = load_local_replied_cids()
    candidates = filter_candidates(comments, skip_cids)
    log(f"Found {len(candidates)} candidate(s); cap = {MAX_REPLIES}")

    if not candidates:
        log("Nothing to do.")
        return 0

    processed = 0
    for c in candidates[:MAX_REPLIES]:
        cid = c["id"]
        comment_html = c.get("content", {}).get("rendered", "")
        snippet = re.sub(r"<[^>]*>", "", comment_html)[:60]

        log(f"Replying to comment {cid} ('{snippet}...')")
        entry = {
            "ts": ts(),
            "comment_id": cid,
            "post_id": c.get("post"),
            "author_name": c.get("author_name"),
        }
        notify_telegram_start(cid, c.get("post"), c.get("author_name"), comment_html)
        try:
            rc, session_id, log_path = reply_via_child_agent(cid)
            entry["session_id"] = session_id
            entry["log"] = str(log_path)
            entry["returncode"] = rc

            # Run regardless of rc — the agent CLI can exit non-zero
            # after successfully POSTing the reply (e.g. it errors
            # during the final report step), and we still want to
            # record the reply as landed.
            landed = check_reply_landed(cid, log_path)

            if landed:
                entry["action"] = "replied" if rc == 0 else "replied_with_agent_error"
                entry["wp_reply_id"] = landed["id"]
                entry["wp_reply_link"] = landed.get("link")
                if landed.get("source"):
                    entry["landed_source"] = landed["source"]
                write_jsonl(SUCCESSES_LOG, entry)
                log(f"  comment {cid}: replied (WP comment {landed['id']}, rc={rc})")
                reply_text = fetch_reply_text(landed["id"])
                notify_telegram_done(comment_html, reply_text, landed.get("link"))
            elif rc == 0:
                entry["action"] = "no_post_detected"
                entry["note"] = "agent exited 0 but no WP reply landed"
                write_jsonl(FAILURES_LOG, entry)
                log(f"  comment {cid}: NO POST detected despite exit 0 — see {log_path}")
                notify_telegram_failure(cid, "no_post_detected",
                                        f"Agent exited cleanly but no reply landed in WP.")
            else:
                entry["action"] = "failed"
                write_jsonl(FAILURES_LOG, entry)
                log(f"  comment {cid}: FAILED (exit {rc}) — see {log_path}")
                notify_telegram_failure(cid, "failed",
                                        f"Agent exited with rc={rc} (often LLM request timeout).")
        except subprocess.TimeoutExpired:
            entry["action"] = "timeout"
            entry["timeout_sec"] = AGENT_TIMEOUT_SEC
            write_jsonl(FAILURES_LOG, entry)
            log(f"  comment {cid}: TIMEOUT after {AGENT_TIMEOUT_SEC}s")
            notify_telegram_failure(cid, "timeout",
                                    f"Child agent killed after {AGENT_TIMEOUT_SEC}s wall clock.")
        except Exception as e:
            entry["action"] = "exception"
            entry["error"] = str(e)
            write_jsonl(FAILURES_LOG, entry)
            log(f"  comment {cid}: EXCEPTION {e}")
            notify_telegram_failure(cid, "exception", str(e)[:200])
        processed += 1

    log(f"Tick done. Processed {processed} of {len(candidates)} candidate(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
