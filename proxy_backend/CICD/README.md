# V2V POC proxy CI/CD

Pipeline file: `proxy_backend/CICD/azure-cicd.yml`. It deploys the proxy image
to the V2V POC stack in `environments/v2v-resources-dev` (`us-east-1`).

## Order

1. Create or update the infrastructure with `v2v-azure-pipeline.yml`
   (`targetEnvironment = v2v-resources-dev`, `targetModule = all`). This
   pipeline reads the ECR repository from that Terraform state, so the stack
   must exist first. Until step 2 has run, the ECS service has no working
   image and is not healthy.
2. Run this pipeline with `terraformAction = apply` (from `main`).

Both pipelines use the same Terraform state
(`terraform-state/V2V-poc/terraform.tfstate`).

## What the pipeline does

- Tests the proxy on Node 24: `npm ci`, `npm audit --audit-level=high`,
  `npm test`.
- Runs `terraform validate` and `terraform test`.
- Builds the ARM64 image from the **repository root** (the image also builds
  `webapp/`), with `proxy_backend/CICD/Dockerfile`. What is sent to the build is
  limited by `proxy_backend/CICD/Dockerfile.dockerignore`.
- Scans the image with Trivy (fixable CRITICAL/HIGH findings and secrets fail
  the build) and pushes it to ECR only when clean, as
  `<commit>-<build id>` and as `latest`.
- Plans Terraform with `container_image_tag = <commit>-<build id>`; the apply
  stage applies that plan.

Pushing `latest` as well keeps the two pipelines in step:
`terraform.dev.tfvars` sets `container_image_tag = "latest"`, so a later
`v2v-azure-pipeline.yml` run keeps the same image.

## Requirements

- Pipeline variable `AWS_DEV_OIDC_ROLE_ARN` (secret), plus `System.AccessToken`
  and `System.OidcRequestUri`.
- The role needs state bucket access, ECR push, the Terraform deployment
  permissions, and `iam:PassRole` for the ECS task roles.
- Azure DevOps environment `v2v-resources` (add an approval check for a manual
  gate).
- The build agent must be able to reach Docker Hub (node and binfmt images),
  GitHub releases (Trivy), the npm registry and the Trivy database.
