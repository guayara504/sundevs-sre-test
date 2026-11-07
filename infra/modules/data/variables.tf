variable "create" {
  description = "true = crea bucket y tabla (primary). false = los referencia (dr)."
  type        = bool
}

variable "bucket_name" {
  type = string
}

variable "table_name" {
  type = string
}

variable "processor_role_arn" {
  description = "Unico principal con acceso al plano de datos del bucket."
  type        = string
}

variable "s3_vpc_endpoint_id" {
  type = string
}

variable "deletion_protection" {
  type = bool
}

variable "replica_regions" {
  type    = list(string)
  default = []
}

variable "enable_replication" {
  description = "Activa CRR del bucket hacia replication_bucket_arn (debe ser conocido en plan)."
  type        = bool
  default     = false
}

variable "replication_bucket_arn" {
  type    = string
  default = null
}

variable "replication_role_name" {
  type = string
}

variable "permissions_boundary_arn" {
  type = string
}
