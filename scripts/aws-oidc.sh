#!/usr/bin/env bash
set -euo pipefail

: "${AWS_OIDC_ROLE_ARN:?Configure AWS_DEV_OIDC_ROLE_ARN}"
: "${SYSTEM_ACCESSTOKEN:?System.AccessToken is required}"
: "${SYSTEM_OIDCREQUESTURI:?System.OidcRequestUri is required}"
if [[ "$AWS_OIDC_ROLE_ARN" == \$\(* ]]; then
  echo "AWS_DEV_OIDC_ROLE_ARN is not configured" >&2
  exit 1
fi
oidc_response="$(curl --fail --silent --show-error -X POST \
  -H "Authorization: Bearer $SYSTEM_ACCESSTOKEN" -H 'Content-Length: 0' \
  "${SYSTEM_OIDCREQUESTURI}?api-version=7.1-preview.1")"
AWS_WEB_IDENTITY_TOKEN_FILE="$(mktemp)"
export AWS_WEB_IDENTITY_TOKEN_FILE
jq -er '.oidcToken' <<< "$oidc_response" > "$AWS_WEB_IDENTITY_TOKEN_FILE"
chmod 600 "$AWS_WEB_IDENTITY_TOKEN_FILE"
export AWS_ROLE_ARN="$AWS_OIDC_ROLE_ARN"
export AWS_ROLE_SESSION_NAME="v2v-proxy-${BUILD_BUILDID:-local}"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
trap 'rm -f "$AWS_WEB_IDENTITY_TOKEN_FILE"' EXIT
