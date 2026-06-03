#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

CODEX_HOME_DIR="${1:-}"
TRUSTED_AGENTS_FILE="${2:-}"

if [ -z "$CODEX_HOME_DIR" ]; then
    echo "ERROR: usage: build-review-codex-home.sh <codex-home-dir> [trusted-agents-file]" >&2
    exit 1
fi

mkdir -p "$CODEX_HOME_DIR"

instructions_file="$CODEX_HOME_DIR/review-model-instructions.md"
config_file="$CODEX_HOME_DIR/config.toml"

TRUSTED_AGENTS_FILE="$TRUSTED_AGENTS_FILE" INSTRUCTIONS_FILE="$instructions_file" python3 - <<'PY'
import os
from pathlib import Path

agents_path = os.environ.get("TRUSTED_AGENTS_FILE", "")
instructions_path = Path(os.environ["INSTRUCTIONS_FILE"])

review_guidelines = ""
if agents_path and Path(agents_path).is_file():
    lines = Path(agents_path).read_text(encoding="utf-8").splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "## Review guidelines":
            start = i + 1
            break
    if start is not None:
        collected = []
        for line in lines[start:]:
            if line.startswith("## "):
                break
            collected.append(line)
        review_guidelines = "\n".join(collected).strip()

content = [
    "You are running in a trusted GitHub review workflow.",
    "Use the repository-specific review policy below for this run.",
]

if review_guidelines:
    content.extend(["", review_guidelines])
else:
    content.extend([
        "",
        "No repository-specific review policy was found in the trusted base-branch `AGENTS.md`.",
        "Preserve Codex's default GitHub review bar for this run.",
        "Only raise high-confidence priority `0` or `1` issues.",
        "Do not widen the merge gate beyond the default GitHub P0/P1 behavior unless trusted repository guidance explicitly says so.",
    ])

instructions_path.write_text("\n".join(content) + "\n", encoding="utf-8")
PY

escaped_instructions_file="$(python3 - <<'PY' "$instructions_file"
import json
import sys

print(json.dumps(sys.argv[1]))
PY
)"

cat >"$config_file" <<EOF
model_instructions_file = ${escaped_instructions_file}
model_max_output_tokens = 512
EOF
