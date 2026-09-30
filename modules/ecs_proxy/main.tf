resource "aws_ecs_cluster" "proxy" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.name_prefix}-cluster"
  }
}

resource "aws_ecs_task_definition" "proxy" {
  family                   = "${var.name_prefix}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    merge(
      {
        name                   = "proxy"
        image                  = var.container_image
        essential              = true
        readonlyRootFilesystem = true
        linuxParameters = {
          initProcessEnabled = true
        }
        portMappings = [
          {
            containerPort = var.container_port
            hostPort      = var.container_port
            protocol      = "tcp"
          }
        ]
        environment = [
          { name = "AWS_REGION", value = var.aws_region },
          { name = "NODE_ENV", value = "production" },
          { name = "PORT", value = tostring(var.container_port) },
          { name = "COGNITO_DOMAIN_PREFIX", value = var.cognito_domain_prefix },
          { name = "COGNITO_APP_CLIENT_NAME", value = var.cognito_app_client_name },
          { name = "BEDROCK_MODEL_ID", value = var.bedrock_model_id },
          { name = "FALLBACK_RATE_LIMIT_PER_MINUTE", value = tostring(var.fallback_rate_limit_per_minute) },
          { name = "MAX_CONNECTIONS_PER_USER", value = tostring(var.max_connections_per_user) }
        ]
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = var.proxy_log_group_name
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "proxy"
          }
        }
        healthCheck = {
          command = [
            "CMD-SHELL",
            "node -e \"fetch('http://127.0.0.1:${var.container_port}${var.health_check_path}').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""
          ]
          interval    = 15
          timeout     = 5
          retries     = 3
          startPeriod = 20
        }
      },
      var.use_bootstrap_container ? {
        command = [
          "sh",
          "-c",
          "node -e \"const http=require('http');const port=Number(process.env.PORT||8080);http.createServer((req,res)=>{res.writeHead(req.url==='/healthz'?200:503,{'content-type':'application/json'});res.end(JSON.stringify(req.url==='/healthz'?{status:'ok',mode:'bootstrap'}:{error:'Proxy image has not been deployed'}));}).listen(port,'0.0.0.0');\""
        ]
      } : {}
    )
  ])

  tags = {
    Name = "${var.name_prefix}-task"
  }
}

resource "aws_ecs_service" "proxy" {
  name                   = "${var.name_prefix}-service"
  cluster                = aws_ecs_cluster.proxy.id
  task_definition        = aws_ecs_task_definition.proxy.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = false

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    assign_public_ip = false
    security_groups  = [var.service_security_group_id]
    subnets          = var.private_subnet_ids
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "proxy"
    container_port   = var.container_port
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = {
    Name = "${var.name_prefix}-service"
  }
}
