#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

primary_outcome="${PRIMARY_OUTCOME:-skipped}"
primary_retry_outcome="${PRIMARY_RETRY_OUTCOME:-skipped}"
fallback_outcome="${FALLBACK_OUTCOME:-skipped}"

outcome="$primary_outcome"
attempt="primary"
attempt_path="none"
failure_class="none"

attempts=()
if [ "$primary_outcome" != "skipped" ]; then
    attempts+=("primary")
fi
if [ "$primary_retry_outcome" != "skipped" ]; then
    attempts+=("primary_retry")
fi
if [ "$fallback_outcome" != "skipped" ]; then
    attempts+=("fallback")
fi

if [ "${#attempts[@]}" -gt 0 ]; then
    attempt_path="$(printf '%s' "${attempts[0]}")"
    if [ "${#attempts[@]}" -gt 1 ]; then
        attempt_path="$(printf '%s' "${attempts[*]}")"
        attempt_path="${attempt_path// / -> }"
    fi
fi

if [ "$primary_outcome" = "success" ]; then
    outcome="success"
    attempt="primary"
elif [ "$primary_retry_outcome" = "success" ]; then
    outcome="success"
    attempt="primary_retry"
elif [ "$fallback_outcome" = "success" ]; then
    outcome="success"
    attempt="fallback"
elif [ "$fallback_outcome" != "skipped" ]; then
    outcome="$fallback_outcome"
    attempt="fallback"
elif [ "$primary_retry_outcome" != "skipped" ]; then
    outcome="$primary_retry_outcome"
    attempt="primary_retry"
elif [ "$primary_outcome" != "skipped" ]; then
    outcome="$primary_outcome"
    attempt="primary"
else
    outcome="skipped"
    attempt="none"
fi

if [ "$outcome" != "success" ] && [ "$outcome" != "skipped" ]; then
    failure_class="execution_error"
fi

set_output "outcome" "$outcome"
set_output "attempt" "$attempt"
set_output "attempt_path" "$attempt_path"
set_output "failure_class" "$failure_class"
