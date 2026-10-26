################################################################################
# ECS Module
# Creates:
#   • ECS Cluster          (Container Insights enabled)
#   • Fargate Task Definition  (512 CPU / 1024 MiB, ARM64, read-only root FS,
#                               init process, non-blocking logs, 120 s stop)
#   • Fargate Service      (2 tasks, circuit breaker + rollback, no public IP,
#                           tags propagated from service to tasks)
#
# Mirrors CDK: PrivatePocStack > ProxyCluster + ProxyTaskDef + ProxyService
################################################################################

locals {
  container_name = "proxy"
  container_port = 8080
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.stack_name}-cluster"

  # Container Insights V2 (enhanced) — CDK: containerInsightsV2: ENABLED
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.stack_name}-cluster"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# ── Fargate Task Definition ───────────────────────────────────────────────────

resource "aws_ecs_task_definition" "proxy" {
  family                   = "${var.stack_name}-proxy"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512  # CDK: 0.5 vCPU
  memory                   = 1024 # CDK: 1 GiB
  task_role_arn            = var.task_role_arn
  execution_role_arn       = var.execution_role_arn

  # ARM64 (Graviton) — CDK: RuntimePlatform.LINUX_ARM64
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.container_image_uri
      essential = true

      portMappings = [
        {
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      # Read-only root filesystem — writeable paths are tmpfs mounts if needed
      readonlyRootFilesystem = true

      # Docker init process as PID 1 prevents zombie processes
      linuxParameters = {
        initProcessEnabled = true
      }

      # Graceful shutdown: ECS sends SIGTERM and waits up to 120 s before SIGKILL.
      # The proxy uses DRAIN_TIMEOUT_MS=100000 to finish in-flight sessions.
      stopTimeout = 120

      environment = var.container_environment

      # Non-blocking log driver so a CloudWatch hiccup cannot stall the audio pipeline
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "proxy"
          "mode"                  = "non-blocking"
          "max-buffer-size"       = "25m" # CDK: cdk.Size.mebibytes(25)
        }
      }

      # Container health check — matches CDK healthCheck block
      healthCheck = {
        # Uses the Node.js built-in fetch() available in Node 18+
        command = [
          "CMD", "node", "-e",
          "fetch('http://127.0.0.1:${local.container_port}/healthz').then((r)=>process.exit(r.ok?0:1),()=>process.exit(1))"
        ]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    }
  ])

  tags = {
    Name = "${var.stack_name}-proxy-task"
  }
}

# ── Fargate Service ───────────────────────────────────────────────────────────

resource "aws_ecs_service" "proxy" {
  name            = "${var.stack_name}-proxy-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.proxy.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  # Rolling update settings — CDK: minHealthyPercent=100, maxHealthyPercent=200
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Circuit breaker with automatic rollback on deployment failure
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.service_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  # Propagate the service tags to every task so CloudWatch Insights queries can
  # filter by stack — CDK: propagateTags: PropagatedTagSource.SERVICE
  propagate_tags = "SERVICE"

  # Allow the ALB health checks to warm up before ECS considers the task healthy
  health_check_grace_period_seconds = 30

  # Prevent Terraform from cycling tasks on every container_definitions change
  # unless the task definition ARN actually changes (new revision).
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = {
    Name = "${var.stack_name}-proxy-service"
  }

  depends_on = [aws_ecs_cluster.main]
}
