terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configuracion parcial: los valores llegan con -backend-config=backend.hcl.
  # El primer apply se hace con estado local (ver scripts/bootstrap.sh) y luego
  # se migra a este backend, que vive en el bucket que este mismo stack crea.
  backend "s3" {}
}
