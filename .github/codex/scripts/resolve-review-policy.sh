#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

EVENT_PATH="${GITHUB_EVENT_PATH:-${1:-}}"

require_env GITHUB_EVENT_NAME

if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
    echo "ERROR: GITHUB_EVENT_PATH is not set or does not exist" >&2
    exit 1
fi

actor_login="$(jq -r '.comment.user.login // .sender.login // empty' "$EVENT_PATH")"
actor_type="$(jq -r '.comment.user.type // .sender.type // ""' "$EVENT_PATH")"
allow_users="$(resolve_allowed_users)"
allow_bots="$(resolve_allowed_bots)"
trigger_handle="$(resolve_trigger_handle)"
normalized_actor_login="$(normalize_login_for_allowlist "$actor_login")"
normalized_trigger_handle="$(normalize_login_for_allowlist "$trigger_handle")"

authorized="false"
can_run="false"
allow_codex_action_bots="false"
reason=""

if [ -z "$actor_login" ]; then
    reason="Unable to determine the actor that triggered this review."
elif [ "$GITHUB_EVENT_NAME" = "issue_comment" ] && [ "$actor_type" = "Bot" ]; then
    reason="Bot-authored PR comments never trigger manual review commands."
elif [ "$GITHUB_EVENT_NAME" = "pull_request" ] && [ "${PR_IS_SAME_REPO:-false}" != "true" ]; then
    reason="Skipping automatic review on fork PRs because self-hosted provider credentials are unavailable to pull_request runs."
elif [ "${PROVIDER_SUPPORTED:-true}" != "true" ]; then
    reason="${PROVIDER_REASON:-Unsupported bot provider.}"
elif [ "${PROVIDER_SECRET_READY:-false}" != "true" ]; then
    reason="Skipping review because required ${PROVIDER_SECRET_NAME:-provider} credentials are unavailable."
elif [ "$actor_type" = "Bot" ] && ! csv_contains_login "$actor_login" "$allow_bots"; then
    reason="Triggering bot actor is not in the strict bot allowlist, so this review request was denied."
elif actor_is_allowlisted "$actor_login" "$actor_type" "$allow_users" "$allow_bots"; then
    authorized="true"
    can_run="true"
    if [ "$actor_type" = "Bot" ] && [[ "$GITHUB_EVENT_NAME" == pull_request* ]]; then
        allow_codex_action_bots="true"
        if [ "$normalized_actor_login" = "$normalized_trigger_handle" ]; then
            reason="Configured review bot-authored PR update will be re-reviewed to produce a fresh artifact."
        else
            reason="Allowlisted bot-authored PR update will be re-reviewed to produce a fresh artifact."
        fi
    else
        reason="Triggering actor is allowlisted for bot reviews."
    fi
else
    reason="Triggering actor is not in the strict bot allowlist, so this review request was denied."
fi

set_output "actor_login" "$actor_login"
set_output "actor_type" "$actor_type"
set_output "authorized" "$authorized"
set_output "can_run" "$can_run"
set_output "allow_codex_action_bots" "$allow_codex_action_bots"
set_output "reason" "$reason"
