variable "name" {
  type = string
}

variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "primary_health_url" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "repository" {
  type = string
}

variable "auto_failover" {
  type = bool
}

variable "permissions_boundary_arn" {
  type = string
}

variable "artifacts_dir" {
  type = string
}

variable "log_retention_days" {
  type = number
}
