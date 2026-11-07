variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "enable_nat_gateway" {
  type = bool
}

variable "enable_flow_logs" {
  type = bool
}

variable "log_retention_days" {
  type = number
}

variable "bucket_name" {
  description = "Unico bucket alcanzable a traves del endpoint S3."
  type        = string
}

variable "table_name" {
  description = "Unica tabla alcanzable a traves del endpoint DynamoDB."
  type        = string
}

variable "permissions_boundary_arn" {
  type = string
}
