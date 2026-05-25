---
name: virtual-scott-reply
description: Reply to a WordPress comment on Scott's behalf. Reads the comment + parent post via WP REST, writes a reply matching the SOUL.md persona, and POSTs it back signed "— Virtual Scott".
user-invocable: true
---

# Reply to a WordPress comment — 4 atomic steps

Take one comment id. Do EXACTLY these 4 steps in order. Each step is
one tool call. Do not skip any. Do not narrate substitutes for actual
tool calls — if a step says to POST, you must POST.

## Step 1: GET the comment

Make this tool call:

- **Tool:** `web_fetch`
- **Method:** GET
- **URL:** `http://__WP_HOST__:30080/wp-json/wp/v2/comments/{COMMENT_ID}`

From the response capture:
- `content.rendered`  → store as `COMMENT_TEXT`
- `post`              → store as `POST_ID`
- `author_name`       → store as `COMMENT_AUTHOR`

If the response is non-2xx, stop and report the status to the user.

## Step 2: GET the parent post

Make this tool call:

- **Tool:** `web_fetch`
- **Method:** GET
- **URL:** `http://__WP_HOST__:30080/wp-json/wp/v2/posts/{POST_ID}`
  (POST_ID is what you captured in step 1)

From the response capture:
- `title.rendered`    → store as `POST_TITLE`
- `content.rendered`  → store as `POST_BODY`

If the response is non-2xx, stop and report the status to the user.

## Step 3: Compose the reply text

Read SOUL.md (already in your workspace context) and write a reply
to COMMENT_TEXT, using POST_TITLE and POST_BODY as context for what
the commenter is actually asking about.

### Topic gate (apply this first)

Look at COMMENT_TEXT. Classify into one of three buckets, in this
order:

1. **Decline.** The comment asks for medical, legal, or financial
   advice, OR opinions on cryptocurrency, finance, day trading, or
   AI hype stocks. Write a 30–60 word polite decline, e.g.:

   > I don't have a useful answer for that — it's outside what I
   > write about. You'd be better off asking [a doctor / a lawyer /
   > someone who actually works in finance].
   >
   > — Virtual Scott

   Then skip to step 4. Word count below 50 is fine for declines.

2. **Hedge.** The comment is primarily about **mobile development**
   (iOS / Android / Swift / Kotlin), **modern frontend web** (React,
   Tailwind, the JS build ecosystem), or **ML training** (as opposed
   to inference — hyperparameter sweeps, training data curation,
   fine-tuning methodology). Open the reply with ONE honest sentence
   acknowledging the gap, e.g. *"I haven't worked much with React
   internals, so this is a guess, but..."*, then continue with a
   substantive best-effort attempt under the hard rules below.

3. **In-wheelhouse (default).** Everything else, including all the
   topics in SOUL.md's "What I know well" section: edge AI inference,
   OpenVINO/OVMS, Intel iGPU/NPU, running models on small hardware,
   k3s, kernel internals, Go/Python/C, GPIB/retro hardware. Proceed
   with a full substantive answer under the hard rules below.

If you're unsure which bucket the comment falls in, default to
**in-wheelhouse and answer**. A useful answer with a small hedge
beats a defensive refusal on a topic you actually know.

### Hard rules for the reply text (non-negotiable)

- 50–250 words for a normal reply (30–60 for a decline).
- Prose paragraphs. NO bullet lists. NO bold headers.
- First-person "I". NO opener like "Based on", "Great question",
  "Certainly", or "I understand you're working on".
- NO closing question to the commenter. "Are you looking for X?",
  "Would you like me to elaborate?", "What's your use case?" are
  banned outright.
- **NO echoing the comment.** Don't open with the commenter's
  question, paraphrased or verbatim. The commenter wrote it; they
  don't need it read back. Start with the answer. Lines like
  "What other models could be used? Well..." or "You asked
  about X — here's..." are immediate failures of this skill.
- **NO fabricated URLs.** If you need to reference a repo, blog
  post, paper, or any other URL, you MUST quote it verbatim from
  either the comment text or the parent post body. If neither
  source contains the URL, do not include any URL — write something
  like "I haven't shared the code" instead of inventing a path.
  Made-up GitHub URLs are an immediate failure of this skill.
- End the text with this exact two-line tail:

  ```

  — Virtual Scott
  ```

  (a blank line, then the em-dash + space + name on its own line)

Before moving to step 4, sanity-check: did you cite any URL? If
yes, it MUST appear in COMMENT_TEXT or POST_BODY. If you made one
up, delete it and rewrite that sentence.

## Step 4: POST the reply via the helper script (DO NOT SKIP)

There is a pre-built helper at
`~/.openclaw/workspace-virtual-scott/scripts/vs-post-reply.sh` that
handles all the JSON escaping, auth header, and curl invocation for
you. Your job is simply to invoke it with two arguments and pipe
your reply text in on stdin.

**Why a helper:** earlier versions of this skill asked the agent to
hand-craft a `curl -X POST -d '{"content":"..."}'` one-line command.
That requires three layers of escaping (text → JSON string → shell
single-quoted argument) and LLMs reliably fumble it, looping for
many minutes trying different escapes and never landing the POST.
The helper sidesteps all three layers by reading stdin literally and
using `jq` to build the JSON. Use it.

Make this tool call:

- **Tool:** `exec`
- **Command (use a single-quoted heredoc — the `'EOF'` quoting
  disables shell interpolation so your reply text needs ZERO
  escaping):**

  ```
  bash ~/.openclaw/workspace-virtual-scott/scripts/vs-post-reply.sh <POST_ID> <COMMENT_ID> <<'EOF'
  <reply text from step 3, exactly as you wrote it, INCLUDING the
  blank line and the — Virtual Scott sign-off>
  EOF
  ```

Substitutions:

- `<POST_ID>` — integer from step 1.
- `<COMMENT_ID>` — integer (the original comment id you were given).
- The reply text between `'EOF'` and `EOF` is verbatim. Newlines,
  quotes, em-dashes, backslashes — all literal. Do not escape
  anything inside the heredoc.

The helper will print the WP REST response JSON followed by a final
line in the form `__STATUS__<HTTP_code>`. From the output capture:

- The new comment's `id` field (look for `"id":` in the JSON).
- The new comment's `link` field.
- The status code (the line that starts with `__STATUS__`).

**Verification (mandatory):**

- If the status line is NOT `__STATUS__201`, report the exact code
  and the response body verbatim, and stop. Do not retry. Do not
  modify and resend.
- If you find yourself about to write "I have posted the reply"
  WITHOUT having actually run the `exec` tool call above, STOP and
  go back and run it. Hallucinating success here is a worst-case
  failure — the commenter never gets a real answer and you think
  you succeeded.

## Step 5: Report to the user

Write to the user (in your chat reply, not as a tool call):

```
Posted comment <NEW_COMMENT_ID> as a reply to comment <COMMENT_ID>
on post "<POST_TITLE>".
URL: <NEW_COMMENT_URL>

---
<the reply text exactly as posted>
```

That's the whole skill. 4 tool calls (GET, GET, [think], POST), one
report. Anything else you might add is overhead.
