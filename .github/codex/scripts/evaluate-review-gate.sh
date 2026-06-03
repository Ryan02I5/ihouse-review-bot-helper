#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

require_env RUN_STATUS REVIEW_JSON

attempt_path="${ATTEMPT_PATH:-none}"
failure_class="${FAILURE_CLASS:-none}"
artifact_ready="${ARTIFACT_READY:-false}"
skip_reason="${SKIP_REASON:-}"
publish_job_result="${PUBLISH_JOB_RESULT:-skipped}"
summary_file="${GITHUB_STEP_SUMMARY:-}"

write_summary() {
    if [ -n "$summary_file" ]; then
        printf '%s\n' "$@" >> "$summary_file"
    fi
}

emit_outputs() {
    local result="$1"
    local gate_class="$2"
    local reason="$3"
    local details="${4:-}"
    local next_action="${5:-}"

    set_output "result" "$result"
    set_output "gate_class" "$gate_class"
    set_output "reason" "$reason"
    set_output "details" "$details"
    set_output "next_action" "$next_action"
}

write_blocked_summary() {
    local gate_class="$1"
    local reason="$2"
    local details="${3:-}"
    local next_action="$4"

    write_summary "## Review gate" ""
    write_summary "- Result: blocked"
    write_summary "- Class: $gate_class"
    write_summary "- Reason: $reason"
    if [ -n "$attempt_path" ] && [ "$attempt_path" != "none" ] && [ "$gate_class" = "execution" ]; then
        write_summary "- Attempt path: $attempt_path"
    fi
    write_summary "- Next action: $next_action"
    if [ -n "$details" ]; then
        write_summary "" "### Details" "$details"
    fi
}

if [ "${RUN_STATUS:-}" = "skipped" ]; then
    reason="review execution was skipped."
    if [ -n "$skip_reason" ]; then
        reason="review execution was skipped: ${skip_reason}"
    fi
    next_action="Address the skip reason (policy, allowlist, or credentials), then re-run the checks."
    write_blocked_summary "skipped" "$reason" "" "$next_action"
    emit_outputs "blocked" "skipped" "$reason" "" "$next_action"
    exit 0
fi

if [ "${RUN_STATUS:-}" != "success" ]; then
    reason="review execution did not complete successfully (run_status='${RUN_STATUS:-unset}')."
    next_action="Re-run failed jobs. If this repeats, inspect the provider/action logs and workflow prerequisites."
    write_blocked_summary "execution" "$reason" "" "$next_action"
    emit_outputs "blocked" "execution" "$reason" "" "$next_action"
    exit 0
fi

if [ "$artifact_ready" != "true" ]; then
    reason="review artifact was not prepared."
    next_action="Re-run failed jobs. If this repeats, inspect artifact upload and provider execution logs."
    write_blocked_summary "execution" "$reason" "" "$next_action"
    emit_outputs "blocked" "execution" "$reason" "" "$next_action"
    exit 0
fi

if [ ! -s "${REVIEW_JSON}" ]; then
    reason="review artifact file is missing or empty: ${REVIEW_JSON}."
    next_action="Re-run failed jobs. If this repeats, inspect artifact upload and workflow sandbox output."
    write_blocked_summary "execution" "$reason" "" "$next_action"
    emit_outputs "blocked" "execution" "$reason" "" "$next_action"
    exit 0
fi

findings_count="$(jq '.findings | length' "${REVIEW_JSON}")"
if [ "${findings_count}" -gt 0 ]; then
    details="$(jq -r '.findings[:3][] | "- " + .title' "${REVIEW_JSON}")"
    if [ "$publish_job_result" != "success" ]; then
        reason="structured review reported ${findings_count} actionable finding(s), and reviewer feedback publish did not complete (review_publish='${publish_job_result}')."
        details="${details}"$'\n'"- Reviewer feedback publish did not complete."
        next_action="Review gate details, fix findings, and re-run checks. If publish keeps failing, inspect review_publish logs and GitHub App permissions."
        write_blocked_summary "findings" "$reason" "$details" "$next_action"
        emit_outputs "blocked" "findings" "$reason" "$details" "$next_action"
    else
        reason="structured review reported ${findings_count} actionable finding(s)."
        next_action="Review the gate details and PR review feedback, fix the findings, and re-run the checks."
        write_blocked_summary "findings" "$reason" "$details" "$next_action"
        emit_outputs "blocked" "findings" "$reason" "$details" "$next_action"
    fi
    exit 0
fi

write_summary "## Review gate" ""
write_summary "- Result: passed"
write_summary "- Class: passed"
write_summary "- Reason: no actionable findings."
write_summary "- Next action: merge can proceed once the other required checks are green."
emit_outputs "passed" "passed" "no actionable findings." "" "merge can proceed once the other required checks are green."
