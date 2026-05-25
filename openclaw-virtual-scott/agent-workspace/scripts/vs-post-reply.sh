#!/bin/bash
# vs-post-reply.sh — POST a comment reply to the sandbox WordPress
# as the `virtual-scott` user.
#
# Usage:
#   vs-post-reply.sh POST_ID PARENT_ID < reply.txt
#
# Reads the reply body from stdin. Plain text is fine — newlines,
# quotes, em-dashes, backslashes all OK. The script handles JSON
# escaping via jq and POSTs via curl. The agent (or the user)
# doesn't have to think about shell quoting or JSON encoding.
#
# Output: the WP REST response body, followed by a final line of
# the form `__STATUS__<HTTP_code>`. The agent should check that line
# for `__STATUS__201`; anything else is a failure.
#
# Substituted at install time by `make install-skill`:
#   __WP_HOST__        — sandbox VM's primary LAN IP
#   __VS_WP_AUTH_B64__ — base64('virtual-scott:<App Password>')

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 POST_ID PARENT_ID < reply.txt" >&2
    echo "__STATUS__000" >&2
    exit 1
fi

POST_ID=$1
PARENT_ID=$2

REPLY=$(cat)

if [ -z "$REPLY" ]; then
    echo "ERROR: empty reply body on stdin" >&2
    echo "__STATUS__000"
    exit 1
fi

# Build the JSON payload with jq so all escaping is correct.
JSON=$(jq -n \
    --argjson post   "$POST_ID" \
    --argjson parent "$PARENT_ID" \
    --arg     content "$REPLY" \
    '{post:$post, parent:$parent, content:$content, status:"approve"}')

curl -sw "\n__STATUS__%{http_code}\n" \
    -X POST 'http://__WP_HOST__:30080/wp-json/wp/v2/comments' \
    -H 'Authorization: Basic __VS_WP_AUTH_B64__' \
    -H 'Content-Type: application/json' \
    -d "$JSON"
