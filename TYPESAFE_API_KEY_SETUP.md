# TYPESAFE_API_KEY Setup Guide

## Quick Start

To enable PR classification with Jev Choice API:

1. **Get your API key** from [TypeSafe](https://www.jevtypesafeai.com/)
2. **Add it to GitHub repository secrets**
3. Open a PR → Expect `jev:size-*` and `jev:risk-*` labels within 10 seconds

## Add Secret via GitHub CLI

```bash
gh secret set TYPESAFE_API_KEY --body "paste-your-key-here"
```

## Add Secret via GitHub UI

1. Go to **Settings → Secrets and variables → Actions**
2. Click **New repository secret**
3. Name: `TYPESAFE_API_KEY` (exact case)
4. Value: Your TypeSafe API key
5. Click **Add secret**

## Verify It Works

1. Create or open any pull request
2. Check **Actions** tab for the "Label PR with Jev Choice" workflow
3. Wait for it to complete
4. PR should have labels like:
   - `jev:size-s` (deterministic, always applied)
   - `jev:risk-low` (from Jev, if key is set)
   - `jev:complexity-low` (from Jev, if key is set)

## Security

- ✅ API key stored **only** in repository secrets
- ✅ Never committed to the repository
- ✅ Accessible **only** to GitHub Actions workflows
- ✅ Read via `${{ secrets.TYPESAFE_API_KEY }}`

## Labels Reference

| Label | Meaning |
|-------|---------|
| `jev:size-xs` | < 50 lines changed |
| `jev:size-s` | 50–199 lines |
| `jev:size-m` | 200–499 lines |
| `jev:size-l` | ≥ 500 lines |
| `jev:risk-low` | Low risk change |
| `jev:risk-medium` | Medium risk |
| `jev:risk-high` | High risk (core systems, auth, etc.) |

## Workflow File

- Location: `.github/workflows/label-pr-jev.yml`
- Docs: `docs/workflows/pr-labeler-jev.md`

## No API Key?

The workflow still applies `jev:size-*` labels even without the secret. It's optional—add the key when you're ready to use Jev classification.
