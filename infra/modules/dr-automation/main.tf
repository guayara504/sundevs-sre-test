###############################################################################
# DR automatizado (vive en la REGION DR para sobrevivir a la caida primaria)
#
#   EventBridge (1 min) -> Lambda health-canary -> metrica PrimaryHealthy (EMF)
#   Alarma (3 de 3 minutos en 0) -> SNS dr-alarm -> Lambda dr-orchestrator
#   dr-orchestrator -> GitHub repository_dispatch "dr-failover"
#                   -> workflow dr.yml: terraform apply en la region DR
#                   -> SNS dr-notifications -> correo
###############################################################################
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_region" "current" {}

locals {
  metrics_namespace = "SundevsSRE/DR"
  status_parameter  = "/${var.project}/${var.environment}/dr/status"
}

# --- Topics -----------------------------------------------------------------
resource "aws_sns_topic" "alarm" {
  name = "${var.name}-dr-alarm"
}

resource "aws_sns_topic" "notifications" {
  name = "${var.name}-dr-notifications"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Estado e integracion con GitHub ----------------------------------------
resource "aws_ssm_parameter" "status" {
  name        = local.status_parameter
  description = "Estado del DR: STANDBY | FAILOVER_TRIGGERED:<timestamp>. Evita disparos duplicados."
  type        = "String"
  value       = "STANDBY"

  lifecycle {
    ignore_changes = [value]
  }
}

# Solo el contenedor del secreto: el valor (fine-grained PAT con permiso
# Contents:write sobre el repo) se carga fuera de Terraform para que nunca
# quede en el codigo ni en el estado.
resource "aws_secretsmanager_secret" "github_token" {
  name                    = "${var.name}-github-dispatch-token"
  description             = "Token de GitHub para disparar el workflow de DR (repository_dispatch)."
  recovery_window_in_days = 7
}

# --- IAM ----------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "canary" {
  name                 = "${var.name}-health-canary"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "canary_logs" {
  role       = aws_iam_role.canary.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "canary_xray" {
  role       = aws_iam_role.canary.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "orchestrator_xray" {
  role       = aws_iam_role.orchestrator.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role" "orchestrator" {
  name                 = "${var.name}-dr-orchestrator"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "orchestrator_logs" {
  role       = aws_iam_role.orchestrator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "orchestrator" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.github_token.arn]
  }
  statement {
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.status.arn]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]
  }
}

resource "aws_iam_role_policy" "orchestrator" {
  name   = "dr-orchestrator"
  role   = aws_iam_role.orchestrator.id
  policy = data.aws_iam_policy_document.orchestrator.json
}

# --- Lambda: health canary ----------------------------------------------------
resource "aws_cloudwatch_log_group" "canary" {
  name              = "/aws/lambda/${var.name}-health-canary"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "canary" {
  function_name    = "${var.name}-health-canary"
  description      = "Sondea ${var.primary_region} y publica la metrica PrimaryHealthy"
  role             = aws_iam_role.canary.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "app.handler"
  timeout          = 15
  memory_size      = 128
  filename         = "${var.artifacts_dir}/health_canary.zip"
  source_code_hash = filebase64sha256("${var.artifacts_dir}/health_canary.zip")

  environment {
    variables = {
      TARGET_URL        = var.primary_health_url
      METRICS_NAMESPACE = local.metrics_namespace
      ENVIRONMENT       = var.environment
      PRIMARY_REGION    = var.primary_region
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.canary.name
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy_attachment.canary_xray]
}

resource "aws_cloudwatch_event_rule" "canary" {
  name                = "${var.name}-health-canary"
  description         = "Sondeo de salud de la region primaria cada minuto"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "canary" {
  rule = aws_cloudwatch_event_rule.canary.name
  arn  = aws_lambda_function.canary.arn
}

resource "aws_lambda_permission" "canary" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.canary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.canary.arn
}

resource "aws_cloudwatch_metric_alarm" "primary_down" {
  alarm_name          = "${var.name}-primary-region-down"
  alarm_description   = "La region primaria ${var.primary_region} no responde /health durante 3 minutos consecutivos. Dispara el DR."
  namespace           = local.metrics_namespace
  metric_name         = "PrimaryHealthy"
  dimensions          = { Environment = var.environment, PrimaryRegion = var.primary_region }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # Sin datos = el canary no corrio: no se decide un failover a ciegas.
  treat_missing_data = "missing"
  alarm_actions      = [aws_sns_topic.alarm.arn, aws_sns_topic.notifications.arn]
  ok_actions         = [aws_sns_topic.notifications.arn]
}

# --- Lambda: orquestador de DR --------------------------------------------------
resource "aws_cloudwatch_log_group" "orchestrator" {
  name              = "/aws/lambda/${var.name}-dr-orchestrator"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "orchestrator" {
  function_name    = "${var.name}-dr-orchestrator"
  description      = "Recibe la alarma de caida y dispara el workflow de restauracion en ${data.aws_region.current.region}"
  role             = aws_iam_role.orchestrator.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "app.handler"
  timeout          = 30
  memory_size      = 128
  filename         = "${var.artifacts_dir}/dr_orchestrator.zip"
  source_code_hash = filebase64sha256("${var.artifacts_dir}/dr_orchestrator.zip")

  # La idempotencia la da el parametro SSM de estado (escritura condicional en
  # el codigo). No se reserva concurrencia: la cuota de la cuenta es 10 y AWS
  # exige mantener 10 sin reservar.
  environment {
    variables = {
      GITHUB_REPOSITORY = var.repository
      TOKEN_SECRET_ID   = aws_secretsmanager_secret.github_token.arn
      STATUS_PARAMETER  = aws_ssm_parameter.status.name
      NOTIFY_TOPIC_ARN  = aws_sns_topic.notifications.arn
      AUTO_FAILOVER     = tostring(var.auto_failover)
      PRIMARY_REGION    = var.primary_region
      DR_REGION         = data.aws_region.current.region
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.orchestrator.name
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.orchestrator, aws_iam_role_policy_attachment.orchestrator_xray]
}

resource "aws_sns_topic_subscription" "orchestrator" {
  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.orchestrator.arn
}

resource "aws_lambda_permission" "orchestrator" {
  statement_id  = "AllowSnsAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orchestrator.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarm.arn
}
