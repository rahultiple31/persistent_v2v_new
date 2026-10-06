#!/usr/bin/env bash

# Source after init so an infrastructure update keeps the previously activated image.
proxy_outputs="$(terraform output -json)"
if [ "$(jq -r '.regional_proxy.value["us-east-1"].runtime_enabled // false' <<< "$proxy_outputs")" = "true" ]; then
  export TF_VAR_proxy_runtime_enabled=true
  TF_VAR_proxy_container_image="$(jq -er '.regional_proxy.value["us-east-1"].deployed_container_image' <<< "$proxy_outputs")"
  export TF_VAR_proxy_container_image
fi
