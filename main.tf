locals {
#  # Network
#  private_subnet_ids = coalescelist(module.vpc.private_subnets, var.private_subnet_ids, [""])
#  public_subnet_ids  = coalescelist(module.vpc.public_subnets, var.public_subnet_ids, [""])

  # Atlantis
  atlantis_image = var.atlantis_image == "" ? "ghcr.io/runatlantis/atlantis:${var.atlantis_version}" : var.atlantis_image
  atlantis_host = coalesce(
    var.atlantis_fqdn,
    element(concat(aws_route53_record.atlantis[*].fqdn, [""]), 0),
    var.alb_dns_name,
    "_"
  )
  atlantis_url = "https://${local.atlantis_host}"
  atlantis_url_events = "${local.atlantis_url}/events"

  # Include only one group of secrets - for github, github app,  gitlab or bitbucket
  has_secrets = try(coalesce(var.atlantis_gitlab_user_token, var.atlantis_github_user_token, var.atlantis_github_app_key, var.atlantis_bitbucket_user_token) != "", false)

  # token/key
  secret_name_key        = local.has_secrets ? var.atlantis_gitlab_user_token != "" ? "ATLANTIS_GITLAB_TOKEN" : var.atlantis_github_user_token != "" ? "ATLANTIS_GH_TOKEN" : var.atlantis_github_app_key != "" ? "ATLANTIS_GH_APP_KEY" : "ATLANTIS_BITBUCKET_TOKEN" : ""
  secret_name_value_from = local.has_secrets ? var.atlantis_gitlab_user_token != "" ? var.atlantis_gitlab_user_token_ssm_parameter_name : var.atlantis_github_user_token != "" ? var.atlantis_github_user_token_ssm_parameter_name : var.atlantis_github_app_key != "" ? var.atlantis_github_app_key_ssm_parameter_name : var.atlantis_bitbucket_user_token_ssm_parameter_name : ""

  # webhook
  secret_webhook_key = local.has_secrets || var.atlantis_github_webhook_secret != "" ? var.atlantis_gitlab_user_token != "" ? "ATLANTIS_GITLAB_WEBHOOK_SECRET" : var.atlantis_github_user_token != "" || var.atlantis_github_webhook_secret != "" ? "ATLANTIS_GH_WEBHOOK_SECRET" : var.atlantis_github_app_key != "" || var.atlantis_github_webhook_secret != "" ? "ATLANTIS_GH_WEBHOOK_SECRET" : "ATLANTIS_BITBUCKET_WEBHOOK_SECRET" : ""

  # ECS - existing or new?
  ecs_cluster_id = var.ecs_cluster_id

  # Container definitions
  container_definitions = var.custom_container_definitions == "" ? var.atlantis_bitbucket_user_token != "" ? jsonencode(concat([module.container_definition_bitbucket.json_map_object], var.extra_container_definitions)) : jsonencode(concat([module.container_definition_github_gitlab.json_map_object], var.extra_container_definitions)) : var.custom_container_definitions

  container_definition_environment = [
    {
      name  = "ATLANTIS_ALLOW_REPO_CONFIG"
      value = var.allow_repo_config
    },
    {
      name  = "ATLANTIS_GITLAB_HOSTNAME"
      value = var.atlantis_gitlab_hostname
    },
    {
      name  = "ATLANTIS_LOG_LEVEL"
      value = var.atlantis_log_level
    },
    {
      name  = "ATLANTIS_PORT"
      value = var.atlantis_port
    },
    {
      name  = "ATLANTIS_ATLANTIS_URL"
      value = local.atlantis_url
    },
    {
      name  = "ATLANTIS_GH_USER"
      value = var.atlantis_github_user
    },
    {
      name  = "ATLANTIS_GITLAB_USER"
      value = var.atlantis_gitlab_user
    },
    {
      name  = "ATLANTIS_BITBUCKET_USER"
      value = var.atlantis_bitbucket_user
    },
    {
      name  = "ATLANTIS_BITBUCKET_BASE_URL"
      value = var.atlantis_bitbucket_base_url
    },
    {
      name  = "ATLANTIS_REPO_ALLOWLIST"
      value = join(",", var.atlantis_repo_allowlist)
    },
    {
      name  = "ATLANTIS_HIDE_PREV_PLAN_COMMENTS"
      value = var.atlantis_hide_prev_plan_comments
    },
    {
      name  = "ATLANTIS_GH_APP_ID"
      value = var.atlantis_github_app_id
    },
    {
      name  = "ATLANTIS_WRITE_GIT_CREDS"
      value = var.atlantis_write_git_creds
    }
  ]

  # ECS task definition
  latest_task_definition_rev = var.external_task_definition_updates ? max(aws_ecs_task_definition.atlantis.revision, data.aws_ecs_task_definition.atlantis[0].revision) : aws_ecs_task_definition.atlantis.revision

  # Secret access tokens
  container_definition_secrets_1 = local.secret_name_key != "" && local.secret_name_value_from != "" ? [
    {
      name      = local.secret_name_key
      valueFrom = local.secret_name_value_from
    },
  ] : []

  # Webhook secrets are not supported by BitBucket
  container_definition_secrets_2 = local.secret_webhook_key != "" ? [
    {
      name      = local.secret_webhook_key
      valueFrom = var.webhook_ssm_parameter_name
    },
  ] : []

  tags = merge(
    {
      "Name" = var.name
    },
    var.tags,
  )

  policies_arn = var.policies_arn != null ? var.policies_arn : ["arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]

  # break up user to uid and gid -- set both to 0 if null
  uid = var.user == null ? 0 : split(":", var.user)[0]
  gid = var.user == null ? 0 : split(":", var.user)[1]

  # default mount points for efs if ephemeral storage is not enabled and mount points aren't specified
  mount_points = var.enable_ephemeral_storage || length(var.mount_points) > 0 ? var.mount_points : [{
    containerPath = "/home/atlantis"
    sourceVolume  = "efs-storage"
    readOnly      = "false"
  }]

  # Chunk whitelisted CIDRs into groups of 5, the limit for IPs in an AWS lb listener
  whitelist_unauthenticated_cidr_block_chunks = chunklist(
    sort(compact(concat(var.allow_github_webhooks ? var.github_webhooks_cidr_blocks : [], var.whitelist_unauthenticated_cidr_blocks))),
    5
  )
}

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_route53_zone" "this" {
  count = var.create_route53_record || var.create_route53_aaaa_record ? 1 : 0

  name         = var.route53_zone_name
  private_zone = var.route53_private_zone
}

################################################################################
# Secret for webhook
################################################################################
resource "random_id" "webhook" {
  count = var.atlantis_github_webhook_secret != "" ? 0 : 1

  byte_length = "64"
}

resource "aws_ssm_parameter" "webhook" {
  count = var.atlantis_bitbucket_user_token != "" ? 0 : 1

  name  = var.webhook_ssm_parameter_name
  type  = "SecureString"
  value = coalesce(var.atlantis_github_webhook_secret, join("", random_id.webhook[*].hex))

  tags = local.tags
}

resource "aws_ssm_parameter" "atlantis_github_user_token" {
  count = var.atlantis_github_user_token != "" ? 1 : 0

  name  = var.atlantis_github_user_token_ssm_parameter_name
  type  = "SecureString"
  value = var.atlantis_github_user_token

  tags = local.tags
}

resource "aws_ssm_parameter" "atlantis_gitlab_user_token" {
  count = var.atlantis_gitlab_user_token != "" ? 1 : 0

  name  = var.atlantis_gitlab_user_token_ssm_parameter_name
  type  = "SecureString"
  value = var.atlantis_gitlab_user_token

  tags = local.tags
}

resource "aws_ssm_parameter" "atlantis_bitbucket_user_token" {
  count = var.atlantis_bitbucket_user_token != "" ? 1 : 0

  name  = var.atlantis_bitbucket_user_token_ssm_parameter_name
  type  = "SecureString"
  value = var.atlantis_bitbucket_user_token

  tags = local.tags
}

resource "aws_ssm_parameter" "atlantis_github_app_key" {
  count = var.atlantis_github_app_key != "" ? 1 : 0

  name  = var.atlantis_github_app_key_ssm_parameter_name
  type  = "SecureString"
  value = var.atlantis_github_app_key

  tags = local.tags
}

module "atlantis_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "v4.3.0"

  name        = var.name
  vpc_id      = var.vpc_id
  description = "Security group with open port for Atlantis (${var.atlantis_port}) from ALB, egress ports are all world open"

  ingress_with_source_security_group_id = [
    {
      from_port                = var.atlantis_port
      to_port                  = var.atlantis_port
      protocol                 = "tcp"
      description              = "Atlantis"
      source_security_group_id = var.alb_security_group_id
    },
  ]

  egress_rules = ["all-all"]

  tags = merge(local.tags, var.atlantis_security_group_tags)
}

module "efs_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "v4.8.0"
  count   = var.enable_ephemeral_storage ? 0 : 1

  name        = "${var.name}-efs"
  vpc_id      = var.vpc_id
  description = "Security group allowing access to the EFS storage"

  ingress_with_source_security_group_id = [{
    rule                     = "nfs-tcp",
    source_security_group_id = module.atlantis_sg.security_group_id
  }]

  tags = local.tags
}

################################################################################
# Route53 records
################################################################################
resource "aws_route53_record" "atlantis" {
  count = var.create_route53_record ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.route53_record_name != null ? var.route53_record_name : var.name
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "atlantis_aaaa" {
  count = var.create_route53_aaaa_record ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.route53_record_name != null ? var.route53_record_name : var.name
  type    = "AAAA"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

################################################################################
# EFS
################################################################################

resource "aws_efs_file_system" "this" {
  count = var.enable_ephemeral_storage ? 0 : 1

  creation_token = coalesce(var.efs_file_system_token, var.name)

  throughput_mode                 = var.efs_throughput_mode
  provisioned_throughput_in_mibps = var.efs_provisioned_throughput_in_mibps

  encrypted = var.efs_file_system_encrypted
}

resource "aws_efs_mount_target" "this" {
  for_each = {
    for k, v in zipmap(coalescelist(var.private_subnets, [""]), var.private_subnets) : k => v
    if var.enable_ephemeral_storage == false
  }

  file_system_id  = aws_efs_file_system.this[0].id
  subnet_id       = each.value
  security_groups = [module.efs_sg[0].security_group_id, module.atlantis_sg.security_group_id]
}

resource "aws_efs_access_point" "this" {
  count = var.enable_ephemeral_storage ? 0 : 1

  file_system_id = aws_efs_file_system.this[0].id
  posix_user {
    gid = local.gid
    uid = local.uid
  }

  root_directory {
    path = "/home/atlantis"
    creation_info {
      owner_gid   = local.gid
      owner_uid   = local.uid
      permissions = 0750
    }
  }
}


## ECS tasks IAM
data "aws_iam_policy_document" "ecs_tasks" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = compact(distinct(concat(["ecs-tasks.amazonaws.com"], var.trusted_principals)))
    }

    dynamic "principals" {
      for_each = length(var.trusted_entities) > 0 ? [true] : []

      content {
        type        = "AWS"
        identifiers = var.trusted_entities
      }
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name                 = "${var.name}-ecs_task_execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary
  path                 = var.path

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  for_each = toset(local.policies_arn)

  role       = aws_iam_role.ecs_task_execution.id
  policy_arn = each.value
}

# ref: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data.html
data "aws_iam_policy_document" "ecs_task_access_secrets" {
  statement {
    effect = "Allow"

    resources = flatten([
      aws_ssm_parameter.webhook[*].arn,
      aws_ssm_parameter.atlantis_github_user_token[*].arn,
      aws_ssm_parameter.atlantis_gitlab_user_token[*].arn,
      aws_ssm_parameter.atlantis_bitbucket_user_token[*].arn,
      aws_ssm_parameter.atlantis_github_app_key[*].arn,
      try(var.repository_credentials["credentialsParameter"], [])
    ])

    actions = [
      "ssm:GetParameters",
      "secretsmanager:GetSecretValue",
    ]
  }
}

data "aws_iam_policy_document" "ecs_task_access_secrets_with_kms" {
  count = var.ssm_kms_key_arn == "" ? 0 : 1

  source_policy_documents = [
    data.aws_iam_policy_document.ecs_task_access_secrets.json
  ]

  statement {
    sid       = "AllowKMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.ssm_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "ecs_task_access_secrets" {
  count = local.has_secrets ? 1 : 0

  name = "ECSTaskAccessSecretsPolicy"

  role = aws_iam_role.ecs_task_execution.id

  policy = element(
    compact(
      concat(
        data.aws_iam_policy_document.ecs_task_access_secrets_with_kms[*].json,
        data.aws_iam_policy_document.ecs_task_access_secrets[*].json,
      ),
    ),
    0,
  )
}

module "container_definition_github_gitlab" {
  source  = "cloudposse/ecs-container-definition/aws"
  version = "v0.58.1"

  container_name  = var.name
  container_image = local.atlantis_image

  container_cpu                = var.container_cpu != null ? var.container_cpu : var.ecs_task_cpu
  container_memory             = var.container_memory != null ? var.container_memory : var.ecs_task_memory
  container_memory_reservation = var.container_memory_reservation

  user                     = var.user
  ulimits                  = var.ulimits
  entrypoint               = var.entrypoint
  command                  = var.command
  working_directory        = var.working_directory
  repository_credentials   = var.repository_credentials
  docker_labels            = var.docker_labels
  start_timeout            = var.start_timeout
  stop_timeout             = var.stop_timeout
  container_depends_on     = var.container_depends_on
  essential                = var.essential
  readonly_root_filesystem = var.readonly_root_filesystem
  mount_points             = local.mount_points
  volumes_from             = var.volumes_from

  port_mappings = [
    {
      containerPort = var.atlantis_port
      hostPort      = var.atlantis_port
      protocol      = "tcp"
    },
  ]

  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-region        = data.aws_region.current.name
      awslogs-group         = aws_cloudwatch_log_group.atlantis.name
      awslogs-stream-prefix = "ecs"
    }
    secretOptions = []
  }
  firelens_configuration = var.firelens_configuration

  environment = concat(
    local.container_definition_environment,
    var.custom_environment_variables,
  )

  secrets = concat(
    local.container_definition_secrets_1,
    local.container_definition_secrets_2,
    var.custom_environment_secrets,
  )
}

module "container_definition_bitbucket" {
  source  = "cloudposse/ecs-container-definition/aws"
  version = "v0.58.1"

  container_name  = var.name
  container_image = local.atlantis_image

  container_cpu                = var.container_cpu != null ? var.container_cpu : var.ecs_task_cpu
  container_memory             = var.container_memory != null ? var.container_memory : var.ecs_task_memory
  container_memory_reservation = var.container_memory_reservation

  user                     = var.user
  ulimits                  = var.ulimits
  entrypoint               = var.entrypoint
  command                  = var.command
  working_directory        = var.working_directory
  repository_credentials   = var.repository_credentials
  docker_labels            = var.docker_labels
  start_timeout            = var.start_timeout
  stop_timeout             = var.stop_timeout
  container_depends_on     = var.container_depends_on
  essential                = var.essential
  readonly_root_filesystem = var.readonly_root_filesystem
  mount_points             = var.mount_points
  volumes_from             = var.volumes_from

  port_mappings = [
    {
      containerPort = var.atlantis_port
      hostPort      = var.atlantis_port
      protocol      = "tcp"
    },
  ]

  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-region        = data.aws_region.current.name
      awslogs-group         = aws_cloudwatch_log_group.atlantis.name
      awslogs-stream-prefix = "ecs"
    }
    secretOptions = []
  }
  firelens_configuration = var.firelens_configuration

  environment = concat(
    local.container_definition_environment,
    var.custom_environment_variables,
  )

  secrets = concat(
    local.container_definition_secrets_1,
    var.custom_environment_secrets,
  )
}

resource "aws_ecs_task_definition" "atlantis" {
  family                   = var.name
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_execution.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory

  container_definitions = local.container_definitions

  dynamic "runtime_platform" {
    for_each = var.runtime_platform != null ? [var.runtime_platform] : []

    content {
      operating_system_family = try(runtime_platform.value.operating_system_family, null)
      cpu_architecture        = try(runtime_platform.value.cpu_architecture, null)
    }
  }

  dynamic "ephemeral_storage" {
    for_each = var.enable_ephemeral_storage ? [1] : []

    content {
      size_in_gib = var.ephemeral_storage_size
    }
  }

  dynamic "volume" {
    for_each = var.enable_ephemeral_storage ? [] : [1]

    content {
      name = "efs-storage"
      efs_volume_configuration {
        file_system_id          = aws_efs_file_system.this[0].id
        transit_encryption      = "ENABLED"
        transit_encryption_port = 2999
        authorization_config {
          access_point_id = aws_efs_access_point.this[0].id
          iam             = "ENABLED"
        }
      }
    }
  }

  tags = local.tags
}

data "aws_ecs_task_definition" "atlantis" {
  count = var.external_task_definition_updates ? 1 : 0

  task_definition = var.name

  depends_on = [aws_ecs_task_definition.atlantis]
}

resource "aws_lb_listener_rule" "example" {
  listener_arn = var.alb_listener_arn

  condition {
    host_header {
      values = [local.atlantis_host]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.atlantis_service_target_group.arn
  }
}

resource "aws_lb_target_group" "atlantis_service_target_group" {
  name     = var.name
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  target_type = "ip"
}

# Forward action for certain CIDR blocks to bypass authentication (eg. GitHub webhooks)
resource "aws_lb_listener_rule" "unauthenticated_access_for_cidr_blocks" {
  count = var.allow_unauthenticated_access ? length(local.whitelist_unauthenticated_cidr_block_chunks) : 0

  listener_arn = var.alb_listener_arn
  priority     = var.allow_unauthenticated_access_priority + count.index

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.atlantis_service_target_group.arn
  }

  condition {
    source_ip {
      values = local.whitelist_unauthenticated_cidr_block_chunks[count.index]
    }
  }
}

# Forward action for certain URL paths to bypass authentication (eg. GitHub webhooks)
resource "aws_lb_listener_rule" "unauthenticated_access_for_webhook" {
  count = var.allow_unauthenticated_access && var.allow_github_webhooks ? 1 : 0

  listener_arn = var.alb_listener_arn
  priority     = var.allow_unauthenticated_webhook_access_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.atlantis_service_target_group.arn
  }

  condition {
    path_pattern {
      values = ["/events"]
    }
  }
}

resource "aws_ecs_service" "atlantis" {
  name    = var.name
  cluster = local.ecs_cluster_id

  task_definition                    = "${var.name}:${local.latest_task_definition_rev}"
  desired_count                      = var.ecs_service_desired_count
  launch_type                        = var.ecs_fargate_spot ? null : "FARGATE"
  platform_version                   = var.ecs_service_platform_version
  deployment_maximum_percent         = var.ecs_service_deployment_maximum_percent
  deployment_minimum_healthy_percent = var.ecs_service_deployment_minimum_healthy_percent
  force_new_deployment               = var.ecs_service_force_new_deployment
  enable_execute_command             = var.ecs_service_enable_execute_command

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [module.atlantis_sg.security_group_id]
    assign_public_ip = var.ecs_service_assign_public_ip
  }

  load_balancer {
    container_name   = var.name
    container_port   = var.atlantis_port
    target_group_arn = aws_lb_target_group.atlantis_service_target_group.arn
  }

  dynamic "load_balancer" {
    for_each = var.extra_load_balancers
    content {
      container_name   = load_balancer.value["container_name"]
      container_port   = load_balancer.value["container_port"]
      target_group_arn = load_balancer.value["target_group_arn"]
    }
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.ecs_fargate_spot ? [true] : []

    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 100
    }
  }

  enable_ecs_managed_tags = var.enable_ecs_managed_tags
  propagate_tags          = var.propagate_tags

  tags = var.use_ecs_old_arn_format ? null : local.tags
}

################################################################################
# Cloudwatch logs
################################################################################
resource "aws_cloudwatch_log_group" "atlantis" {
  name              = var.name
  retention_in_days = var.cloudwatch_log_retention_in_days
  kms_key_id        = var.cloudwatch_logs_kms_key_id

  tags = local.tags
}
