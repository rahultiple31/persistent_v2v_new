# CICD Pipeline

This folder contains the Dockerfile and Azure DevOps pipeline for the proxy service.

## Files

- `Dockerfile` builds the Node.js proxy image for ECS Fargate ARM64.
- `azure-pipelines.yml` builds and pushes the image, creates a new ECS task-definition revision, and updates the existing ECS service.

The pipeline does not initialize, plan, or apply Terraform. Provision the ECR repository, ECS cluster, ECS service, and initial task definition manually with the files in `../terraform` before running it.

## Expected Repository Layout

The workflow builds with repository root as the Docker context and this Dockerfile:

```bash
docker buildx build --platform linux/arm64 -f CICD/Dockerfile .
```

The application source is at:

- `package.json`
- `package-lock.json`
- `src/index.js`

The included `src/index.js` makes the image buildable and provides `/healthz`, but its application routes intentionally return HTTP 501. Replace it with the V2V translation implementation before production use.

## Azure DevOps Setup

1. Install the AWS Toolkit for Azure DevOps extension in the ADO organization.
2. Create an AWS service connection named `aws-dev-service-connection`, or change the `awsServiceConnection` variable in `azure-pipelines.yml`.
3. Create a YAML pipeline and select `CICD/azure-pipelines.yml` as its path.
4. Confirm the service connection is authorized for the pipeline.

The Azure pipeline defaults to the same ECR repository, ECS cluster, service, container name, and AWS Region as the Terraform configuration. Change its variables if the manually deployed resource names differ. Run the full manual Terraform deployment once before the first pipeline run; the Terraform bootstrap command keeps the initial ECS service healthy until this pipeline deploys the application image.

Each deployment uses an immutable image tag containing the source commit and Azure build ID. The pipeline reads the task definition currently used by the service and changes only the `proxy` container image. Before later manual Terraform applies, set `container_image` to the image that should remain deployed so Terraform does not restore an older image.

The AWS service connection needs permission to push to ECR plus:

- `sts:GetCallerIdentity`
- `ecr:DescribeRepositories`
- `ecs:DescribeServices`
- `ecs:DescribeTaskDefinition`
- `ecs:RegisterTaskDefinition`
- `ecs:UpdateService`
- `iam:PassRole` for the ECS task execution role and task role

The Microsoft-hosted agent also pulls `tonistiigi/binfmt` to enable the ARM64 Docker build. The Azure pipeline does not run Terraform.
