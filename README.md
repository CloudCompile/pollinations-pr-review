# pollinations-pr-summary

**Pollinations PR Summary** — GitHub Action that summarizes pull request diffs using Pollinations.AI and automatically applies labels (`size:*`, `risk:*`, `breaking-change`).

- Uses Pollinations text API (`https://text.pollinations.ai/openai`) with referrer: `prisimai.github.io`.
- Hybrid risk detection: AI + heuristic rules.
- Caches summaries per-diff-hash to avoid redundant API calls.
- Retries the Pollinations API respecting free-tier spacing.
- Comments are updated (not duplicated) and marked with `🤖 PR Summary by Pollinations.AI`.

## Features

- Professional summary format (detailed & developer friendly).
- Detects breaking changes.
- Assigns labels:
  - `size: XS/Small/Medium/Large/XL` (based on lines changed)
  - `risk: low/medium/high`
  - `breaking-change` (if present)
- Designed to be lightweight and run on PR creation and updates.

## Installation

1. Create a new repository (or add to your existing repo) and copy files into the paths shown:
   - `.github/workflows/summarize-pr.yml`
   - `.github/scripts/summarize_pr.sh`
   - `action.yml`
   - `README.md`
   - `LICENSE`

2. Commit & push to GitHub.

3. (Optional) If you want higher Pollinations limits or remove watermark, sign up at https://auth.pollinations.ai and modify the script to include an Authorization header:
```bash
-H "Authorization: Bearer ${{ secrets.POLLINATIONS_API_KEY }}"
```
