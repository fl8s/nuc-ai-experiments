---
name: virtual-scott-poll
description: Scan the sandbox WordPress for comments that virtual-scott should respond to and report a short list. Does NOT post replies — that's virtual-scott-reply's job. Filters out comments by virtual-scott itself, by the blog owner scott, by anonymous authors, comments that already have a virtual-scott reply, and obvious filler.
user-invocable: true
---

# Find comments worth replying to

Produce a short prioritised list of WordPress comments that Virtual
Scott should respond to. This skill **does not post anything** — it
only discovers and filters. After running, the human (or a scheduled
runner) decides whether to invoke `virtual-scott-reply` for each id
in the list.

Why split off the reply step: actual reply generation is expensive
(cold OVMS path ≥ 30 s per reply) and reply correctness is graded
post-hoc. Doing discovery + reply in a single agent run risks looping,
high iGPU usage, and shipping many marginal replies on the same
invocation. Discover-then-confirm-then-reply is safer.

## Step 1: GET all approved comments

Make this tool call:

- **Tool:** `web_fetch`
- **Method:** GET
- **URL:** `http://__WP_HOST__:30080/wp-json/wp/v2/comments?status=approve&per_page=100&order=desc&orderby=date`

From the response capture the full array. For each comment, extract:
`id`, `post`, `parent`, `author` (numeric user_id), `author_name`,
`content.rendered` (call this `BODY`), `date`.

## Step 2: Filter the candidate set

Drop any comment matching ANY of these rules. The remaining set
becomes the candidates.

1. **Self (authenticated).** `author == 2` (virtual-scott user_id).
   Don't reply to yourself.
2. **Self (anonymous artifact).** `author_name == "Virtual Scott"`
   regardless of `author`. Catches manually-created anon comments
   left over from debugging (author=0 + name=Virtual Scott).
3. **Blog owner.** `author == 1` (scott admin user_id). Don't reply
   to the blog owner's own comments.
4. **Anonymous default.** `author == 0` AND `author_name == "A
   WordPress Commenter"`. WP's default seed comment; skip.
5. **Already replied.** Some other comment in the full array has
   `parent == comment.id` AND its `author == 2`. (i.e., virtual-scott
   has already posted a reply in this comment's thread.)
6. **Pure filler.** `BODY` (stripped of HTML tags) matches any of:
   - Under 25 characters total
   - Matches one of these patterns case-insensitively (regex-style):
     `^thanks?\!?\.?$`, `^nice (post|article|read)`,
     `^(great|good|cool|awesome|amazing) (post|article|stuff|read)`,
     `^first\!?$`, only emoji/punctuation.

   Filler comments may be technically polite but the persona rule is
   "half a useful answer beats a confident wrong one" — there's
   nothing meaningful to answer, so don't.

## Step 3: Report the candidates

For each surviving comment, print one row:

```
{id}  post:{post_id}  by:{author_name}  "{body, truncated to 80 chars}"
```

Sort by `id` ascending (oldest first — fairest to commenters who've
been waiting longest).

If the list is empty, print exactly: `No comments need a reply.`

Cap the report at 10 candidates. If the unfiltered candidates
exceed 10, mention `(N additional candidates not listed)`.

## Step 4: Suggest next-step invocations

For each candidate in the report, print a copy-pasteable line for
the human:

```
To reply: openclaw agent --agent virtual-scott --message 'Read /home/smbaker/.openclaw/workspace-virtual-scott/skills/virtual-scott-reply/SKILL.md and execute its 4 steps for COMMENT_ID={id}.'
```

The cron-fired `virtual-scott-tick` skill automates discover-and-
reply for the autonomous loop. This `poll` skill is the read-only
manual-inspection version: a human runs it to see what would be
replied to before letting the autonomous loop process it.

## What this skill deliberately does NOT do

- **Does not reply.** Discovery only.
- **Does not retry on errors.** If the GET in step 1 returns
  non-2xx, report the status and stop.
- **Does not write to WP.** Read-only against the REST API. No auth
  header needed for step 1 (public read).
- **Does not invoke other skills.** Agent loops nesting skills are
  unreliable on Qwen3-Coder; we keep skills independent.
