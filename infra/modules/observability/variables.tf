variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "function_name" {
  type = string
}

variable "lambda_timeout_ms" {
  type = number
}

variable "api_id" {
  type = string
}

variable "table_name" {
  type = string
}

variable "redis_cluster_ids" {
  description = "Nodos Redis a monitorear (lista vacia si Redis esta apagado)."
  type        = list(string)
}

variable "nat_gateway_enabled" {
  type = bool
}

variable "nat_gateway_id" {
  type    = string
  default = null
}

variable "metrics_namespace" {
  type = string
}

variable "api_5xx_threshold" {
  description = "Numero de 5xx por minuto que dispara la alarma."
  type        = number
}

variable "latency_p95_ms_limit" {
  type = number
}
