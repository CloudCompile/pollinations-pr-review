#!/usr/bin/env bash
# .github/scripts/summarize_pr.sh
# Run: executed by the workflow .github/workflows/summarize-pr.yml
set -euo pipefail

# -------------------------
# Configuration / defaults
# -------------------------
CACHE_DIR=".github/pr-summary-cache"
mkdir -p "$CACHE_DIR"

POLLINATIONS_REFERRER="${POLLINATIONS_REFERRER:-prisimai.github.io}"
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-32768}"    # how many bytes of the diff to send
MAX_ATTEMPTS=4
WAIT_SECONDS=20                              # wait between retries (respect free-tier)

# Colors for labels (user confirmed)
COLOR_SIZE="ededed"
COLOR_RISK_LOW="00b300"
COLOR_RISK_MEDIUM="ffaa00"
COLOR_RISK_HIGH="ff0000"
COLOR_BREAKING="d73a4a"

# -------------------------
# Helpers
# -------------------------
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ensure a label exists (create if missing)
ensure_label() {
  local repo_api="$1" name="$2" color="$3" description="$4"
  # encode name for URL (labels containing spaces)
  # GitHub API for single label GET uses url-encoded name
  local encoded_name
  encoded_name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$name")

  # Check if exists
  if curl -s -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${repo_api}/labels/${encoded_name}" | jq -e . >/dev/null 2>&1; then
    # exists (200)
    return 0
  fi

  # Create it
  local payload
  payload=$(jq -nc --arg name "$name" --arg color "$color" --arg desc "$description" '{name:$name, color:$color, description:$desc}')
  curl -s -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${repo_api}/labels" \
    -d "$payload" >/dev/null || true
}

# -------------------------
# Environment / event data
# -------------------------
EVENT_FILE="${GITHUB_EVENT_PATH:-.github/event.json}"

if [ ! -f "$EVENT_FILE" ]; then
  echo "GITHUB_EVENT_PATH not set or event file not found. Creating a minimal fallback from environment..."
  echo "{}" > "$EVENT_FILE"
fi

REPO="${GITHUB_REPOSITORY:?REPO not set}"   # owner/repo
API_BASE="https://api.github.com/repos/${REPO}"

PR_NUMBER=$(jq -r '.pull_request.number // empty' "$EVENT_FILE")
BASE_REF=$(jq -r '.pull_request.base.ref // empty' "$EVENT_FILE")
HEAD_SHA=$(jq -r '.pull_request.head.sha // empty' "$EVENT_FILE")

if [ -z "$PR_NUMBER" ]; then
  die "This workflow must run on a pull_request event. PR number not found in event payload."
fi

echo "Processing PR #${PR_NUMBER} in ${REPO} (base: ${BASE_REF})"

# Ensure base ref is present
git fetch origin "${BASE_REF}" || true

# Create diff file (we'll use HEAD against base)
git diff "origin/${BASE_REF}...HEAD" > /tmp/pr_diff.txt || true

# Stats
ADDED_LINES=$(git diff --numstat "origin/${BASE_REF}...HEAD" | awk '{added+=$1} END{print added+0}')
REMOVED_LINES=$(git diff --numstat "origin/${BASE_REF}...HEAD" | awk '{removed+=$2} END{print removed+0}')
TOTAL_CHANGED_FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" | wc -l | tr -d ' ')
TOTAL_LINES=$((ADDED_LINES + REMOVED_LINES))
echo "Added lines: ${ADDED_LINES}, Removed lines: ${REMOVED_LINES}, Files changed: ${TOTAL_CHANGED_FILES}, Total lines: ${TOTAL_LINES}"

# Diff hash for caching
DIFF_HASH=$(sha256sum /tmp/pr_diff.txt | awk '{print $1}')
CACHE_JSON="${CACHE_DIR}/${DIFF_HASH}.json"
CACHE_SUMMARY="${CACHE_DIR}/${DIFF_HASH}.summary.txt"

IS_CACHED=false
if [ -f "$CACHE_JSON" ] && [ -f "$CACHE_SUMMARY" ]; then
  echo "Cache hit for diff hash ${DIFF_HASH}"
  META_JSON=$(cat "$CACHE_JSON")
  SUMMARY_TEXT=$(cat "$CACHE_SUMMARY")
  IS_CACHED=true
else
  echo "Cache miss for diff hash ${DIFF_HASH}"
fi

# -------------------------
# Get summary from Pollinations (if not cached)
# -------------------------
if [ "$IS_CACHED" = false ]; then

  # Trim diff to MAX_DIFF_BYTES
  # Use head -c to limit raw bytes, then escape safely for jq --arg
  DIFF_TRIMMED=$(head -c "${MAX_DIFF_BYTES}" /tmp/pr_diff.txt || true)
  # If empty, set a friendly message
  if [ -z "$DIFF_TRIMMED" ]; then
    DIFF_TRIMMED="(empty diff - maybe whitespace or binary file changes)"
  fi

  # Build request body via jq, passing diff as argument to avoid shell quoting pitfalls
  REQUEST_BODY=$(jq -n --arg model "openai" --arg diff "$DIFF_TRIMMED" '{
    model: $model,
    reasoning_effort: "medium",
    temperature: 0.3,
    messages: [
      {role: "system", content: "You are a senior developer summarizing pull requests into JSON with fields: summary (string), breaking_change (boolean), risk (one of: low, medium, high), notes (optional string). Be concise and professional."},
      {role: "user", content: "Please output ONLY a single JSON object with keys: summary, breaking_change (true/false), risk (low|medium|high), notes (optional). Use the diff below as input. Do not include commentary."},
      {role: "user", content: $diff}
    ]
  }')

  # Retry loop
  ATTEMPT=1
  POLL_RESP=""
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "Pollinations API attempt ${ATTEMPT}/${MAX_ATTEMPTS}..."
    POLL_RESP=$(curl -sS -X POST "https://text.pollinations.ai/openai?referrer=${POLLINATIONS_REFERRER}" \
      -H "Content-Type: application/json" \
      -d "$REQUEST_BODY" || true)

    # Try to extract AI's textual answer (openai-like envelope or raw text)
    PARSED=$(echo "$POLL_RESP" | jq -r 'if (.choices != null) then (.choices[0].message.content // .choices[0].text // "") else . end' 2>/dev/null || echo "$POLL_RESP")

    # Try to extract first JSON object from PARSED: try to parse whole string as JSON
    JSON_CANDIDATE=$(echo "$PARSED" | jq -R 'fromjson? // empty' 2>/dev/null || echo "")

    if [ -n "$JSON_CANDIDATE" ]; then
      echo "Valid JSON received from Pollinations (direct parse)."
      echo "$JSON_CANDIDATE" > "$CACHE_JSON"
      SUMMARY_TEXT=$(echo "$JSON_CANDIDATE" | jq -r '.summary // "No summary."')
      echo "$SUMMARY_TEXT" > "$CACHE_SUMMARY"
      break
    fi

    # Fallback: extract substring between first { and last } and try parse
    EXTRACTED=$(echo "$PARSED" | sed -n '1h;1!H;${;g;s/.*\({.*}\).*/\1/;p;}' || true)
    if [ -n "$EXTRACTED" ]; then
      if echo "$EXTRACTED" | jq -R 'fromjson? // empty' 2>/dev/null | grep -q .; then
        echo "$EXTRACTED" | jq -R 'fromjson' > "$CACHE_JSON"
        SUMMARY_TEXT=$(cat "$CACHE_JSON" | jq -r '.summary // "No summary."')
        echo "$SUMMARY_TEXT" > "$CACHE_SUMMARY"
        echo "Valid JSON extracted and parsed."
        break
      fi
    fi

    echo "Pollinations response not parseable as JSON on attempt ${ATTEMPT}."
    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
      echo "Waiting ${WAIT_SECONDS}s before retrying (respect free-tier)..."
      sleep "${WAIT_SECONDS}"
    fi
    ATTEMPT=$((ATTEMPT+1))
  done

  # If still no structured JSON, build a heuristic fallback
  if [ ! -f "$CACHE_JSON" ]; then
    echo "Failed to get structured JSON after ${MAX_ATTEMPTS} attempts. Building heuristic fallback."
    HEUR_SUMMARY="PR changes: ${TOTAL_LINES} lines changed across ${TOTAL_CHANGED_FILES} files. Added ${ADDED_LINES}, removed ${REMOVED_LINES}."
    HEUR_BREAK=false
    HEUR_RISK="low"
    if grep -E "package.json|Pipfile|requirements.txt|setup.py|poetry.lock|go.mod|Cargo.toml" /tmp/pr_diff.txt >/dev/null; then
      HEUR_RISK="medium"
    fi
    if [ "${TOTAL_LINES}" -gt 500 ]; then
      HEUR_RISK="high"
    fi
    META_FALLBACK=$(jq -n --arg s "$HEUR_SUMMARY" --arg risk "$HEUR_RISK" --arg notes "Fallback heuristic summary used after API failures." --argjson breaking false '{summary:$s, breaking_change:$breaking, risk:$risk, notes:$notes}')
    echo "$META_FALLBACK" > "$CACHE_JSON"
    echo "$HEUR_SUMMARY" > "$CACHE_SUMMARY"
  fi

  META_JSON=$(cat "$CACHE_JSON")
  SUMMARY_TEXT=$(cat "$CACHE_SUMMARY")
fi

# -------------------------
# Hybrid risk + breaking logic
# -------------------------
# Values from AI / meta
RISK_AI=$(echo "$META_JSON" | jq -r '.risk // "medium"')
BREAK_AI=$(echo "$META_JSON" | jq -r '.breaking_change // false')

# Heuristic scoring
SCORE=0
# dependency or build file touched
if grep -E "package.json|Pipfile|requirements.txt|setup.py|poetry.lock|go.mod|Cargo.toml" /tmp/pr_diff.txt >/dev/null; then
  SCORE=$((SCORE + 2))
fi
# big changes
if [ "$TOTAL_LINES" -gt 500 ]; then SCORE=$((SCORE + 2)); fi
if [ "$TOTAL_LINES" -gt 200 ] && [ "$TOTAL_LINES" -le 500 ]; then SCORE=$((SCORE + 1)); fi
# many files
if [ "$TOTAL_CHANGED_FILES" -gt 10 ]; then SCORE=$((SCORE + 1)); fi
# heavy deletions
if [ "$REMOVED_LINES" -gt "$ADDED_LINES" ] && [ "$REMOVED_LINES" -gt 100 ]; then SCORE=$((SCORE + 1)); fi

# AI numeric mapping low=0, medium=1, high=2
AI_NUM=1
if [ "$RISK_AI" = "low" ]; then AI_NUM=0; fi
if [ "$RISK_AI" = "high" ]; then AI_NUM=2; fi

COMBINED_NUM=$(( (SCORE + AI_NUM) / 2 ))
FINAL_RISK="medium"
if [ "$COMBINED_NUM" -le 0 ]; then FINAL_RISK="low"; fi
if [ "$COMBINED_NUM" -ge 2 ]; then FINAL_RISK="high"; fi
if [ "$COMBINED_NUM" -eq 1 ]; then FINAL_RISK="medium"; fi

# Breaking: OR of AI and heuristic
HEUR_BREAK=false
if grep -Ei "BREAKING CHANGE|ALTER TABLE|add_column|remove_column|schema version|migrate|breaking" /tmp/pr_diff.txt >/dev/null; then
  HEUR_BREAK=true
fi
if [ "$BREAK_AI" = "true" ] || [ "$BREAK_AI" = "True" ] || [ "$HEUR_BREAK" = true ]; then
  FINAL_BREAKING=true
else
  FINAL_BREAKING=false
fi

# -------------------------
# Size label
# -------------------------
SIZE_LABEL="size: XS"
if [ "$TOTAL_LINES" -lt 50 ]; then SIZE_LABEL="size: XS"; fi
if [ "$TOTAL_LINES" -ge 50 ] && [ "$TOTAL_LINES" -lt 200 ]; then SIZE_LABEL="size: Small"; fi
if [ "$TOTAL_LINES" -ge 200 ] && [ "$TOTAL_LINES" -lt 500 ]; then SIZE_LABEL="size: Medium"; fi
if [ "$TOTAL_LINES" -ge 500 ] && [ "$TOTAL_LINES" -lt 2000 ]; then SIZE_LABEL="size: Large"; fi
if [ "$TOTAL_LINES" -ge 2000 ]; then SIZE_LABEL="size: XL"; fi

RISK_LABEL="risk: ${FINAL_RISK}"

echo "Final computed labels => ${SIZE_LABEL}, ${RISK_LABEL}, breaking-change=${FINAL_BREAKING}"

# -------------------------
# Ensure labels exist (auto-create)
# -------------------------
# Prepare label creation (colors and descriptions)
ensure_label "${API_BASE}" "size: XS" "$COLOR_SIZE" "Size: extra small (under 50 lines)"
ensure_label "${API_BASE}" "size: Small" "$COLOR_SIZE" "Size: small (50-199 lines)"
ensure_label "${API_BASE}" "size: Medium" "$COLOR_SIZE" "Size: medium (200-499 lines)"
ensure_label "${API_BASE}" "size: Large" "$COLOR_SIZE" "Size: large (500-1999 lines)"
ensure_label "${API_BASE}" "size: XL" "$COLOR_SIZE" "Size: extra large (2000+ lines)"

ensure_label "${API_BASE}" "risk: low" "$COLOR_RISK_LOW" "Risk: low"
ensure_label "${API_BASE}" "risk: medium" "$COLOR_RISK_MEDIUM" "Risk: medium"
ensure_label "${API_BASE}" "risk: high" "$COLOR_RISK_HIGH" "Risk: high"

ensure_label "${API_BASE}" "breaking-change" "$COLOR_BREAKING" "Potential breaking change"

# -------------------------
# Build comment body (including Diff Stats)
# -------------------------
DIFF_STATS_BLOCK=$(cat <<EOF
### Diff Stats
- Files changed: ${TOTAL_CHANGED_FILES}
- Lines added: ${ADDED_LINES}
- Lines removed: ${REMOVED_LINES}
- Total lines changed: ${TOTAL_LINES}
EOF
)

read -r -d '' COMMENT_BODY <<EOF || true
🤖 PR Summary by Pollinations.AI  
*(referrer: ${POLLINATIONS_REFERRER})*

### Summary
${SUMMARY_TEXT}

**Risk Level:** ${FINAL_RISK}
**Breaking Change:** ${FINAL_BREAKING}

${DIFF_STATS_BLOCK}

---  
_This comment is generated automatically. It will be updated (not duplicated) on new commits to this PR._
EOF

# -------------------------
# Post or update PR comment
# -------------------------
COMMENTS_URL="${API_BASE}/issues/${PR_NUMBER}/comments"

EXISTING_COMMENT_ID=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${COMMENTS_URL}" \
  | jq -r '.[] | select(.user.login == "github-actions[bot]" or .user.login == "github-actions") | select(.body | test("🤖 PR Summary by Pollinations.AI")) | .id' \
  | head -n 1 || true)

if [ -n "$EXISTING_COMMENT_ID" ]; then
  echo "Updating existing comment id ${EXISTING_COMMENT_ID}"
  curl -sS -X PATCH -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${API_BASE}/issues/comments/${EXISTING_COMMENT_ID}" \
    -d "$(jq -nc --arg body "$COMMENT_BODY" '{body:$body}')" >/dev/null
else
  echo "Creating a new PR comment"
  curl -sS -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${COMMENTS_URL}" \
    -d "$(jq -nc --arg body "$COMMENT_BODY" '{body:$body}')" >/dev/null
fi

# -------------------------
# Apply labels to PR
# -------------------------
LABELS_API="${API_BASE}/issues/${PR_NUMBER}/labels"
# Build labels array
if [ "$FINAL_BREAKING" = true ] || [ "$FINAL_BREAKING" = "true" ]; then
  LABELS_JSON=$(jq -n --arg s "$SIZE_LABEL" --arg r "$RISK_LABEL" --arg b "breaking-change" '[ $s, $r, $b ]')
else
  LABELS_JSON=$(jq -n --arg s "$SIZE_LABEL" --arg r "$RISK_LABEL" '[ $s, $r ]')
fi

curl -sS -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
  "${LABELS_API}" \
  -d "$LABELS_JSON" >/dev/null

echo "Labels applied."

echo "Done."
