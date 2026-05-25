#!/bin/bash
# seed-comments.sh — seed the sandbox WP with canonical test comments
# from `some-commenter`, used as input fixtures for testing the
# Virtual Scott reply pipeline.
#
# Reads ./fixtures/some-commenter-comments.json and POSTs each entry
# via the WP REST API authenticated as `scott` (admin).
#
# Substituted at install time:
#   __WP_HOST__         — sandbox VM's primary LAN IP
#   __SCOTT_AUTH_B64__  — base64('scott:<scott's App Password>')
#
# Re-runnable: but each run creates DUPLICATE comments. Pair with
# `wipe-comments.sh` for a clean slate.
set -euo pipefail

FIXTURE_FILE=${1:-fixtures/some-commenter-comments.json}
WP_BASE="http://__WP_HOST__:30080/wp-json/wp/v2"
AUTH_HDR="Authorization: Basic __SCOTT_AUTH_B64__"

if [ ! -f "$FIXTURE_FILE" ]; then
    echo "ERROR: fixture file not found: $FIXTURE_FILE" >&2
    exit 1
fi

# Pre-fetch all posts so we can map slug → id
POSTS=$(curl -fsS "$WP_BASE/posts?per_page=100" -H "$AUTH_HDR")

count=0
jq -c '.[]' "$FIXTURE_FILE" | while read -r entry; do
    slug=$(echo "$entry" | jq -r '.post_slug')
    content=$(echo "$entry" | jq -r '.content')

    post_id=$(echo "$POSTS" | jq -r --arg s "$slug" '.[] | select(.slug == $s) | .id' | head -1)
    if [ -z "$post_id" ]; then
        echo "  SKIP: no post with slug '$slug' (did medium-import run?)" >&2
        continue
    fi

    # Build JSON body via jq (handles escaping)
    body=$(jq -n \
        --argjson post "$post_id" \
        --arg name "Some Commenter" \
        --arg email "some-commenter@example.com" \
        --argjson author 3 \
        --arg content "$content" \
        '{post:$post, author:$author, author_name:$name, author_email:$email, content:$content, status:"approve"}')

    resp=$(curl -sw "\n__STATUS__%{http_code}" -X POST "$WP_BASE/comments" \
        -H "$AUTH_HDR" -H 'Content-Type: application/json' \
        -d "$body")
    status=$(echo "$resp" | tail -1 | sed 's/__STATUS__//')
    new_id=$(echo "$resp" | head -1 | jq -r '.id // "?"')

    if [ "$status" = "201" ]; then
        echo "  seeded comment $new_id on post $post_id ('$slug')"
        count=$((count + 1))
    else
        echo "  FAILED on post $post_id ('$slug'): HTTP $status" >&2
        echo "$resp" | head -2 >&2
    fi
done

echo "Done."
