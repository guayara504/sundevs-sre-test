variable "name" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "node_type" {
  type = string
}

variable "num_nodes" {
  type = number
}

variable "engine_version" {
  type = string
}

variable "log_retention_days" {
  type = number
}
