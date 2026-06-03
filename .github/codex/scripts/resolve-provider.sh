#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

trigger_handle="$(resolve_trigger_handle)"
model="$(resolve_model)"
review_model="$(resolve_review_model)"
reasoning_effort="$(resolve_reasoning_effort)"
responses_api_endpoint="$(resolve_responses_api_endpoint)"

supported="true"
reason=""
provider_secret_name=""
provider_secret_ready="false"

if [ -n "${CODEX_PROVIDER_API_KEY_SECRET:-}" ]; then
    provider_secret_name="CODEX_PROVIDER_API_KEY"
    provider_secret_ready="true"
elif [ -n "${OPENAI_API_KEY_SECRET:-}" ]; then
    provider_secret_name="OPENAI_API_KEY"
    provider_secret_ready="true"
else
    provider_secret_name="CODEX_PROVIDER_API_KEY"
fi

github_app_ready="false"
if [ -n "${CODEX_BOT_APP_ID_SECRET:-}" ] && [ -n "${CODEX_BOT_PRIVATE_KEY_SECRET:-}" ]; then
    github_app_ready="true"
fi

set_output "trigger_handle" "$trigger_handle"
set_output "model" "$model"
set_output "review_model" "$review_model"
set_output "reasoning_effort" "$reasoning_effort"
set_output "responses_api_endpoint" "$responses_api_endpoint"
set_output "supported" "$supported"
set_output "reason" "$reason"
set_output "provider_secret_name" "$provider_secret_name"
set_output "provider_secret_ready" "$provider_secret_ready"
set_output "github_app_ready" "$github_app_ready"
