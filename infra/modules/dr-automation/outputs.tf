output "orchestrator_function_name" {
  value = aws_lambda_function.orchestrator.function_name
}

output "github_token_secret_arn" {
  value = aws_secretsmanager_secret.github_token.arn
}

output "notifications_topic_arn" {
  value = aws_sns_topic.notifications.arn
}

output "status_parameter" {
  value = aws_ssm_parameter.status.name
}
