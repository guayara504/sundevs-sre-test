environment     = "dev"
deployment_role = "primary"
region          = "us-east-1"
dr_region       = "us-east-2"
repository      = "guayara504/sundevs-sre-test"
owner_email     = "vgs2016@gmail.com"

vpc_cidr = "10.20.0.0/16"

# Interruptores de costo (ver README > Costos).
enable_nat_gateway = false
enable_redis       = false
enable_flow_logs   = true

redis_node_type = "cache.t3.micro"
redis_num_nodes = 1

api_throttle_rate_limit  = 20
api_throttle_burst_limit = 40

log_retention_days  = 14
deletion_protection = false

# dev no tiene DR: ahorro de costo, solo prod se replica.
enable_dr = false
