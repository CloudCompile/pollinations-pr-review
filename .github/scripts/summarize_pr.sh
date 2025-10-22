#!/usr/bin/env bash
set -euo pipefail

# Paths
CACHE_DIR=".github/pr-summary-cache"
mkdir -p "$CACHE_DIR"

EVENT_FILE="${GITHUB_EVENT_PATH:-.github/event.json}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "GITHUB_EVENT_PATH not set or event file not found. Creating a minimal fallback from environment..."
  # Fallback: try to construct minimal fields - this is rare; normally GitHub sets GITHUB_EVENT_PATH
  echo "{}" > "$EVENT_FILE"
fi

# Read PR number and base ref
PR_NUMBER=$(jq -r '.pull_request.number // empty' "$EVENT_FILE")
BASE_REF=$(jq -r '.pull_request.base.ref // empty' "$EVENT_FILE")
HEAD_SHA=$(jq -r '.pull_request.head.sha // empty' "$EVENT_FILE")
REPO="${GITHUB_REPOSITORY}"

if [ -z "$PR_NUMBER" ]; then
  echo "This workflow must run on a pull_request event. Exiting."
  exit 1
fi

echo "Processing PR #$PR_NUMBER on repo $REPO (base: $BASE_REF)"

# Make sure base ref is available
git fetch origin "$BASE_REF" || true

# Store diff (limit size later)
git diff "origin/${BASE_REF}...HEAD" > /tmp/pr_diff.txt || true

# Basic stats
ADDED_LINES=$(git diff --numstat "origin/${BASE_REF}...HEAD" | awk '{a+=$1} END{print a+0}')
REMOVED_LINES=$(git diff --numstat "origin/${BASE_REF}...HEAD" | awk '{a+=$2} END{print a+0}')
TOTAL_CHANGED_FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" | wc -l)
TOTAL_LINES=$((ADDED_LINES + REMOVED_LINES))

echo "Added lines: $ADDED_LINES, Removed lines: $REMOVED_LINES, Files changed: $TOTAL_CHANGED_FILES, Total lines: $TOTAL_LINES"

# Hash the diff to key cache
DIFF_HASH=$(sha256sum /tmp/pr_diff.txt | awk '{print $1}')
CACHE_JSON="${CACHE_DIR}/${DIFF_HASH}.json"
CACHE_SUMMARY="${CACHE_DIR}/${DIFF_HASH}.summary.txt"

# Try to restore existing cache file (we don't use actions/cache here; using repo-local cache files)
if [ -f "$CACHE_JSON" ] && [ -f "$CACHE_SUMMARY" ]; then
  echo "Cache hit for diff hash $DIFF_HASH"
  SUMMARY_TEXT=$(cat "$CACHE_SUMMARY")
  META_JSON=$(cat "$CACHE_JSON")
  IS_CACHED=true
else
  echo "Cache miss for diff hash $DIFF_HASH"
  IS_CACHED=false
fi

# If not cached: call Pollinations API with retries
if [ "$IS_CACHED" = false ]; then
  # Trim or chunk diff to a reasonable size for the model (we'll send up to ~32KB)
  DIFF_PAYLOAD=$(head -c 32768 /tmp/pr_diff.txt | jq -Rs .)

  # Build the user prompt asking for JSON output
  read -r -d '' PROMPT <<'PROMPT' || true
You are a senior developer assistant. Summarize the following GitHub pull request diff for maintainers in JSON format. The JSON must contain keys:
- "summary": a concise professional summary (string).
- "breaking_change": boolean true/false.
- "risk": one of "low", "medium", "high".
- "notes": optional additional notes (string).

Decision-making guidance:
- Consider touched files, dependency updates, deletions, large-scale refactors as increasing risk.
- If the diff changes package.json, Pipfile, requirements.txt, build scripts, CI, or major config, this increases risk.
- If many deletions or changes touching core modules, mark risk as "high".
- If breaking APIs or schema migrations are evident, set breaking_change true.

Respond ONLY with a single JSON object.

Diff:
PROMPT

  # Insert diff into prompt safely by embedding as a string
  FULL_PROMPT="${PROMPT}\n\nDiff:\n${DIFF_PAYLOAD}"

  # Prepare payload for Pollinations /openai endpoint: use model openai and ask for JSON
  REQUEST_BODY=$(jq -n --arg model "openai" \
    --argjson messages "[{\"role\":\"system\",\"content\":\"You are a senior developer summarizing pull requests.\"},{\"role\":\"user\",\"content\":$DIFF_PAYLOAD}]" \
    '{
      model: $model,
      reasoning_effort: "medium",
      temperature: 0.3,
      messages: [
        {role: "system", content: "You are a senior developer summarizing pull requests into JSON with fields summary, breaking_change, risk, notes. Be concise and accurate."},
        {role: "user", content: "Please output a JSON object with keys: summary, breaking_change (true/false), risk (low|medium|high), notes (optional). Use the following diff as input. Do not output anything else than JSON."},
        {role: "user", content: $DIFF_PAYLOAD}
      ]
    }')

  # Retry loop - respects free-tier spacing. We'll attempt 4 times with increasing wait (20s then 20s)
  MAX_ATTEMPTS=4
  ATTEMPT=1
  POLL_RESP=""
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "Pollinations API attempt $ATTEMPT/$MAX_ATTEMPTS..."
    POLL_RESP=$(curl -sS -X POST "https://text.pollinations.ai/openai?referrer=${POLLINATIONS_REFERRER}" \
      -H "Content-Type: application/json" \
      -d "$REQUEST_BODY" || true)

    # Try to extract JSON object from the response text
    # First try to parse the response body as JSON itself (API may return openai-format)
    # If the response contains choices[0].message.content, extract it
    PARSED=$(echo "$POLL_RESP" | jq -r '
      if (.choices != null) then
        (.choices[0].message.content // .choices[0].text) 
      else
        .
      end' 2>/dev/null || echo "")

    # If still empty, fallback to raw response
    if [ -z "$PARSED" ]; then
      PARSED="$POLL_RESP"
    fi

    # Try to find first JSON object in PARSED
    JSON_OBJECT=$(echo "$PARSED" | awk 'match($0,/{/){start=NR; print substr($0, RSTART)}' 2>/dev/null || true)
    # Simpler approach: try to extract object using jq -R . | fromjson
    JSON_CANDIDATE=$(echo "$PARSED" | jq -R 'fromjson? // empty' 2>/dev/null || true)

    if [ -n "$JSON_CANDIDATE" ]; then
      echo "Valid JSON received from Pollinations."
      echo "$JSON_CANDIDATE" > "$CACHE_JSON"
      # Save a human-readable summary (summary field)
      SUMMARY_TEXT=$(echo "$JSON_CANDIDATE" | jq -r '.summary // "No summary."')
      echo "$SUMMARY_TEXT" > "$CACHE_SUMMARY"
      break
    else
      # if not valid JSON, try to extract substring that looks like JSON between first { and last }
      EXTRACTED=$(echo "$PARSED" | sed -n '1h;1!H;${;g;s/.*\({.*}\).*/\1/;p;}' || true)
      # try parse
      if echo "$EXTRACTED" | jq -R 'fromjson? // empty' 2>/dev/null | grep -q .; then
        echo "$EXTRACTED" | jq -R 'fromjson' > "$CACHE_JSON"
        SUMMARY_TEXT=$(cat "$CACHE_JSON" | jq -r '.summary // "No summary."')
        echo "$SUMMARY_TEXT" > "$CACHE_SUMMARY"
        break
      fi
    fi

    # If we reach here, response was not valid JSON / empty -> wait and retry
    echo "Pollinations response not parseable as JSON. Attempt $ATTEMPT failed."
    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
      WAIT=20
      echo "Waiting $WAIT seconds before retrying (respect free-tier rate limits)..."
      sleep $WAIT
    fi
    ATTEMPT=$((ATTEMPT+1))
  done

  # If we still don't have cache json after retries, create a fallback minimal JSON
  if [ ! -f "$CACHE_JSON" ]; then
    echo "Failed to get structured JSON from Pollinations after $MAX_ATTEMPTS attempts. Creating fallback summary using heuristic."
    # Heuristic fallback summary
    HEUR_SUMMARY="PR changes: ${TOTAL_LINES} lines changed across ${TOTAL_CHANGED_FILES} files. Added ${ADDED_LINES}, removed ${REMOVED_LINES}."
    HEUR_BREAK=false
    HEUR_RISK="low"
    if grep -E "package.json|Pipfile|requirements.txt|setup.py|poetry.lock|go.mod|Cargo.toml" /tmp/pr_diff.txt >/dev/null; then
      HEUR_RISK="medium"
    fi
    if [ "$TOTAL_LINES" -gt 500 ]; then HEUR_RISK="high"; fi
    echo "{\"summary\":\"${HEUR_SUMMARY}\",\"breaking_change\":${HEUR_BREAK},\"risk\":\"${HEUR_RISK}\",\"notes\":\"Fallback heuristic summary used after API failures.\"}" > "$CACHE_JSON"
    echo "$HEUR_SUMMARY" > "$CACHE_SUMMARY"
  fi

  # Load meta
  META_JSON=$(cat "$CACHE_JSON")
  SUMMARY_TEXT=$(cat "$CACHE_SUMMARY")
fi

# Ensure we have summary and meta
echo "Final summary (first 400 chars):"
echo "${SUMMARY_TEXT}" | sed -n '1,20p'

RISK=$(echo "$META_JSON" | jq -r '.risk // "medium"')
BREAKING=$(echo "$META_JSON" | jq -r '.breaking_change // false')

# Heuristic adjustments to risk to combine AI + heuristic (Hybrid)
# Start numeric score from heuristic evidence and bump or reduce depending on AI assessment
SCORE=0

# Heuristic: file touches that increase risk
if grep -E "package.json|Pipfile|requirements.txt|setup.py|poetry.lock|go.mod|Cargo.toml" /tmp/pr_diff.txt >/dev/null; then
  SCORE=$((SCORE + 2))
fi
# Large removals or huge change size
if [ "$TOTAL_LINES" -gt 500 ]; then SCORE=$((SCORE + 2)); fi
if [ "$TOTAL_LINES" -gt 200 ] && [ "$TOTAL_LINES" -le 500 ]; then SCORE=$((SCORE + 1)); fi
# Many files changed
if [ "$TOTAL_CHANGED_FILES" -gt 10 ]; then SCORE=$((SCORE + 1)); fi
# deletions heavy
if [ "$REMOVED_LINES" -gt "$ADDED_LINES" ] && [ "$REMOVED_LINES" -gt 100 ]; then SCORE=$((SCORE + 1)); fi

# Interpret AI risk as numeric: low=0, medium=1, high=2
AI_NUM=1
if [ "$RISK" = "low" ]; then AI_NUM=0; fi
if [ "$RISK" = "high" ]; then AI_NUM=2; fi

# Combine: average-ish
COMBINED_NUM=$(( (SCORE + AI_NUM) / 2 ))
FINAL_RISK="medium"
if [ "$COMBINED_NUM" -le 0 ]; then FINAL_RISK="low"; fi
if [ "$COMBINED_NUM" -ge 2 ]; then FINAL_RISK="high"; fi
if [ "$COMBINED_NUM" -eq 1 ]; then FINAL_RISK="medium"; fi

# Breaking change decision: OR of AI opinion + heuristic evidence
HEUR_BREAK=false
if grep -E "BREAKING CHANGE|ALTER TABLE|add_column|remove_column|schema version|migrate" -i /tmp/pr_diff.txt >/dev/null; then
  HEUR_BREAK=true
fi
if [ "$BREAKING" = "true" ] || [ "$BREAKING" = "True" ]; then FINAL_BREAKING=true; else FINAL_BREAKING=$HEUR_BREAK; fi

# Size label by total lines changed
SIZE_LABEL="size: XS"
if [ "$TOTAL_LINES" -lt 50 ]; then SIZE_LABEL="size: XS"; fi
if [ "$TOTAL_LINES" -ge 50 ] && [ "$TOTAL_LINES" -lt 200 ]; then SIZE_LABEL="size: Small"; fi
if [ "$TOTAL_LINES" -ge 200 ] && [ "$TOTAL_LINES" -lt 500 ]; then SIZE_LABEL="size: Medium"; fi
if [ "$TOTAL_LINES" -ge 500 ] && [ "$TOTAL_LINES" -lt 2000 ]; then SIZE_LABEL="size: Large"; fi
if [ "$TOTAL_LINES" -ge 2000 ]; then SIZE_LABEL="size: XL"; fi

RISK_LABEL="risk: ${FINAL_RISK}"

echo "Labels chosen: ${SIZE_LABEL}, ${RISK_LABEL}, breaking-change=${FINAL_BREAKING}"

# Prepare final comment body
read -r -d '' COMMENT_BODY <<EOF || true
🤖 PR Summary by Pollinations.AI  
*(referrer: prisimai.github.io)*

### Summary
${SUMMARY_TEXT}

**Risk Level:** ${FINAL_RISK}
**Breaking Change:** ${FINAL_BREAKING}

---  
_This comment is generated automatically. It will be updated (not duplicated) on new commits to this PR._
EOF

# Use GitHub API to find an existing comment by the bot that includes the marker "🤖 PR Summary by Pollinations.AI"
API_URL="https://api.github.com/repos/${REPO}"
COMMENTS_URL="${API_URL}/issues/${PR_NUMBER}/comments"

EXISTING_COMMENT_ID=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${COMMENTS_URL}" \
  | jq -r '.[] | select(.user.login == "github-actions[bot]") | select(.body | test("🤖 PR Summary by Pollinations.AI")) | .id' \
  | head -n 1 || true)

if [ -n "$EXISTING_COMMENT_ID" ]; then
  echo "Updating existing comment id $EXISTING_COMMENT_ID"
  curl -sS -X PATCH -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${API_URL}/issues/comments/${EXISTING_COMMENT_ID}" \
    -d "$(jq -nc --arg body "$COMMENT_BODY" '{body:$body}')" > /dev/null
else
  echo "Creating a new PR comment"
  curl -sS -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${COMMENTS_URL}" \
    -d "$(jq -nc --arg body "$COMMENT_BODY" '{body:$body}')" > /dev/null
fi

# Apply labels
LABELS_API="${API_URL}/issues/${PR_NUMBER}/labels"
# We'll add or update labels in one call. Prepare JSON array
LABELS_JSON=$(jq -n --arg l1 "$SIZE_LABEL" --arg l2 "$RISK_LABEL" --arg l3 "breaking-change" \
  '[ $l1, $l2, ($l3) ] | map(select(. != null))')

# If not breaking, remove breaking-change label from labels_json
if [ "$FINAL_BREAKING" = false ] || [ "$FINAL_BREAKING" = "false" ]; then
  LABELS_JSON=$(jq -n --arg l1 "$SIZE_LABEL" --arg l2 "$RISK_LABEL" '[ $l1, $l2 ]')
fi

# POST labels (this will add them; GitHub deduplicates)
curl -sS -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
  "${LABELS_API}" \
  -d "$LABELS_JSON" > /dev/null

echo "Done."
