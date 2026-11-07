output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "function_name" {
  value = aws_lambda_function.processor.function_name
}

output "function_role_arn" {
  value = aws_iam_role.processor.arn
}

output "metrics_namespace" {
  value = local.metrics_namespace
}
