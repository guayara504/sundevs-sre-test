output "api_endpoint" {
  description = "URL base de la API (POST /process, GET /health)."
  value       = module.service.api_endpoint
}

output "function_name" {
  value = module.service.function_name
}

output "results_bucket" {
  value = module.data.bucket_name
}

output "results_table" {
  value = module.data.table_name
}

output "redis_enabled" {
  value = var.enable_redis
}

output "redis_endpoint" {
  value = var.enable_redis ? module.cache[0].primary_endpoint : null
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "s3_vpc_endpoint_id" {
  value = module.network.s3_vpc_endpoint_id
}

output "alerts_topic_arn" {
  value = module.observability.alerts_topic_arn
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${module.observability.dashboard_name}"
}

output "dr_orchestrator_function" {
  value = local.create_dr ? module.dr_automation[0].orchestrator_function_name : null
}

output "dr_github_token_secret_arn" {
  value = local.create_dr ? module.dr_automation[0].github_token_secret_arn : null
}
