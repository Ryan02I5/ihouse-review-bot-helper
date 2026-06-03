#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

require_env OWNER REPO PR_NUMBER HEAD_SHA RUN_URL RUN_STATUS

review_json="${REVIEW_JSON:-codex-review-output.json}"
review_findings_count="${REVIEW_FINDINGS_COUNT:-}"
review_findings_summary="${REVIEW_FINDINGS_SUMMARY:-}"
failure_comment_policy="${FAILURE_COMMENT_POLICY:-publish}"
strict_findings_publish="false"
if [ "$failure_comment_policy" = "skip" ]; then
    strict_findings_publish="true"
fi
trigger_handle="$(resolve_trigger_handle)"
normalized_bot_login="$(normalize_login_for_allowlist "$trigger_handle")"
fallback_publish_login="$(normalize_login_for_allowlist "${PUBLISH_FALLBACK_LOGIN:-github-actions[bot]}")"
source_comment_id="${SOURCE_COMMENT_ID:-}"

source_comment_created_at() {
    local source_comment_json

    if [ -z "$source_comment_id" ]; then
        return 0
    fi

    source_comment_json="$(github_api_allow_404 GET "/repos/$OWNER/$REPO/issues/comments/$source_comment_id" || true)"
    if [ -z "$source_comment_json" ]; then
        return 0
    fi

    jq -r '.created_at // empty' <<<"$source_comment_json"
}

review_placeholder_body() {
    if [ -n "$source_comment_id" ]; then
        printf '<!-- inline-review-only head:%s source-comment:%s -->\n' "$HEAD_SHA" "$source_comment_id"
    else
        printf '<!-- inline-review-only head:%s -->\n' "$HEAD_SHA"
    fi
}

clean_signal_body() {
    if [ -n "$source_comment_id" ]; then
        printf 'iHouse Review: Didn'\''t find any major issues.\n<!-- clean-signal head:%s source-comment:%s -->\n' "$HEAD_SHA" "$source_comment_id"
    else
        printf 'iHouse Review: Didn'\''t find any major issues.\n<!-- clean-signal head:%s -->\n' "$HEAD_SHA"
    fi
}

detect_failure_class_from_logs() {
    local token="${ACTIONS_READ_TOKEN:-}"
    local run_id="${WORKFLOW_RUN_ID:-}"
    local review_run_job_name="${REVIEW_RUN_JOB_NAME:-review / review_run}"
    local jobs_json review_run_job_id log_excerpt

    if [ -z "$token" ] || [ -z "$run_id" ]; then
        return 0
    fi

    jobs_json="$(github_api_with_token "$token" GET "/repos/$OWNER/$REPO/actions/runs/$run_id/jobs?per_page=100" || true)"
    if [ -z "$jobs_json" ]; then
        return 0
    fi

    review_run_job_id="$(jq -r --arg name "$review_run_job_name" '.jobs[]? | select(.name == $name) | .id' <<<"$jobs_json" | head -n 1)"
    if [ -z "$review_run_job_id" ] || [ "$review_run_job_id" = "null" ]; then
        return 0
    fi

    log_excerpt="$(curl -fsSL \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$OWNER/$REPO/actions/jobs/$review_run_job_id/logs" 2>/dev/null || true)"

    if printf '%s' "$log_excerpt" | grep -F "Selected model is at capacity" >/dev/null; then
        printf 'provider_capacity'
        return 0
    fi

    if printf '%s' "$log_excerpt" | grep -F "model is at capacity" >/dev/null; then
        printf 'provider_capacity'
        return 0
    fi
}

resolve_effective_failure_class() {
    local configured_failure_class="${FAILURE_CLASS:-none}"
    local detected_failure_class=""

    if [ "$configured_failure_class" = "provider_capacity" ]; then
        printf '%s' "$configured_failure_class"
        return 0
    fi

    detected_failure_class="$(detect_failure_class_from_logs || true)"
    if [ -n "$detected_failure_class" ]; then
        printf '%s' "$detected_failure_class"
        return 0
    fi

    printf '%s' "$configured_failure_class"
}

failure_signal_body() {
    local effective_failure_class="${1:-execution_error}"

    if [ "$effective_failure_class" = "provider_capacity" ]; then
        cat <<EOF
iHouse Review: Review did not complete because the provider reported temporary model capacity pressure. This is not a code finding. Re-run the GitHub review workflow or re-request review after the provider recovers. Check the workflow run for details.
EOF
        return 0
    fi

    cat <<'EOF'
iHouse Review: Review did not complete due to provider/runtime/workflow failure. Check the workflow run for details.
EOF
}

priority_badge_markdown() {
    case "${1:-1}" in
        0)
            printf '![P0 Badge](https://img.shields.io/badge/P0-red?style=flat)'
            ;;
        *)
            printf '![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)'
            ;;
    esac
}

inline_finding_body() {
    local title="$1"
    local body="$2"
    local priority="$3"
    local badge

    badge="$(priority_badge_markdown "$priority")"

    cat <<EOF
**<sub><sub>${badge}</sub></sub>  ${title}**

${body}

Useful? React with 👍 / 👎.
EOF
}

normalize_review_path() {
    local raw_path="${1:-}"
    RAW_PATH="$raw_path" REPO_NAME="$REPO" WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$(pwd)}" python3 - <<'PY'
import os

raw_path = os.environ.get("RAW_PATH", "")
repo_name = os.environ.get("REPO_NAME", "")
workspace_root = os.environ.get("WORKSPACE_ROOT", "")

if not raw_path:
    raise SystemExit(0)

if not os.path.isabs(raw_path):
    print(raw_path)
    raise SystemExit(0)

real_path = os.path.realpath(raw_path)
workspace_real = os.path.realpath(workspace_root) if workspace_root else ""

if workspace_real:
    try:
        if os.path.commonpath([real_path, workspace_real]) == workspace_real:
            print(os.path.relpath(real_path, workspace_real))
            raise SystemExit(0)
    except ValueError:
        pass

marker = f"/{repo_name}/" if repo_name else ""
if marker and marker in raw_path:
    print(raw_path.rsplit(marker, 1)[1])
PY
}

success_review_already_exists() {
    local body="$1"
    local since
    local reviews_json

    since="$(source_comment_created_at)"
    if [ -z "$since" ]; then
        return 1
    fi

    reviews_json="$(github_api GET "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100")"
    jq -e \
        --arg normalized_bot "$normalized_bot_login" \
        --arg fallback_login "$fallback_publish_login" \
        --arg body "$body" \
        --arg since "$since" \
        'map(
            select(
                (
                  (((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; "")) == $normalized_bot)
                  or
                  (((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; "")) == $fallback_login)
                )
                and (((.submitted_at // .created_at // "")) >= $since)
                and (((.body // "") | sub("\n$"; "")) == ($body | sub("\n$"; "")))
                and ((.state // "") == "COMMENTED")
            )
        ) | length > 0' <<<"$reviews_json" >/dev/null
}

comment_already_exists() {
    local body="$1"
    local since
    local comments_json

    since="$(source_comment_created_at)"
    comments_json="$(github_api GET "/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100")"
    jq -e \
        --arg normalized_bot "$normalized_bot_login" \
        --arg fallback_login "$fallback_publish_login" \
        --arg body "$body" \
        --arg since "$since" \
        'map(
            select(
                (
                  (((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; "")) == $normalized_bot)
                  or
                  (((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; "")) == $fallback_login)
                )
                and ((($since == "") or ((.created_at // "") >= $since)))
                and (((.body // "") | sub("\n$"; "")) == ($body | sub("\n$"; "")))
            )
        ) | length > 0' <<<"$comments_json" >/dev/null
}

positive_reaction_already_exists() {
    local since
    local reactions_json

    since="$(source_comment_created_at)"
    reactions_json="$(github_api GET "/repos/$OWNER/$REPO/issues/$PR_NUMBER/reactions?per_page=100")"
    jq -e \
        --arg normalized_bot "$normalized_bot_login" \
        --arg fallback_login "$fallback_publish_login" \
        --arg since "$since" \
        'map(
            select(
                ((.content // "") == "+1")
                and (
                  (((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; "")) == $normalized_bot)
                  or
                  (((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; "")) == $fallback_login)
                )
                and ((($since == "") or ((.created_at // "") >= $since)))
            )
        ) | length > 0' <<<"$reactions_json" >/dev/null
}

publish_issue_comment() {
    local body="$1"
    local payload_file

    payload_file="$(mktemp)"
    jq -n --arg body "$body" '{body: $body}' >"$payload_file"
    github_api POST "/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments" "$payload_file" >/dev/null
    rm -f "$payload_file"
}

add_positive_reaction_to_pr() {
    local payload_file

    if positive_reaction_already_exists; then
        return 0
    fi

    payload_file="$(mktemp)"
    jq -n '{content:"+1"}' >"$payload_file"
    github_api POST "/repos/$OWNER/$REPO/issues/$PR_NUMBER/reactions" "$payload_file" >/dev/null || true
    rm -f "$payload_file"
}

if [ "$RUN_STATUS" != "success" ]; then
    if [ "$RUN_STATUS" != "skipped" ]; then
        effective_failure_class="$(resolve_effective_failure_class)"
        failure_body="$(failure_signal_body "$effective_failure_class")"
        if ! comment_already_exists "$failure_body"; then
            publish_issue_comment "$failure_body"
        fi
    fi
    exit 0
fi

if [ ! -s "$review_json" ]; then
    if [ -n "$review_findings_count" ] && [ "$review_findings_count" = "0" ]; then
        clean_body="$(clean_signal_body)"
        if ! comment_already_exists "$clean_body"; then
            publish_issue_comment "$clean_body"
        fi
        add_positive_reaction_to_pr
        exit 0
    fi

    if [ -n "$review_findings_count" ] && [ "$review_findings_count" != "0" ]; then
        summary_block=""
        if [ -n "$review_findings_summary" ]; then
            summary_block=$'\n\nSummary:\n'"$review_findings_summary"
        fi
        fallback_body="iHouse Review: Structured review found ${review_findings_count} actionable finding(s), but the detailed review artifact was unavailable. Re-run the review workflow after fixing GitHub Actions storage/upload so full inline findings can be published.${summary_block}"
        if ! comment_already_exists "$fallback_body"; then
            publish_issue_comment "$fallback_body"
        fi
        exit 0
    fi

    effective_failure_class="$(resolve_effective_failure_class)"
    failure_body="$(failure_signal_body "$effective_failure_class")"
    if ! comment_already_exists "$failure_body"; then
        publish_issue_comment "$failure_body"
    fi
    exit 0
fi

findings_count="$(jq '.findings | length' "$review_json")"
findings_publish_failed="false"
if [ "$findings_count" -eq 0 ]; then
    clean_body="$(clean_signal_body)"
    if ! comment_already_exists "$clean_body"; then
        publish_issue_comment "$clean_body"
    fi
    add_positive_reaction_to_pr
    exit 0
else
    review_comments_file="$(mktemp)"
    payload_file="$(mktemp)"
    review_body_file="$(mktemp)"
    printf '[]' >"$review_comments_file"

    while IFS= read -r finding; do
        absolute_path="$(printf '%s' "$finding" | jq -r '.code_location.absolute_file_path')"
        path="$(normalize_review_path "$absolute_path")"
        start_line="$(printf '%s' "$finding" | jq -r '.code_location.line_range.start')"
        end_line="$(printf '%s' "$finding" | jq -r '.code_location.line_range.end')"
        title="$(printf '%s' "$finding" | jq -r '.title')"
        body="$(printf '%s' "$finding" | jq -r '.body')"
        priority="$(printf '%s' "$finding" | jq -r '.priority')"
        formatted_body="$(inline_finding_body "$title" "$body" "$priority")"

        if [ -z "$path" ] || [ -z "$start_line" ] || [ -z "$end_line" ] || [ "$start_line" = "null" ] || [ "$end_line" = "null" ]; then
            continue
        fi

        if [ "$start_line" -lt "$end_line" ]; then
            jq \
                --arg body "$formatted_body" \
                --arg path "$path" \
                --argjson start_line "$start_line" \
                --argjson end_line "$end_line" \
                '. + [{
                  body: $body,
                  path: $path,
                  start_line: $start_line,
                  start_side: "RIGHT",
                  line: $end_line,
                  side: "RIGHT"
                }]' "$review_comments_file" >"$payload_file"
        else
            jq \
                --arg body "$formatted_body" \
                --arg path "$path" \
                --argjson line "$end_line" \
                '. + [{
                  body: $body,
                  path: $path,
                  line: $line,
                  side: "RIGHT"
                }]' "$review_comments_file" >"$payload_file"
        fi

        mv "$payload_file" "$review_comments_file"
    done < <(jq -c '.findings[]' "$review_json")

    review_comments_count="$(jq 'length' "$review_comments_file")"

    if [ "$review_comments_count" -eq 0 ]; then
        findings_publish_failed="true"
    else
        review_body="$(review_placeholder_body)"
        if success_review_already_exists "$review_body"; then
            rm -f "$review_comments_file" "$payload_file" "$review_body_file"
            exit 0
        fi

        printf '%s\n' "$review_body" >"$review_body_file"
        jq -n \
            --rawfile body "$review_body_file" \
            --arg commit_id "$HEAD_SHA" \
            --slurpfile comments "$review_comments_file" \
            '{
              body: $body,
              commit_id: $commit_id,
              event: "COMMENT",
              comments: $comments[0]
            }' >"$payload_file"

        if ! github_api POST "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" "$payload_file" >/dev/null 2>&1; then
            findings_publish_failed="true"
        fi
    fi

    rm -f "$review_comments_file" "$payload_file" "$review_body_file"
fi

if [ "$strict_findings_publish" = "true" ] && [ "$findings_publish_failed" = "true" ]; then
    printf 'ERROR: findings exist but reviewer feedback publish failed in strict gate mode.\n' >&2
    exit 1
fi
