#!/bin/bash
# wipe-comments.sh — force-delete ALL comments from the sandbox WP.
# Uses `wp comment delete --force` via wp-cli inside the WP pod.
# Use before `seed-comments.sh` for a clean repeatable demo.
#
# This is destructive but the destination is the sandbox WP only.
# All comments (test fixtures, agent replies, the WP default seed) go.

set -euo pipefail

WP_POD_EXEC=${WP_POD_EXEC:-"kubectl exec -n wordpress deploy/wordpress -- wp --allow-root --path=/var/www/html"}

ids=$($WP_POD_EXEC comment list --field=comment_ID 2>/dev/null | tr -d '\r')
count=$(echo -n "$ids" | grep -c . 2>/dev/null || echo 0)

if [ "$count" -eq 0 ]; then
    echo "No comments to delete."
    exit 0
fi

echo "Deleting $count comment(s)..."
echo "$ids" | xargs $WP_POD_EXEC comment delete --force 2>&1 | tail -5
echo "Done. Remaining comments:"
$WP_POD_EXEC comment list --fields=comment_ID,comment_author,comment_post_ID --format=table 2>&1 | head -5
