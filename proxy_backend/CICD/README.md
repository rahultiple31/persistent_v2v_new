# Nova Proxy CI/CD

Use `proxy_backend/CICD/azure-cicd.yml` as the Azure pipeline path in this
repository. Select `dev` or `dev-nsso`; both deploy in `us-east-1`.

Provision the proxy infrastructure and V2V stack first, as described in
[DEPLOY-V2V.md](../../DEPLOY-V2V.md). Then select `terraformAction=apply`
to activate the proxy after its plan and environment approval.

The pipeline tests the real Nova proxy, builds an immutable ARM64 image with
`proxy_backend` as the Docker context, and updates the existing proxy
Terraform state. It reads ECR repository output from that state and Cognito
IDs/application origin from the V2V state. Terraform owns the image and startup
configuration; activation removes the health-only bootstrap command.

The pipeline uses `AWS_DEV_OIDC_ROLE_ARN`, `System.AccessToken`, and
`System.OidcRequestUri`. It requires backend state and lock access, ECR push,
Terraform deployment permissions, and passing the ECS task roles. Both
`dev` and `dev-nsso` Azure environments must be configured for approval.

A subsequent infrastructure pipeline run preserves the activated image.
Subsequent local proxy applies must keep `proxy_runtime_enabled=true`
and the desired immutable `proxy_container_image`.
