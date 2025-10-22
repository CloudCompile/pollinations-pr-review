#!/usr/bin/env bash
# .github/scripts/summarize_pr.sh
set -euo pipefail

CACHE_DIR=".github/pr-summary-cache"
mkdir -p "$CACHE_DIR"

POLLINATIONS_REFERRER="${POLLINATIONS_REFERRER:-prisimai.github.io}"
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-32768}"
MAX_ATTEMPTS=4
WAIT_SECONDS=20

# ---- Pull Request context ---------------------------------------------------
EVENT_FILE="${GITHUB_EVENT_PATH:-.github/event.json}"
REPO="${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"
API_BASE="https://api.github.com/repos/${REPO}"

PR_NUMBER=$(jq -r '.pull_request.number // empty' "$EVENT_FILE")
BASE_REF=$(jq -r '.pull_request.base.ref // "main"' "$EVENT_FILE")
[ -z "$PR_NUMBER" ] && { echo "No PR number found"; exit 1; }

git fetch origin "$BASE_REF" || true
git diff "origin/${BASE_REF}...HEAD" > /tmp/pr_diff.txt || true

ADDED=$(git diff --numstat "origin/${BASE_REF}...HEAD" | awk '{a+=$1} END{print a+0}')
REMOVED=$(git diff --numstat "origin/${BASE_REF}...HEAD" | awk '{a+=$2} END{print a+0}')
FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" | wc -l | tr -d ' ')
TOTAL=$((ADDED + REMOVED))
DIFF_HASH=$(sha256sum /tmp/pr_diff.txt | awk '{print $1}')
CACHE_JSON="${CACHE_DIR}/${DIFF_HASH}.json"
CACHE_SUMMARY="${CACHE_DIR}/${DIFF_HASH}.summary.txt"

# ---- Try cache --------------------------------------------------------------
if [ -f "$CACHE_JSON" ] && [ -f "$CACHE_SUMMARY" ]; then
  META_JSON=$(cat "$CACHE_JSON")
  SUMMARY=$(cat "$CACHE_SUMMARY")
else
  DIFF=$(head -c "$MAX_DIFF_BYTES" /tmp/pr_diff.txt || true)
  [ -z "$DIFF" ] && DIFF="(empty diff)"

  REQUEST_BODY=$(jq -n --arg model "openai" --arg diff "$DIFF" '{
    model: $model,
    temperature: 0.4,
    reasoning_effort: "medium",
    messages: [
      {role:"system",content:"You are a senior developer. Reply ONLY with raw JSON. No Markdown, no code fences."},
      {role:"user",content:"Produce plain JSON with keys: summary (string), breaking_change (boolean), risk (low|medium|high), notes (string). Nothing else."},
      {role:"user",content:$diff}
    ]
  }')

  ATTEMPT=1
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "Pollinations attempt $ATTEMPT/$MAX_ATTEMPTS"
    RESP=$(curl -sS -X POST "https://text.pollinations.ai/openai?referrer=${POLLINATIONS_REFERRER}" \
      -H "Content-Type: application/json" -d "$REQUEST_BODY" || true)

    RAW=$(echo "$RESP" | jq -r 'if (.choices) then (.choices[0].message.content // .choices[0].text // "") else . end' 2>/dev/null || echo "$RESP")
    # strip Markdown code fences and extra text
    CLEAN=$(printf "%s" "$RAW" \
  | sed 's/```json//g; s/```//g' \
  | awk 'BEGIN{RS=""; ORS=""} {if (match($0,/\{[[:print:][:space:]]*\}/,m)) print m[0]}' )

    # try parse
    if echo "$CLEAN" | jq empty 2>/dev/null; then
      echo "$CLEAN" > "$CACHE_JSON"
      SUMMARY=$(echo "$CLEAN" | jq -r '.summary // "No summary."')
      echo "$SUMMARY" > "$CACHE_SUMMARY"
      break
    fi
    echo "No valid JSON yet. Waiting ${WAIT_SECONDS}s…"
    sleep "$WAIT_SECONDS"
    ATTEMPT=$((ATTEMPT+1))
  done

  # fallback
  if [ ! -f "$CACHE_JSON" ]; then
    echo "{\"summary\":\"PR changes: ${TOTAL} lines across ${FILES} files.\",\"breaking_change\":false,\"risk\":\"low\"}" > "$CACHE_JSON"
    echo "PR changes: ${TOTAL} lines across ${FILES} files." > "$CACHE_SUMMARY"
  fi

  META_JSON=$(cat "$CACHE_JSON")
  SUMMARY=$(cat "$CACHE_SUMMARY")
fi

RISK=$(echo "$META_JSON" | jq -r '.risk // "medium"')
BREAK=$(echo "$META_JSON" | jq -r '.breaking_change // false')

# ---- Simple label logic -----------------------------------------------------
SIZE="size: XS"
[ "$TOTAL" -ge 50 ] && SIZE="size: Small"
[ "$TOTAL" -ge 200 ] && SIZE="size: Medium"
[ "$TOTAL" -ge 500 ] && SIZE="size: Large"
[ "$TOTAL" -ge 2000 ] && SIZE="size: XL"

RISK_LABEL="risk: ${RISK}"
BREAK_LABEL="breaking-change"

# ---- Comment body -----------------------------------------------------------
read -r -d '' BODY <<EOF || true
🤖 PR Summary by Pollinations.AI  
*(referrer: ${POLLINATIONS_REFERRER})*

### Summary
${SUMMARY}

**Risk Level:** ${RISK}  
**Breaking Change:** ${BREAK}

### Diff Stats
- Files changed: ${FILES}
- Lines added: ${ADDED}
- Lines removed: ${REMOVED}
- Total lines changed: ${TOTAL}

---
_This comment updates automatically._
EOF

COMMENTS_URL="${API_BASE}/issues/${PR_NUMBER}/comments"
COMMENT_ID=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" "${COMMENTS_URL}" |
  jq -r '.[] | select(.user.login=="github-actions[bot]") | select(.body|test("🤖 PR Summary by Pollinations")) | .id' | head -n1)

if [ -n "$COMMENT_ID" ]; then
  curl -s -X PATCH -H "Authorization: token ${GITHUB_TOKEN}" \
    "${API_BASE}/issues/comments/${COMMENT_ID}" -d "$(jq -nc --arg body "$BODY" '{body:$body}')" >/dev/null
else
  curl -s -X POST -H "Authorization: token ${GITHUB_TOKEN}" \
    "${COMMENTS_URL}" -d "$(jq -nc --arg body "$BODY" '{body:$body}')" >/dev/null
fi

# ---- Apply labels -----------------------------------------------------------
LABELS=("$SIZE" "$RISK_LABEL")
[ "$BREAK" = "true" ] && LABELS+=("$BREAK_LABEL")
jq -n --argjson arr "$(printf '%s\n' "${LABELS[@]}" | jq -R . | jq -s .)" '{labels:$arr}' |
  curl -s -X POST -H "Authorization: token ${GITHUB_TOKEN}" \
    "${API_BASE}/issues/${PR_NUMBER}/labels" -d @- >/dev/null

echo "Done."
