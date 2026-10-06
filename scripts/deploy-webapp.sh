#!/usr/bin/env bash
set -euo pipefail

dist_directory="${1:?Pass the built webapp dist directory}"
test -f "$dist_directory/index.html"
settings="$(terraform output -json connect_v2v_translation)"
if [ "$(jq -r '.deploy_v2v_assets' <<< "$settings")" != "true" ]; then
  exit 0
fi
bucket="$(jq -er '.v2v_bucket_name' <<< "$settings")"
prefix="$(jq -r '.v2v_root_prefix' <<< "$settings")"
destination="s3://$bucket/${prefix%/}"
destination="${destination%/}/"

# Publish dependencies first, index last, and keep older chunks used by open calls.
aws s3 sync "$dist_directory/" "$destination" \
  --exclude index.html --exclude frontend-config.js --cache-control no-cache
aws s3 cp "$dist_directory/index.html" "${destination}index.html" \
  --content-type text/html --cache-control no-cache
distribution="$(jq -er '.cloudfront_distribution_id' <<< "$settings")"
aws cloudfront create-invalidation --distribution-id "$distribution" \
  --paths '/index.html' '/frontend-config.js' >/dev/null
