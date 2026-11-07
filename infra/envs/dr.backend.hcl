# El estado del DR vive en la region DR: si us-east-1 cae, sigue accesible.
bucket       = "tfstate-sundevs-sre-624991055549-use2"
key          = "sundevs-sre/prod-dr/terraform.tfstate"
region       = "us-east-2"
encrypt      = true
use_lockfile = true
