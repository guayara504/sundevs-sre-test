variable "project" {
  description = "Prefijo de nombres. Debe coincidir con el del bootstrap (los roles OIDC solo gestionan <project>-<env>-*)."
  type        = string
  default     = "sundevs-sre"
}

variable "environment" {
  description = "Ambiente logico."
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment debe ser dev o prod."
  }
}

variable "deployment_role" {
  description = "primary = region activa (crea los datos); dr = restauracion en la region DR (reutiliza datos replicados)."
  type        = string
  default     = "primary"
  validation {
    condition     = contains(["primary", "dr"], var.deployment_role)
    error_message = "deployment_role debe ser primary o dr."
  }
}

variable "region" {
  description = "Region donde se despliega este stack."
  type        = string
}

variable "dr_region" {
  description = "Region de recuperacion."
  type        = string
  default     = "us-east-2"
}

variable "repository" {
  description = "owner/repo de GitHub (etiquetas y disparo de DR)."
  type        = string
}

variable "owner_email" {
  description = "Correo que recibe las alarmas (SNS). Requiere confirmar la suscripcion."
  type        = string
}

# --- Red -------------------------------------------------------------------
variable "vpc_cidr" {
  type = string
}

variable "enable_nat_gateway" {
  description = "NAT Gateway para salida a internet desde subnets privadas. La Lambda NO lo necesita para S3/DynamoDB (gateway endpoints); se puede apagar para ahorrar ~33 USD/mes."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "VPC Flow Logs (solo REJECT) hacia CloudWatch."
  type        = bool
  default     = true
}

# --- Cache -----------------------------------------------------------------
variable "enable_redis" {
  description = "Crea ElastiCache. Si es false la Lambda opera en modo degradado (lee de DynamoDB) y responde X-Cache: MISS."
  type        = bool
  default     = true
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "redis_num_nodes" {
  description = "1 = sin replica (dev). 2+ = Multi-AZ con failover automatico (prod)."
  type        = number
  default     = 1
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

variable "cache_ttl_seconds" {
  type    = number
  default = 60
}

# --- Compute / API ---------------------------------------------------------
variable "lambda_memory_mb" {
  type    = number
  default = 256
}

variable "lambda_timeout_seconds" {
  type    = number
  default = 10
}

variable "lambda_reserved_concurrency" {
  description = "-1 = sin reserva. Limitar protege Redis/DynamoDB de picos (requiere cuota de concurrencia suficiente)."
  type        = number
  default     = -1
}

variable "api_throttle_rate_limit" {
  description = "Requests por segundo sostenidos a nivel de stage."
  type        = number
  default     = 50
}

variable "api_throttle_burst_limit" {
  type    = number
  default = 100
}

variable "artifacts_dir" {
  description = "Directorio con los .zip construidos por scripts/build_lambda.py."
  type        = string
  default     = "../build"
}

# --- Datos / operacion ------------------------------------------------------
variable "log_retention_days" {
  type    = number
  default = 14
}

variable "deletion_protection" {
  description = "Proteccion contra borrado de la tabla DynamoDB."
  type        = bool
  default     = false
}

variable "enable_dr" {
  description = "Solo primary: replica datos a la region DR y despliega el canary + orquestador de failover."
  type        = bool
  default     = false
}

variable "dr_auto_failover" {
  description = "Si es true, el orquestador dispara el workflow de DR automaticamente al detectar caida."
  type        = bool
  default     = true
}
