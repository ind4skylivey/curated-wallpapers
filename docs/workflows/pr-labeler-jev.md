# PR Labeler with Jev Choice API

Automated GitHub Actions workflow that classifies pull requests by **size** and **risk** using the TypeSafe Jev Choice API.

## Overview

The workflow runs on every PR (opened, synchronize, reopened) and:

1. **Extracts deterministic metrics** from the PR diff (files, lines added/deleted)
2. **Classifies size** based on total line count (no computation needed)
3. **Calls Jev Choice API** for risk and complexity assessment (soft-fail if API key missing)
4. **Applies labels** to the PR for easy filtering and triage

## Labels

| Label | Criteria |
|-------|----------|
| `jev:size-xs` | < 50 lines total |
| `jev:size-s` | 50–199 lines |
| `jev:size-m` | 200–499 lines |
| `jev:size-l` | ≥ 500 lines |
| `jev:risk-low` | Minimal scope, well-tested, docs-only |
| `jev:risk-medium` | Moderate scope, clear intent, non-critical |
| `jev:risk-high` | Large scope, core systems, auth changes |
| `jev:complexity-low` | Straightforward, single concern |
| `jev:complexity-medium` | Multiple concerns, moderate scope |
| `jev:complexity-high` | Complex logic, distributed changes |

## Setup

### 1. Add the TypeSafe API Key

The workflow reads `TYPESAFE_API_KEY` from GitHub repository secrets.

**Via GitHub UI:**
1. Go to **Settings → Secrets and variables → Actions**
2. Click **New repository secret**
3. Name: `TYPESAFE_API_KEY`
4. Paste your TypeSafe API key
5. Click **Add secret**

**Via GitHub CLI:**
```bash
gh secret set TYPESAFE_API_KEY --body "your-api-key-here"
```

**Important:** Never commit the key to the repository. The workflow reads it only from the `${{ secrets.TYPESAFE_API_KEY }}` context variable.

### 2. Workflow Behavior

- **If API key is configured**: PR gets `jev:risk-*` and `jev:complexity-*` labels based on Jev classification
- **If API key is missing**: Workflow skips Jev classification, applies only `jev:size-*` labels, and logs a warning
- **If API call fails**: Continues gracefully (`continue-on-error`), does not block the PR merge

## How It Works

### Step 1: Get PR Metrics
Uses `gh` CLI to fetch PR stats:
- Files changed
- Lines added/deleted
- Total lines changed

```bash
gh pr view <PR_NUMBER> --json files,additions,deletions,commits
```

Size is deterministic and computed locally:
```
< 50 lines    → jev:size-xs
50–199 lines  → jev:size-s
200–499 lines → jev:size-m
≥ 500 lines   → jev:size-l
```

### Step 2: Build PR Context
Extracts PR title, author, description, and file list to build a compact state string.

### Step 3: Call Jev API
Sends a POST request to `https://api.typesafe.ai/v1/systemone` with:
- **State**: PR context (title, author, files, description)
- **Questions**: Two `choice` questions for risk and complexity
- **Bearer token**: From repository secret

Example request:
```json
{
  "model": "jev-latest",
  "state": "PR Title: Add user authentication...",
  "questions": {
    "risk": {
      "type": "choice",
      "instructions": "Based on the PR description, files changed, and scope, classify the risk level...",
      "criteria": {
        "low": "Minimal scope, well-documented, tests included...",
        "medium": "Moderate scope, clear intent...",
        "high": "Large scope, touches core systems..."
      }
    },
    "complexity": {
      "type": "choice",
      "instructions": "Classify the apparent complexity...",
      "criteria": {
        "low": "Straightforward changes...",
        "medium": "Multiple concerns...",
        "high": "Complex logic..."
      }
    }
  }
}
```

### Step 4: Apply Labels
Adds labels to the PR:
- Always applies `jev:size-*` (deterministic)
- Applies `jev:risk-*` if Jev classification succeeded
- Applies `jev:complexity-*` if available
- Posts a summary comment with classifications

## Testing

### Smoke Test: Create a Tiny PR

```bash
# Create a feature branch
git checkout -b test/labeler-smoke-test

# Make a minimal change (e.g., update a comment)
echo "# Test PR for labeler" >> README_TEMP.md

# Commit and push
git add README_TEMP.md
git commit -m "test: smoke test for PR labeler"
git push origin test/labeler-smoke-test

# Open PR via GitHub UI or CLI
gh pr create --title "Test: PR Labeler Smoke Test" \
  --body "Minimal PR to verify labeler works. Expected label: jev:size-xs"
```

**Expected outcome:**
- Within 10 seconds: PR receives `jev:size-xs` label
- If TYPESAFE_API_KEY is set: PR also receives `jev:risk-low` and `jev:complexity-low`
- If TYPESAFE_API_KEY is missing: Only size label applied; comment mentions API key not configured

### Full Test: Trigger from Main Branch

To test without pushing, use GitHub's branch protection testing or draft PR workflow.

## Troubleshooting

### Labels not appearing
1. Check **Actions** tab for workflow run status
2. Look for error messages in the run logs
3. Verify `TYPESAFE_API_KEY` is set (if you want risk classification)

### Workflow shows "warning: Jev API error"
- Verify the API key is correct
- Check TypeSafe API status at https://www.jevtypesafeai.com/
- Ensure the request payload is valid JSON

### "TYPESAFE_API_KEY not configured"
This is **not** an error. The workflow continues and applies size labels. To enable Jev classification:
1. Add the secret to the repository (see Setup, step 1)
2. Push a new commit or reopen the PR to re-trigger the workflow

## Soft-Fail Behavior

The workflow is designed to **never block** PR merges:

- Step `classify-pr` has `continue-on-error: true`
- Missing API key triggers graceful exit (exit 0)
- API failures are logged but do not fail the job
- All label operations use `|| true` to suppress errors

This ensures the workflow is informational only.

## Example Output

When the workflow runs:

```
✓ Get PR diff metrics
  files_changed=3, additions=45, deletions=12 (total: 57)

✓ Build PR context for Jev
  State built: 300 chars

✓ Classify with Jev Choice API
  Jev classification: risk=low, complexity=low

✓ Apply labels
  Adding label: jev:size-s
  Adding label: jev:risk-low
  Adding label: jev:complexity-low

✓ Comment on PR (optional)
  Posted classification summary comment
```

## References

- [TypeSafe Jev API docs](https://www.jevtypesafeai.com/how-to-use)
- [GitHub Actions documentation](https://docs.github.com/en/actions)
- [GitHub CLI reference](https://cli.github.com/manual)
