#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

EVENT_PATH="${GITHUB_EVENT_PATH:-${1:-}}"
COMMAND_MODE="${COMMAND_MODE:-review}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
TRIGGER_HANDLE="${BOT_TRIGGER_HANDLE:-$(resolve_trigger_handle)}"

if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
    echo "ERROR: GITHUB_EVENT_PATH is not set or does not exist" >&2
    exit 1
fi

should_run="false"
trigger_mode="auto"
command_name=""
command_text=""
source_key="auto"
source_comment_id=""

if { [ "$EVENT_NAME" = "pull_request" ] || [ "$EVENT_NAME" = "pull_request_target" ]; } && [ "$COMMAND_MODE" = "review" ]; then
    should_run="true"
else
    issue_has_pr="$(jq -r 'if .issue.pull_request then "true" else "false" end' "$EVENT_PATH")"
    if [ "$EVENT_NAME" = "issue_comment" ] && [ "$issue_has_pr" = "true" ]; then
        trigger_mode="comment"
        source_comment_id="$(jq -r '.comment.id // ""' "$EVENT_PATH")"
        comment_author_type="$(jq -r '.comment.user.type // ""' "$EVENT_PATH")"
        if [ -n "$source_comment_id" ]; then
            source_key="comment-$source_comment_id"
        fi

        if [ "$comment_author_type" = "Bot" ]; then
            set_output "should_run" "$should_run"
            set_output "trigger_mode" "$trigger_mode"
            set_output "command_name" "$command_name"
            set_output "command_text" "$command_text"
            set_output "source_key" "$source_key"
            set_output "source_comment_id" "$source_comment_id"
            set_output "trigger_handle" "$TRIGGER_HANDLE"
            exit 0
        fi

        parsed_json="$(
            COMMENT_BODY="$(jq -r '.comment.body // ""' "$EVENT_PATH")" TRIGGER_HANDLE="$TRIGGER_HANDLE" python3 - <<'PY'
import json
import os
import re

body = os.environ.get("COMMENT_BODY", "")
handle = re.escape(os.environ.get("TRIGGER_HANDLE", "codex"))


def strip_html_comments(text: str) -> str:
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def strip_fenced_code_blocks(text: str) -> str:
    lines = text.split("\n")
    visible = []
    in_fence = False
    fence_char = ""
    fence_length = 0

    for line in lines:
        match = re.match(r"^\s*([`~]{3,})", line)
        if match:
            marker = match.group(1)
            if not in_fence:
                in_fence = True
                fence_char = marker[0]
                fence_length = len(marker)
                continue
            if marker[0] == fence_char and len(marker) >= fence_length:
                in_fence = False
                continue

        if not in_fence:
            visible.append(line)

    return "\n".join(visible)


def strip_inline_code(text: str) -> str:
    return re.sub(r"`[^`\n]*`", "", text)


def find_trigger_match(text: str):
    pattern = re.compile(rf"@{handle}(?=$|[\s:;,])", flags=re.I)
    for match in pattern.finditer(text):
        if match.start() == 0 or not re.match(r"[A-Za-z0-9_]", text[match.start() - 1]):
            return match
    return None


sanitized = body.replace("\r\n", "\n").replace("\r", "\n")
sanitized = strip_html_comments(sanitized)
sanitized = strip_fenced_code_blocks(sanitized)
sanitized = strip_inline_code(sanitized)

match = find_trigger_match(sanitized)
if not match:
    print(json.dumps({"command_name": "", "command_text": ""}))
else:
    rest = re.sub(r"^[\s,:;]+", "", sanitized[match.end():]).strip()
    if not rest:
        print(json.dumps({"command_name": "", "command_text": ""}))
    else:
        review_match = re.match(r"^review(?:\s+(.*))?$", rest, flags=re.I | re.S)
        if review_match:
            print(json.dumps({
                "command_name": "review",
                "command_text": (review_match.group(1) or "").strip(),
            }))
        else:
            print(json.dumps({
                "command_name": "task",
                "command_text": rest,
            }))
PY
        )"

        command_name="$(printf '%s' "$parsed_json" | jq -r '.command_name')"
        command_text="$(printf '%s' "$parsed_json" | jq -r '.command_text')"

        case "$COMMAND_MODE:$command_name" in
            review:review|task:task|route:review|route:task)
                should_run="true"
                ;;
        esac
    fi
fi

set_output "should_run" "$should_run"
set_output "trigger_mode" "$trigger_mode"
set_output "command_name" "$command_name"
set_output "command_text" "$command_text"
set_output "source_key" "$source_key"
set_output "source_comment_id" "$source_comment_id"
set_output "trigger_handle" "$TRIGGER_HANDLE"
