terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend parcial: cada ambiente aporta su archivo envs/<env>.backend.hcl
  # (bucket por region + llave por ambiente + lock nativo de S3).
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Proveedor de la region DR: lo usa el stack primario de prod para dejar listo
# lo minimo en la region de recuperacion (bucket replica, tabla replica,
# orquestador de DR). En el despliegue DR apunta a la misma region.
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = local.tags
  }
}
