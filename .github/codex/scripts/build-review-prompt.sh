#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

BASE_PROMPT_FILE="${1:-}"
OUTPUT_FILE="${2:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"

require_env GITHUB_REPOSITORY PR_NUMBER PR_URL BASE_REF HEAD_REF HEAD_SHA TRIGGER_MODE
require_env BASE_SHA

if [ -z "$BASE_PROMPT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "ERROR: usage: build-review-prompt.sh <base-prompt-file> <output-file>" >&2
    exit 1
fi

focus_text="$(printf '%s' "${REVIEW_FOCUS:-}" | sanitize_prompt_text)"
pr_title="$(printf '%s' "${PR_TITLE:-}" | sanitize_prompt_text)"
pr_body="$(printf '%s' "${PR_BODY:-}" | sanitize_prompt_text)"
changed_files=""
diff_context=""
diff_notice=""

max_patch_files="${REVIEW_PROMPT_MAX_PATCH_FILES:-12}"
max_patch_chars_per_file="${REVIEW_PROMPT_MAX_PATCH_CHARS_PER_FILE:-1200}"
max_patch_chars_total="${REVIEW_PROMPT_MAX_PATCH_CHARS_TOTAL:-12000}"
github_token="${GITHUB_TOKEN:-}"

if git rev-parse --verify "$BASE_SHA" >/dev/null 2>&1 && git rev-parse --verify "$HEAD_SHA" >/dev/null 2>&1; then
    changed_files="$(git --no-pager diff --name-status "$BASE_SHA" "$HEAD_SHA" | sanitize_prompt_text)"
    diff_bundle="$RUNNER_TEMP/codex-review-diff-bundle.json"
    if [ -n "$github_token" ]; then
      export GITHUB_TOKEN="$github_token"
      export MAX_PATCH_FILES="$max_patch_files"
      export MAX_PATCH_CHARS_PER_FILE="$max_patch_chars_per_file"
      export MAX_PATCH_CHARS_TOTAL="$max_patch_chars_total"
      GITHUB_TOKEN="$github_token" \
      MAX_PATCH_FILES="$max_patch_files" \
      MAX_PATCH_CHARS_PER_FILE="$max_patch_chars_per_file" \
      MAX_PATCH_CHARS_TOTAL="$max_patch_chars_total" \
      python3 - <<'PY' > "$diff_bundle"
import json
import os
import subprocess

base_sha = os.environ['BASE_SHA']
head_sha = os.environ['HEAD_SHA']
max_files = int(os.environ['MAX_PATCH_FILES'])
per_file_limit = int(os.environ['MAX_PATCH_CHARS_PER_FILE'])
total_limit = int(os.environ['MAX_PATCH_CHARS_TOTAL'])

endpoint = f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/pulls/{os.environ['PR_NUMBER']}/files?per_page=100"
github_token = os.environ.get('GITHUB_TOKEN')
if not github_token:
    raise RuntimeError('GITHUB_TOKEN missing for GitHub API diff fetch path')
headers = {
    'Authorization': f"Bearer {github_token}",
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
}
files = []
while endpoint:
    req = subprocess.check_output([
        'python3', '-c',
        'import json,sys,urllib.request; '
        'url=sys.argv[1]; auth=sys.argv[2]; accept=sys.argv[3]; version=sys.argv[4]; '
        'req=urllib.request.Request(url, headers={"Authorization":auth,"Accept":accept,"X-GitHub-Api-Version":version}); '
        'resp=urllib.request.urlopen(req); '
        'print(json.dumps({"body": json.loads(resp.read().decode()), "link": resp.headers.get("Link", "")}))',
        endpoint,
        headers['Authorization'],
        headers['Accept'],
        headers['X-GitHub-Api-Version'],
    ], text=True)
    payload = json.loads(req)
    files.extend(payload['body'])
    link = payload.get('link') or ''
    next_url = ''
    for part in link.split(','):
        part = part.strip()
        if 'rel="next"' in part and part.startswith('<'):
            next_url = part.split('>')[0][1:]
            break
    endpoint = next_url

blocks = []
patch_budget_left = total_limit
patch_files_available = 0
patch_files_included = 0
patch_files_truncated = 0
changed_files_total = len(files)

for file_info in files[:max_files]:
    filename = str(file_info.get('filename') or '').strip()
    patch = str(file_info.get('patch') or '')
    status = str(file_info.get('status') or '')
    if not filename:
        continue
    if not patch:
        continue

    patch_files_available += 1
    if patch_budget_left <= 0:
        break

    limit = min(per_file_limit, patch_budget_left)
    truncated = False
    if len(patch) > limit:
        patch = patch[: max(0, limit - len('\n...[truncated]'))].rstrip() + '\n...[truncated]'
        truncated = True
        patch_files_truncated += 1

    patch_budget_left -= len(patch)
    patch_files_included += 1
    blocks.append({
        'filename': filename,
        'status': status,
        'patch': patch,
    })

payload = {
    'files': blocks,
    'meta': {
        'changed_files_total': changed_files_total,
        'changed_files_shown': min(changed_files_total, max_files),
        'changed_files_omitted': max(0, changed_files_total - max_files),
        'patch_files_available': patch_files_available,
        'patch_files_included': patch_files_included,
        'patch_files_truncated': patch_files_truncated,
        'patch_chars_limit_total': total_limit,
        'patch_chars_included': total_limit - patch_budget_left,
        'patch_was_truncated': patch_files_truncated > 0 or changed_files_total > max_files,
    },
}
print(json.dumps(payload))
PY
    else
      git --no-pager diff --unified=3 "$BASE_SHA" "$HEAD_SHA" \
        | python3 - <<'PY' > "$diff_bundle"
import json
import os
import re
import sys

max_files = int(os.environ['MAX_PATCH_FILES'])
per_file_limit = int(os.environ['MAX_PATCH_CHARS_PER_FILE'])
total_limit = int(os.environ['MAX_PATCH_CHARS_TOTAL'])

text = sys.stdin.read()
file_chunks = []
current = []
current_name = None
current_status = 'modified'

for line in text.splitlines():
    if line.startswith('diff --git '):
        if current_name and current:
            file_chunks.append((current_name, current_status, '\n'.join(current)))
        current = [line]
        current_name = None
        current_status = 'modified'
        continue
    if current is None:
        continue
    current.append(line)
    if line.startswith('+++ b/'):
        current_name = line[6:]
    elif line.startswith('new file mode '):
        current_status = 'added'
    elif line.startswith('deleted file mode '):
        current_status = 'removed'
    elif line.startswith('rename to '):
        current_name = line[len('rename to '):]
        current_status = 'renamed'

if current_name and current:
    file_chunks.append((current_name, current_status, '\n'.join(current)))

blocks = []
patch_budget_left = total_limit
patch_files_available = 0
patch_files_included = 0
patch_files_truncated = 0
changed_files_total = len(file_chunks)

for filename, status, patch in file_chunks[:max_files]:
    if not filename or not patch:
        continue
    patch_files_available += 1
    if patch_budget_left <= 0:
        break
    limit = min(per_file_limit, patch_budget_left)
    if len(patch) > limit:
        patch = patch[: max(0, limit - len('\n...[truncated]'))].rstrip() + '\n...[truncated]'
        patch_files_truncated += 1
    patch_budget_left -= len(patch)
    patch_files_included += 1
    blocks.append({'filename': filename, 'status': status, 'patch': patch})

payload = {
    'files': blocks,
    'meta': {
        'changed_files_total': changed_files_total,
        'changed_files_shown': min(changed_files_total, max_files),
        'changed_files_omitted': max(0, changed_files_total - max_files),
        'patch_files_available': patch_files_available,
        'patch_files_included': patch_files_included,
        'patch_files_truncated': patch_files_truncated,
        'patch_chars_limit_total': total_limit,
        'patch_chars_included': total_limit - patch_budget_left,
        'patch_was_truncated': patch_files_truncated > 0 or changed_files_total > max_files,
    },
}
print(json.dumps(payload))
PY
    fi
    diff_context="$(DIFF_BUNDLE="$diff_bundle" python3 - <<'PY'
import json
import os
from pathlib import Path
bundle = json.loads(Path(os.environ['DIFF_BUNDLE']).read_text())
blocks = []
for item in bundle.get('files', []):
    blocks.append("\n".join([
        f"### File: {item['filename']} ({item.get('status') or 'modified'})",
        "```diff",
        item['patch'],
        "```",
    ]))
print("\n\n".join(blocks))
PY
)"
    diff_notice="$(DIFF_BUNDLE="$diff_bundle" python3 - <<'PY'
import json
import os
from pathlib import Path
bundle = json.loads(Path(os.environ['DIFF_BUNDLE']).read_text())
meta = bundle.get('meta', {})
parts = [
    f"patch_files_included={meta.get('patch_files_included', 0)}",
    f"patch_files_available={meta.get('patch_files_available', 0)}",
    f"changed_files_total={meta.get('changed_files_total', 0)}",
]
if meta.get('patch_was_truncated'):
    parts.append('patch_context_truncated=true')
print(', '.join(parts))
PY
)"
fi

cat "$BASE_PROMPT_FILE" >"$OUTPUT_FILE"
cat >>"$OUTPUT_FILE" <<EOF2

## Runtime context

- Repository: \`$GITHUB_REPOSITORY\`
- Pull request: #$PR_NUMBER
- URL: $PR_URL
- Base ref: \`$BASE_REF\`
- Base SHA: \`$BASE_SHA\`
- Head ref: \`$HEAD_REF\`
- Head SHA: \`$HEAD_SHA\`
- Trigger mode: \`$TRIGGER_MODE\`

### Pull request title

${pr_title:-<empty>}

### Pull request body

${pr_body:-<empty>}
EOF2

if [ -n "$focus_text" ]; then
    cat >>"$OUTPUT_FILE" <<EOF2

### Requested review focus

$focus_text
EOF2
fi

if [ -n "$changed_files" ]; then
    cat >>"$OUTPUT_FILE" <<EOF2

### Changed files

$changed_files
EOF2
fi

if [ -n "$diff_notice" ]; then
    cat >>"$OUTPUT_FILE" <<EOF2

### Diff context budget

$diff_notice
EOF2
fi

if [ -n "$diff_context" ]; then
    cat >>"$OUTPUT_FILE" <<EOF2

### Diff context

$diff_context
EOF2
fi
