terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

resource "aws_elasticache_subnet_group" "this" {
  name        = "${var.name}-redis"
  description = "Subnets privadas para Redis"
  subnet_ids  = var.subnet_ids
}

# --- Autenticacion ----------------------------------------------------------
# RBAC con autenticacion IAM: la Lambda firma un token SigV4 con su propio rol
# (sin red, sin secretos que rotar). El usuario "default" queda deshabilitado.
resource "aws_elasticache_user" "default" {
  user_id       = "${var.name}-default"
  user_name     = "default"
  engine        = "redis"
  access_string = "off ~* -@all"

  authentication_mode {
    type = "no-password-required"
  }
}

resource "aws_elasticache_user" "app" {
  # Con IAM, user_id y user_name deben ser identicos.
  user_id       = "${var.name}-app"
  user_name     = "${var.name}-app"
  engine        = "redis"
  access_string = "on ~* -@all +get +set +ping +ttl +exists"

  authentication_mode {
    type = "iam"
  }
}

resource "aws_elasticache_user_group" "this" {
  user_group_id = "${var.name}-users"
  engine        = "redis"
  user_ids      = [aws_elasticache_user.default.user_id, aws_elasticache_user.app.user_id]
}

# --- Logs -------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "slow_log" {
  name              = "/aws/elasticache/${var.name}/slow-log"
  retention_in_days = var.log_retention_days
}

# --- Cluster ----------------------------------------------------------------
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "Cache de lectura para ${var.name} (TTL obligatorio en todas las keys)"

  engine               = "redis"
  engine_version       = var.engine_version
  parameter_group_name = "default.redis7"
  node_type            = var.node_type
  port                 = 6379

  num_cache_clusters         = var.num_nodes
  automatic_failover_enabled = var.num_nodes > 1
  multi_az_enabled           = var.num_nodes > 1

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.security_group_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  user_group_ids             = [aws_elasticache_user_group.this.user_group_id]

  # Es una cache: no se respalda (la fuente de verdad es DynamoDB/S3).
  snapshot_retention_limit   = 0
  auto_minor_version_upgrade = true
  maintenance_window         = "sun:07:00-sun:08:00"
  apply_immediately          = true

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.slow_log.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }
}
