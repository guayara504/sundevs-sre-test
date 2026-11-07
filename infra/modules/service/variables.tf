variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "role_name" {
  type = string
}

variable "permissions_boundary_arn" {
  type = string
}

variable "artifact_path" {
  description = "Zip construido por scripts/build_lambda.py (mismo artefacto en plan y apply)."
  type        = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "bucket_name" {
  type = string
}

variable "bucket_arn" {
  type = string
}

variable "table_name" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "s3_vpc_endpoint_id" {
  type = string
}

variable "redis_enabled" {
  type = bool
}

variable "redis_host" {
  type = string
}

variable "redis_port" {
  type = number
}

variable "redis_user_id" {
  type = string
}

variable "redis_cache_name" {
  type = string
}

variable "redis_connect_arns" {
  type = list(string)
}

variable "cache_ttl_seconds" {
  type = number
}

variable "memory_mb" {
  type = number
}

variable "timeout_seconds" {
  type = number
}

variable "reserved_concurrency" {
  type = number
}

variable "throttle_rate_limit" {
  type = number
}

variable "throttle_burst_limit" {
  type = number
}

variable "log_retention_days" {
  type = number
}
