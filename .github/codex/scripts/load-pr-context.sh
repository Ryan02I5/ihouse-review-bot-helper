#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

EVENT_PATH="${GITHUB_EVENT_PATH:-${1:-}}"

require_env GITHUB_REPOSITORY

if [ -z "$EVENT_PATH" ] || [ ! -f "$EVENT_PATH" ]; then
    echo "ERROR: GITHUB_EVENT_PATH is not set or does not exist" >&2
    exit 1
fi

pr_number="$(jq -r '.pull_request.number // .issue.number // empty' "$EVENT_PATH")"
if [ -z "$pr_number" ]; then
    echo "ERROR: unable to determine pull request number from event payload" >&2
    exit 1
fi

pr_json="$(github_api GET "/repos/$GITHUB_REPOSITORY/pulls/$pr_number")"

base_ref="$(printf '%s' "$pr_json" | jq -r '.base.ref')"
base_sha="$(printf '%s' "$pr_json" | jq -r '.base.sha')"
head_ref="$(printf '%s' "$pr_json" | jq -r '.head.ref')"
head_sha="$(printf '%s' "$pr_json" | jq -r '.head.sha')"
head_repo_full_name="$(printf '%s' "$pr_json" | jq -r '.head.repo.full_name')"
is_same_repo="$(printf '%s' "$pr_json" | jq -r --arg repo "$GITHUB_REPOSITORY" 'if .head.repo.full_name == $repo then "true" else "false" end')"
is_draft="$(printf '%s' "$pr_json" | jq -r 'if .draft then "true" else "false" end')"
pr_title="$(printf '%s' "$pr_json" | jq -r '.title // ""')"
pr_body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
pr_url="$(printf '%s' "$pr_json" | jq -r '.html_url')"

set_output "pr_number" "$pr_number"
set_output "pr_title" "$pr_title"
set_output "pr_body" "$pr_body"
set_output "pr_url" "$pr_url"
set_output "base_ref" "$base_ref"
set_output "base_sha" "$base_sha"
set_output "head_ref" "$head_ref"
set_output "head_sha" "$head_sha"
set_output "head_repo_full_name" "$head_repo_full_name"
set_output "is_same_repo" "$is_same_repo"
set_output "is_draft" "$is_draft"
set_output "merge_ref" "refs/pull/$pr_number/merge"
set_output "head_checkout_ref" "refs/pull/$pr_number/head"
