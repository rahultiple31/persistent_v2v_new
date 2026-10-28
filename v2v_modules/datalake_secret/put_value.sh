#!/usr/bin/env bash
# Source this after Terraform creates the secret. Values come from Azure secret variables.
set -euo pipefail
set +x

for name in DATALAKE_AWS_ACCESS_KEY_ID DATALAKE_AWS_SECRET_ACCESS_KEY; do
  value="${!name-}"
  if [ -z "$value" ] || [[ "$value" == '$('* ]]; then
    echo "Set the Azure secret variable $name before applying." >&2
    return 1
  fi
done

if [ "${1:-}" = --check ]; then
  return 0
fi

payload_file="$(mktemp)"
trap 'rm -f -- "$payload_file"' EXIT

python3 - "$payload_file" <<'PY'
import hashlib
import json
import os
import sys

names = ("DATALAKE_AWS_ACCESS_KEY_ID", "DATALAKE_AWS_SECRET_ACCESS_KEY")
values = {}
for name in names:
    value = os.environ.get(name, "")
    if not value or (value.startswith("$(") and value.endswith(")")):
        raise SystemExit(f"Set the Azure secret variable {name} before applying.")
    values[name] = value

secret_string = json.dumps(
    {
        "aws_access_key_id": values["DATALAKE_AWS_ACCESS_KEY_ID"],
        "aws_secret_access_key": values["DATALAKE_AWS_SECRET_ACCESS_KEY"],
    },
    sort_keys=True,
    separators=(",", ":"),
)

request = {
    "SecretId": "BTSGSD-V2V-US-Datalake/dev",
    "SecretString": secret_string,
    "ClientRequestToken": hashlib.sha256(secret_string.encode()).hexdigest(),
}

with open(sys.argv[1], "w", encoding="utf-8") as payload:
    json.dump(request, payload)
PY

aws secretsmanager put-secret-value \
  --region us-east-1 \
  --cli-input-json "file://$payload_file" \
  --no-cli-pager >/dev/null

rm -f -- "$payload_file"
trap - EXIT
