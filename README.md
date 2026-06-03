# iHouse Review Bot Helper

Public reusable GitHub Actions helper for cross-owner review bot consumers.

This repository intentionally contains only the review reusable workflow and trusted helper assets needed by caller repositories:

- `.github/workflows/reusable-codex-pr-review.yml`
- `.github/codex/prompts/review.md`
- `.github/codex/schemas/review-output.schema.json`
- `.github/codex/scripts/*.sh`

Consumer repositories must call the reusable workflow with an immutable commit SHA and pass the same SHA as `helper_ref`.

```yaml
jobs:
  review:
    uses: Ryan02I5/ihouse-review-bot-helper/.github/workflows/reusable-codex-pr-review.yml@<40-char-sha>
    with:
      helper_repository: Ryan02I5/ihouse-review-bot-helper
      helper_ref: <same-40-char-sha>
    secrets:
      REVIEW_BOT_PROVIDER_API_KEY: ${{ secrets.REVIEW_BOT_PROVIDER_API_KEY }}
      CODEX_BOT_APP_ID: ${{ secrets.CODEX_BOT_APP_ID }}
      CODEX_BOT_PRIVATE_KEY: ${{ secrets.CODEX_BOT_PRIVATE_KEY }}
```

Secrets stay in the consumer repository. This public helper stores no provider API keys, GitHub App private keys, signing material, or consumer repository credentials.

Inline publish prefers a GitHub App installation token when the consumer has `CODEX_BOT_APP_ID` + `CODEX_BOT_PRIVATE_KEY` and that app is installed on the caller repository. If no installation token is available, advisory publish falls back to the caller workflow token, so consumer jobs should grant at least:

- `issues: write`
- `pull-requests: write`

Refs Ryan02I5/ihouse-review-bot-helper#1.
