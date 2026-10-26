# V2V Private POC — Terraform

Terraform equivalent of `cdk-stacks/lib/private-poc-stack.ts`.  
All functionality is preserved; no code changes are required in `proxy/` or `webapp/`.

---

## Folder structure

```
terraform/
├── providers.tf              # AWS provider + Terraform version constraints
├── variables.tf              # All input variables (mirrors private-poc.config.ts)
├── locals.tf                 # Computed values (CSP, webapp config JSON, env vars)
├── main.tf                   # Root module — wires all child modules
├── outputs.tf                # Stack outputs
├── terraform.tfvars.example  # Copy → terraform.tfvars and fill in values
├── scripts/
│   └── build-and-push.sh     # Builds webapp + Docker image and pushes to ECR
└── modules/
    ├── networking/   # Security groups + VPC interface endpoints
    ├── alb/          # S3 log bucket + ALB + listener + target group
    ├── waf/          # WAF v2 WebACL + ALB association
    ├── cloudwatch/   # CloudWatch log group (90-day retention)
    ├── ssm/          # SSM parameters (forceBackupTranslation, bedrockRegion)
    ├── iam/          # Task execution role + task role + all inline policies
    ├── ecr/          # ECR private repository + lifecycle policy
    ├── ecs/          # ECS cluster + Fargate task definition + service
    └── dns/          # Route 53 A record + Connect approved origin
```

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | 1.5.0 |
| AWS CLI v2 | 2.x |
| Docker + buildx | 24.x |
| Node.js | 18.x (webapp build) |

IAM permissions required by the Terraform executor principal:

- `ec2:*` (security groups, VPC endpoints)
- `elasticloadbalancing:*`
- `wafv2:*`
- `ecs:*`
- `ecr:*`
- `iam:*` (create roles and inline policies)
- `logs:*`
- `ssm:*`
- `s3:*` (ALB log bucket)
- `route53:*`
- `connect:AssociateApprovedOrigin`, `connect:DisassociateApprovedOrigin`

---

## First-time deployment

### 1 — Copy and populate the variable file

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your VPC, subnet, OIDC, Connect, and certificate values
```

### 2 — Initialise Terraform and create the ECR repository first

The proxy Docker image must exist in ECR before `terraform apply` creates the
ECS service. Bootstrap the repository in a targeted apply:

```bash
cd terraform
terraform init
terraform apply -target=module.ecr
```

### 3 — Build and push the proxy image

```bash
# From the repository root:
bash terraform/scripts/build-and-push.sh \
  --region  us-east-1      \
  --account 123456789012   \
  --repo    v2v-proxy       \
  --tag     latest
```

The script:
1. Runs `npm ci && npm run build` inside `webapp/` (produces `webapp/dist/`)
2. Authenticates Docker to ECR
3. Builds the `proxy/Dockerfile` for `linux/arm64` (Graviton Fargate)
4. Pushes the image to ECR

### 4 — Deploy the full stack

```bash
cd terraform
terraform apply
```

Terraform will create resources in dependency order:

```
ECR → CloudWatch → SSM → IAM
    → Networking (SGs + VPC endpoints)
    → ALB → WAF
    → ECS (cluster + task def + service)
    → DNS (Route 53 + Connect approved origin)
```

---

## Updating the container image

```bash
# Build and push a new image with a versioned tag
bash terraform/scripts/build-and-push.sh \
  --region us-east-1 --account 123456789012 --repo v2v-proxy --tag v1.2.0

# Roll out: Terraform updates only the task definition revision
cd terraform
terraform apply -var="container_image_tag=v1.2.0"
```

ECS performs a rolling update (min 100 % healthy, max 200 %) with circuit
breaker + rollback enabled. In-flight sessions are protected by the 480-second
target group deregistration delay and the 120-second task stop timeout.

---

## Runtime operations (no Terraform needed)

### Toggle backup translation mode

The proxy polls this SSM parameter every 30 seconds. No redeployment required.

```bash
# Force all calls to Transcribe + Translate + Polly
aws ssm put-parameter \
  --name  "/V2V/POC/forceBackupTranslation" \
  --value "true" \
  --overwrite

# Restore Nova Sonic
aws ssm put-parameter \
  --name  "/V2V/POC/forceBackupTranslation" \
  --value "false" \
  --overwrite
```

### Create the test sign-in SecureString (one-time, manual)

The `testSignIn` parameter **cannot** be created by Terraform because it is a
`SecureString` encrypted by the default SSM KMS key.  
Create it by hand once, then set `test_sign_in = true` in your tfvars:

```bash
aws ssm put-parameter \
  --name  "/V2V/POC/testSignIn" \
  --type  "SecureString"        \
  --value '{"users":[{"username":"agent1","password":"changeme"}]}'
```

---

## Module reference

### `networking`
| Resource | Description |
|----------|-------------|
| `aws_security_group.alb` | Ingress from VDI CIDRs → port 80/443; egress to service SG → 8080 |
| `aws_security_group.service` | Ingress from ALB SG → 8080; egress HTTPS to anywhere |
| `aws_security_group.endpoint` | Ingress HTTPS from service SG + extra CIDRs |
| `aws_vpc_endpoint.interface[*]` | bedrock-runtime, transcribestreaming, translate, polly, ssm, ecr.api, ecr.dkr, logs |

### `alb`
| Resource | Description |
|----------|-------------|
| `aws_s3_bucket.alb_logs` | Encrypted, SSL-enforced, 90-day lifecycle, retained on destroy |
| `aws_lb.main` | Internal ALB, drop invalid headers, 120 s idle timeout |
| `aws_lb_target_group.proxy` | IP targets, port 8080, /healthz, 480 s deregistration delay |
| `aws_lb_listener.http/https` | HTTP (80) or HTTPS (443) depending on `certificate_arn` |

### `waf`
| Resource | Description |
|----------|-------------|
| `aws_wafv2_web_acl.main` | IP reputation list (p0), known bad inputs (p1), optional common set (p2) |
| `aws_wafv2_web_acl_association.alb` | Binds WebACL to the ALB |

### `cloudwatch`
| Resource | Description |
|----------|-------------|
| `aws_cloudwatch_log_group.proxy` | `/ecs/V2V-Private-POC/proxy`, 90-day retention |

### `ssm`
| Resource | Description |
|----------|-------------|
| `aws_ssm_parameter.force_backup_translation` | `/V2V/POC/forceBackupTranslation` — runtime switch |
| `aws_ssm_parameter.bedrock_region` | `/V2V/POC/bedrockRegion` — informational |

### `iam`
| Resource | Description |
|----------|-------------|
| `aws_iam_role.task_execution` | ECR pull + CloudWatch Logs write |
| `aws_iam_role.task` | bedrock:InvokeModel, transcribe/translate/polly (region-scoped), ssm:GetParameter |

### `ecr`
| Resource | Description |
|----------|-------------|
| `aws_ecr_repository.proxy` | Private repo, scan on push, AES-256 encryption |
| `aws_ecr_lifecycle_policy.proxy` | Remove untagged after 1 day; keep last 10 tagged |

### `ecs`
| Resource | Description |
|----------|-------------|
| `aws_ecs_cluster.main` | Container Insights enabled |
| `aws_ecs_task_definition.proxy` | 0.5 vCPU / 1 GiB, ARM64, read-only FS, init process, 120 s stop |
| `aws_ecs_service.proxy` | 2 tasks, circuit breaker + rollback, no public IP, tags propagated |

### `dns`
| Resource | Description |
|----------|-------------|
| `aws_route53_record.site` | A alias → ALB DNS name |
| `aws_connect_approved_origin.site` | Registers `https://<hostname>` with the Connect instance |

---

## Teardown

```bash
cd terraform
terraform destroy
```

> **Note:** The ALB log S3 bucket has `force_destroy = false` (mirrors CDK
> `RemovalPolicy.RETAIN`). Empty it manually before running `terraform destroy`,
> or set `force_destroy = true` in `modules/alb/main.tf` if log retention is
> not required.


```
CDK → Terraform mapping (100% parity)
| CDK construct | Terraform resource | |---|---| | ec2.SecurityGroup (3×) | aws_security_group + aws_vpc_security_group_*_rule | | ec2.InterfaceVpcEndpoint (8×) | aws_vpc_endpoint (for_each map) | | s3.Bucket (ALB logs) | aws_s3_bucket + encryption + lifecycle + policy | | elbv2.ApplicationLoadBalancer | aws_lb + aws_lb_listener + aws_lb_target_group | | wafv2.CfnWebACL + association | aws_wafv2_web_acl + aws_wafv2_web_acl_association | | logs.LogGroup | aws_cloudwatch_log_group | | ssm.StringParameter (2×) | aws_ssm_parameter | | iam.Role (task + execution) | aws_iam_role + aws_iam_role_policy (inline) | | ecr.Repository | aws_ecr_repository + aws_ecr_lifecycle_policy | | ecs.Cluster | aws_ecs_cluster + aws_ecs_cluster_capacity_providers | | ecs.FargateTaskDefinition | aws_ecs_task_definition (jsonencode, ARM64) | | ecs.FargateService | aws_ecs_service (circuit breaker + rollback) | | route53.ARecord | aws_route53_record (alias) | | connect.ApprovedOrigin | aws_connect_approved_origin |
```

```
 How to deploy
# 1. Fill in your values
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# 2. Bootstrap ECR first
cd terraform && terraform init
terraform apply -target=module.ecr

# 3. Build and push the image
bash terraform/scripts/build-and-push.sh \
  --region us-east-1 --account 123456789012 --repo v2v-proxy --tag latest

# 4. Deploy everything
terraform apply
```