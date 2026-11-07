environment     = "prod"
deployment_role = "primary"
region          = "us-east-1"
dr_region       = "us-east-2"
repository      = "guayara504/sundevs-sre-test"
owner_email     = "vgs2016@gmail.com"

vpc_cidr = "10.30.0.0/16"

enable_nat_gateway = true
enable_redis       = true
enable_flow_logs   = true

redis_node_type = "cache.t3.micro"
redis_num_nodes = 2 # Multi-AZ con failover automatico

api_throttle_rate_limit  = 50
api_throttle_burst_limit = 100

log_retention_days  = 90
deletion_protection = true

# DR backup & restore: datos replicados (S3 CRR + DynamoDB global table) y
# computo restaurado bajo demanda por el orquestador.
enable_dr        = true
dr_auto_failover = true
