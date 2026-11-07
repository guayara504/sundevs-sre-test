terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

locals {
  function_name     = "${var.name}-processor"
  metrics_namespace = "SundevsSRE/Processor"
}

###############################################################################
# IAM: rol de ejecucion con minimo privilegio + permissions boundary
###############################################################################
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "processor" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

# ENIs en la VPC + escritura de logs.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.processor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "processor" {
  statement {
    sid       = "ResultsObjectsViaVpcEndpointOnly"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${var.bucket_arn}/results/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.s3_vpc_endpoint_id]
    }
  }

  statement {
    sid       = "ResultsTable"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [var.table_arn]
  }

  statement {
    sid       = "TracingAndMetrics"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.redis_enabled ? [1] : []
    content {
      sid       = "RedisIamAuth"
      actions   = ["elasticache:Connect"]
      resources = var.redis_connect_arns
    }
  }
}

resource "aws_iam_role_policy" "processor" {
  name   = "processor-least-privilege"
  role   = aws_iam_role.processor.id
  policy = data.aws_iam_policy_document.processor.json
}

###############################################################################
# Lambda
###############################################################################
resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "processor" {
  function_name = local.function_name
  description   = "Procesa POST /process con cache Redis (read-through), DynamoDB y S3"
  role          = aws_iam_role.processor.arn

  runtime       = "python3.12"
  architectures = ["arm64"] # Graviton: ~20% mas barato y mas eficiente
  handler       = "app.handler"
  memory_size   = var.memory_mb
  timeout       = var.timeout_seconds

  filename         = var.artifact_path
  source_code_hash = filebase64sha256(var.artifact_path)

  reserved_concurrent_executions = var.reserved_concurrency

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = {
      ENVIRONMENT        = var.environment
      RESULTS_BUCKET     = var.bucket_name
      RESULTS_TABLE      = var.table_name
      REDIS_ENABLED      = tostring(var.redis_enabled)
      REDIS_HOST         = var.redis_host
      REDIS_PORT         = tostring(var.redis_port)
      REDIS_USER_ID      = var.redis_user_id
      REDIS_CACHE_NAME   = var.redis_cache_name
      CACHE_TTL_SECONDS  = tostring(var.cache_ttl_seconds)
      METRICS_NAMESPACE  = local.metrics_namespace
      POWERTOOLS_SERVICE = "processor"
    }
  }

  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.processor.name
    application_log_level = "INFO"
    system_log_level      = "WARN"
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_access,
    aws_iam_role_policy.processor,
  ]
}

###############################################################################
# API Gateway HTTP API
###############################################################################
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.name}-http-api/access"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-http-api"
  protocol_type = "HTTP"
  description   = "Entrada publica al servicio de procesamiento"

  cors_configuration {
    allow_origins  = ["*"]
    allow_methods  = ["POST", "GET", "OPTIONS"]
    allow_headers  = ["content-type", "authorization", "x-request-id"]
    expose_headers = ["x-cache", "x-result-source", "x-request-id"]
    max_age        = 300
  }
}

resource "aws_apigatewayv2_integration" "processor" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.processor.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = (var.timeout_seconds * 1000) + 1000
}

resource "aws_apigatewayv2_route" "process" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /process"
  target    = "integrations/${aws_apigatewayv2_integration.processor.id}"
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.processor.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit    = var.throttle_rate_limit
    throttling_burst_limit   = var.throttle_burst_limit
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      userAgent          = "$context.identity.userAgent"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      protocol           = "$context.protocol"
      responseLength     = "$context.responseLength"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integrationLatency"
      integrationStatus  = "$context.integrationStatus"
      integrationError   = "$context.integrationErrorMessage"
      errorMessage       = "$context.error.message"
    })
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
