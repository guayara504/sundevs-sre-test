terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_region" "current" {}

###############################################################################
# Notificaciones: SNS -> correo (la suscripcion se confirma desde el email)
###############################################################################
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  actions = [aws_sns_topic.alerts.arn]

  # Alarmas "estandar": metrica unica, accion de alarma y de recuperacion.
  alarms = merge(
    {
      lambda-errors = {
        description = "La Lambda processor registra errores (respuestas 500)."
        namespace   = "AWS/Lambda"
        metric      = "Errors"
        stat        = "Sum"
        threshold   = 0
        periods     = 1
        dimensions  = { FunctionName = var.function_name }
      }
      lambda-throttles = {
        description = "La Lambda processor esta siendo throttled (concurrencia agotada)."
        namespace   = "AWS/Lambda"
        metric      = "Throttles"
        stat        = "Sum"
        threshold   = 0
        periods     = 1
        dimensions  = { FunctionName = var.function_name }
      }
      lambda-duration-p95 = {
        description = "La duracion p95 de la Lambda supera el 80% del timeout."
        namespace   = "AWS/Lambda"
        metric      = "Duration"
        stat        = "p95"
        threshold   = var.lambda_timeout_ms * 0.8
        periods     = 2
        dimensions  = { FunctionName = var.function_name }
      }
      api-5xx = {
        description = "API Gateway devuelve errores 5xx."
        namespace   = "AWS/ApiGateway"
        metric      = "5xx"
        stat        = "Sum"
        threshold   = var.api_5xx_threshold - 1
        periods     = 1
        dimensions  = { ApiId = var.api_id, Stage = "$default" }
      }
      api-latency-p95 = {
        description = "Latencia p95 de la API por encima del objetivo."
        namespace   = "AWS/ApiGateway"
        metric      = "Latency"
        stat        = "p95"
        threshold   = var.latency_p95_ms_limit
        periods     = 3
        dimensions  = { ApiId = var.api_id, Stage = "$default" }
      }
      cache-degraded = {
        description = "La Lambda no pudo usar Redis (opera en modo degradado leyendo de DynamoDB)."
        namespace   = var.metrics_namespace
        metric      = "CacheErrors"
        stat        = "Sum"
        threshold   = 0
        periods     = 1
        dimensions  = { Environment = var.environment, Service = "processor" }
      }
      dynamodb-throttles = {
        description = "DynamoDB rechaza escrituras por throttling."
        namespace   = "AWS/DynamoDB"
        metric      = "WriteThrottleEvents"
        stat        = "Sum"
        threshold   = 0
        periods     = 1
        dimensions  = { TableName = var.table_name }
      }
    },
    var.nat_gateway_enabled ? {
      nat-port-allocation-errors = {
        description = "El NAT Gateway no puede asignar puertos (agotamiento de conexiones)."
        namespace   = "AWS/NATGateway"
        metric      = "ErrorPortAllocation"
        stat        = "Sum"
        threshold   = 0
        periods     = 1
        dimensions  = { NatGatewayId = var.nat_gateway_id }
      }
    } : {},
    merge([
      for id in var.redis_cluster_ids : {
        "redis-cpu-${id}" = {
          description = "CPU del motor Redis ${id} alta."
          namespace   = "AWS/ElastiCache"
          metric      = "EngineCPUUtilization"
          stat        = "Average"
          threshold   = 75
          periods     = 3
          dimensions  = { CacheClusterId = id }
        }
        "redis-memory-${id}" = {
          description = "Uso de memoria de Redis ${id} alto (riesgo de evicciones)."
          namespace   = "AWS/ElastiCache"
          metric      = "DatabaseMemoryUsagePercentage"
          stat        = "Average"
          threshold   = 80
          periods     = 3
          dimensions  = { CacheClusterId = id }
        }
      }
    ]...)
  )
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dimensions
  statistic           = startswith(each.value.stat, "p") ? null : each.value.stat
  extended_statistic  = startswith(each.value.stat, "p") ? each.value.stat : null
  period              = 60
  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

###############################################################################
# Dashboard operativo (golden signals + cache)
###############################################################################
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "API - trafico y errores"
          region = data.aws_region.current.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", var.api_id, "Stage", "$default"],
            [".", "4xx", ".", ".", ".", "."],
            [".", "5xx", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "API - latencia"
          region = data.aws_region.current.region
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, "Stage", "$default", { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["AWS/ApiGateway", "IntegrationLatency", "ApiId", var.api_id, "Stage", "$default", { stat = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Cache - HIT vs MISS"
          region = data.aws_region.current.region
          stat   = "Sum"
          period = 60
          metrics = [
            [var.metrics_namespace, "CacheHit", "Environment", var.environment, "Service", "processor"],
            [".", "CacheMiss", ".", ".", ".", "."],
            [".", "CacheErrors", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Lambda"
          region = data.aws_region.current.region
          period = 60
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.function_name, { stat = "Sum" }],
            [".", "Errors", ".", ".", { stat = "Sum" }],
            [".", "Throttles", ".", ".", { stat = "Sum" }],
            [".", "Duration", ".", ".", { stat = "p95" }],
          ]
        }
      },
    ]
  })
}
