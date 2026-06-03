#!/bin/bash

set -euo pipefail

require_env() {
    local name
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            echo "ERROR: missing required environment variable: $name" >&2
            exit 1
        fi
    done
}

normalize_bool() {
    case "${1:-false}" in
        1|true|TRUE|yes|YES|on|ON)
            echo "true"
            ;;
        *)
            echo "false"
            ;;
    esac
}

first_env_value() {
    local name
    local value=""

    for name in "$@"; do
        value="${!name:-}"
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
    done

    return 0
}

csv_contains() {
    local needle="$1"
    local csv="${2:-}"
    local item
    local -a __csv_items=()

    if [ -z "$csv" ]; then
        return 1
    fi

    IFS=',' read -r -a __csv_items <<<"$csv"
    for item in "${__csv_items[@]}"; do
        item="$(printf '%s' "$item" | xargs)"
        if [ "$item" = "$needle" ] || [ "$item" = "*" ]; then
            return 0
        fi
    done

    return 1
}

normalize_login_for_allowlist() {
    local login="${1:-}"
    login="$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
    printf '%s' "${login%\[bot\]}"
}

csv_contains_login() {
    local needle="$1"
    local csv="${2:-}"
    local normalized_needle item normalized_item
    local -a __csv_items=()

    if [ -z "$csv" ]; then
        return 1
    fi

    normalized_needle="$(normalize_login_for_allowlist "$needle")"
    IFS=',' read -r -a __csv_items <<<"$csv"
    for item in "${__csv_items[@]}"; do
        item="$(printf '%s' "$item" | xargs)"
        if [ "$item" = "*" ]; then
            return 0
        fi

        normalized_item="$(normalize_login_for_allowlist "$item")"
        if [ "$normalized_item" = "$normalized_needle" ]; then
            return 0
        fi
    done

    return 1
}

actor_is_allowlisted() {
    local login="$1"
    local actor_type="${2:-}"
    local allowed_users="${3:-}"
    local allowed_bots="${4:-}"

    if [ -z "$login" ]; then
        return 1
    fi

    if csv_contains_login "$login" "$allowed_users"; then
        return 0
    fi

    if [ "$actor_type" = "Bot" ] && csv_contains_login "$login" "$allowed_bots"; then
        return 0
    fi

    return 1
}

resolve_trigger_handle() {
    local handle
    handle="$(first_env_value BOT_TRIGGER_HANDLE)"
    handle="${handle:-ryan-verification-engineer}"
    printf '%s' "$handle" | tr '[:upper:]' '[:lower:]'
}

resolve_model() {
    first_env_value CODEX_MODEL
}

resolve_review_model() {
    first_env_value CODEX_REVIEW_MODEL CODEX_MODEL
}

resolve_reasoning_effort() {
    first_env_value CODEX_REASONING_EFFORT
}

resolve_responses_api_endpoint() {
    first_env_value BOT_RESPONSES_API_ENDPOINT
}

resolve_allowed_users() {
    first_env_value BOT_ALLOWED_USERS
}

resolve_allowed_bots() {
    local bots

    bots="$(first_env_value BOT_ALLOWED_BOTS)"
    if [ -n "$bots" ]; then
        printf '%s' "$bots"
        return 0
    fi
}

sanitize_text() {
    local limit="${SANITIZE_LIMIT:-4000}"
    LIMIT="$limit" python3 -c '
import os
import re
import sys

text = sys.stdin.read()
text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
text = text.replace("\r", "")
lines = [line.rstrip() for line in text.splitlines()]
text = "\n".join(lines).strip()
text = re.sub(r"\n{3,}", "\n\n", text)

limit = int(os.environ.get("LIMIT", "4000"))
if len(text) > limit:
    text = text[:limit].rstrip() + "\n...[truncated]"

sys.stdout.write(text)
'
}

sanitize_prompt_text() {
    local limit="${PROMPT_SANITIZE_LIMIT:-8000}"
    LIMIT="$limit" python3 -c '
import os
import re
import sys

text = sys.stdin.read()
text = text.replace("\r\n", "\n").replace("\r", "\n")
text = re.sub(r"<!--.*?-->", "", text, flags=re.S)

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

text = "\n".join(visible)
text = re.sub(r"`[^`\n]*`", "", text)
lines = [line.rstrip() for line in text.splitlines()]
text = "\n".join(lines).strip()
text = re.sub(r"\n{3,}", "\n\n", text)

limit = int(os.environ.get("LIMIT", "8000"))
if len(text) > limit:
    text = text[:limit].rstrip() + "\n...[truncated]"

sys.stdout.write(text)
'
}

set_output() {
    local name="$1"
    local value="${2-}"
    local marker
    marker="__CODEX_OUTPUT_$(python3 - <<'PY'
import secrets

print(secrets.token_hex(16))
PY
)"
    printf '%s<<%s\n%s\n%s\n' "$name" "$marker" "$value" "$marker"
}

github_api() {
    local method="$1"
    local endpoint="$2"
    local data_file="${3:-}"

    require_env GITHUB_TOKEN

    local -a args=(
        -fsSL
        -X "$method"
        -H "Authorization: Bearer $GITHUB_TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    if [ -n "$data_file" ]; then
        args+=(-H "Content-Type: application/json" --data @"$data_file")
    fi

    curl "${args[@]}" "https://api.github.com${endpoint}"
}

github_api_with_token() {
    local token="$1"
    local method="$2"
    local endpoint="$3"
    local data_file="${4:-}"

    if [ -z "$token" ]; then
        echo "ERROR: missing required token for github_api_with_token" >&2
        exit 1
    fi

    local -a args=(
        -fsSL
        -X "$method"
        -H "Authorization: Bearer $token"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    if [ -n "$data_file" ]; then
        args+=(-H "Content-Type: application/json" --data @"$data_file")
    fi

    curl "${args[@]}" "https://api.github.com${endpoint}"
}

github_api_allow_404() {
    local method="$1"
    local endpoint="$2"
    local data_file="${3:-}"

    require_env GITHUB_TOKEN

    local response_file status
    response_file="$(mktemp)"

    local -a args=(
        -sSL
        -o "$response_file"
        -w "%{http_code}"
        -X "$method"
        -H "Authorization: Bearer $GITHUB_TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    if [ -n "$data_file" ]; then
        args+=(-H "Content-Type: application/json" --data @"$data_file")
    fi

    status="$(curl "${args[@]}" "https://api.github.com${endpoint}")"
    if [ "$status" = "404" ]; then
        rm -f "$response_file"
        return 1
    fi

    if [ "${status#2}" = "$status" ]; then
        cat "$response_file" >&2
        rm -f "$response_file"
        echo "ERROR: GitHub API request failed with status $status" >&2
        exit 1
    fi

    cat "$response_file"
    rm -f "$response_file"
}
