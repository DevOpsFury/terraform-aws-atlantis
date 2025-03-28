# Atlantis
output "atlantis_url" {
  description = "URL of Atlantis"
  value       = local.atlantis_url
}

output "atlantis_url_events" {
  description = "Webhook events URL of Atlantis"
  value       = local.atlantis_url_events
}

output "atlantis_repo_allowlist" {
  description = "Git repositories where webhook should be created"
  value       = var.atlantis_repo_allowlist
}

output "webhook_secret" {
  description = "Webhook secret"
  value       = try(random_id.webhook[0].hex, "")
  sensitive   = true
}

# ECS
output "task_role_arn" {
  description = "The Atlantis ECS task role arn"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "task_role_id" {
  description = "The Atlantis ECS task role id"
  value       = aws_iam_role.ecs_task_execution.id
}

output "task_role_name" {
  description = "The Atlantis ECS task role name"
  value       = aws_iam_role.ecs_task_execution.name
}

output "task_role_unique_id" {
  description = "The stable and unique string identifying the Atlantis ECS task role."
  value       = aws_iam_role.ecs_task_execution.unique_id
}

output "ecs_task_definition" {
  description = "Task definition for ECS service (used for external triggers)"
  value       = aws_ecs_service.atlantis.task_definition
}

output "ecs_security_group" {
  description = "Security group assigned to ECS Service in network configuration"
  value       = module.atlantis_sg.security_group_id
}

output "ecs_cluster_id" {
  description = "ECS cluster id"
  value       = local.ecs_cluster_id
}
