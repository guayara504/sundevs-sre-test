variable "project" {
  description = "Prefijo de nombres de todos los recursos del proyecto."
  type        = string
  default     = "sundevs-sre"
}

variable "primary_region" {
  description = "Region primaria (workload activo)."
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Region de recuperacion ante desastres (backup & restore)."
  type        = string
  default     = "us-east-2"
}

variable "github_owner" {
  description = "Usuario u organizacion de GitHub duena del repositorio."
  type        = string
}

variable "github_repo" {
  description = "Nombre del repositorio de GitHub."
  type        = string
}

variable "alert_email" {
  description = "Correo que recibe las alertas de presupuesto."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual del proyecto en USD (alerta al 80% real y 100% pronosticado)."
  type        = number
  default     = 30
}
