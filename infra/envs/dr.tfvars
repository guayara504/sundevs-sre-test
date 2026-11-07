# Restauracion de PROD en la region DR. Lo aplica el workflow dr.yml
# (disparado por el orquestador o manualmente).
environment     = "prod"
deployment_role = "dr"
region          = "us-east-2"
dr_region       = "us-east-2"
repository      = "guayara504/sundevs-sre-test"
owner_email     = "vgs2016@gmail.com"

vpc_cidr = "10.40.0.0/16"

# Durante un desastre se prioriza tiempo de recuperacion y costo: la cache
# se levanta (1 nodo) y no se crea NAT (la Lambda usa gateway endpoints).
enable_nat_gateway = false
enable_redis       = true
enable_flow_logs   = true

redis_node_type = "cache.t3.micro"
redis_num_nodes = 1

api_throttle_rate_limit  = 50
api_throttle_burst_limit = 100

log_retention_days  = 30
deletion_protection = false
enable_dr           = false
