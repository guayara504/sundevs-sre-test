data "aws_caller_identity" "current" {}

locals {
  region_codes = {
    "us-east-1" = "use1"
    "us-east-2" = "use2"
    "us-west-2" = "usw2"
  }

  account_id     = data.aws_caller_identity.current.account_id
  region_code    = local.region_codes[var.region]
  dr_region_code = local.region_codes[var.dr_region]

  # name  -> recursos compartidos entre regiones (tabla global).
  # rname -> recursos regionales y roles IAM (globales, deben ser unicos por region).
  name  = "${var.project}-${var.environment}"
  rname = "${local.name}-${local.region_code}"

  is_primary = var.deployment_role == "primary"
  create_dr  = local.is_primary && var.enable_dr

  table_name        = "${local.name}-results"
  bucket_name       = "${local.name}-results-${local.account_id}-${local.region_code}"
  dr_bucket_name    = "${local.name}-results-${local.account_id}-${local.dr_region_code}"
  processor_role    = "${local.rname}-processor"
  dr_processor_role = "${local.name}-${local.dr_region_code}-processor"

  tags = {
    Project        = var.project
    Environment    = var.environment
    DeploymentRole = var.deployment_role
    ManagedBy      = "terraform"
    Repository     = var.repository
  }
}

# ---------------------------------------------------------------------------
# Red: VPC, subnets publicas/privadas en 2 AZ, IGW, NAT opcional,
# gateway endpoints (S3, DynamoDB), security groups y flow logs.
# ---------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name               = local.rname
  region             = var.region
  vpc_cidr           = var.vpc_cidr
  enable_nat_gateway = var.enable_nat_gateway
  enable_flow_logs   = var.enable_flow_logs
  log_retention_days = var.log_retention_days
  bucket_name        = local.bucket_name
  table_name         = local.table_name

  permissions_boundary_arn = local.boundary_arn
}

# ---------------------------------------------------------------------------
# Cache: ElastiCache Redis con TLS + autenticacion IAM (sin passwords).
# ---------------------------------------------------------------------------
module "cache" {
  source = "./modules/cache"
  count  = var.enable_redis ? 1 : 0

  name               = local.rname
  subnet_ids         = module.network.private_subnet_ids
  security_group_id  = module.network.redis_security_group_id
  node_type          = var.redis_node_type
  num_nodes          = var.redis_num_nodes
  engine_version     = var.redis_engine_version
  log_retention_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Datos en la region DR (solo prod primario): bucket destino de replicacion.
# ---------------------------------------------------------------------------
module "dr_storage" {
  source = "./modules/dr-storage"
  count  = local.create_dr ? 1 : 0

  providers = {
    aws = aws.dr
  }

  bucket_name               = local.dr_bucket_name
  allowed_writer_role_arns  = ["arn:aws:iam::${local.account_id}:role/${local.dr_processor_role}"]
  replication_role_arn      = "arn:aws:iam::${local.account_id}:role/${local.rname}-s3-replication"
  noncurrent_retention_days = 30
}

# ---------------------------------------------------------------------------
# Datos: S3 (resultados) + DynamoDB (registro durable / fuente de verdad).
# En modo dr se reutilizan los datos replicados (no se crean).
# ---------------------------------------------------------------------------
module "data" {
  source = "./modules/data"

  create              = local.is_primary
  bucket_name         = local.bucket_name
  table_name          = local.table_name
  processor_role_arn  = "arn:aws:iam::${local.account_id}:role/${local.processor_role}"
  s3_vpc_endpoint_id  = module.network.s3_vpc_endpoint_id
  deletion_protection = var.deletion_protection

  replica_regions          = local.create_dr ? [var.dr_region] : []
  enable_replication       = local.create_dr
  replication_bucket_arn   = local.create_dr ? module.dr_storage[0].bucket_arn : null
  replication_role_name    = "${local.rname}-s3-replication"
  permissions_boundary_arn = local.boundary_arn
}

locals {
  boundary_arn = "arn:aws:iam::${local.account_id}:policy/${var.project}-workload-boundary"
}

# ---------------------------------------------------------------------------
# Servicio: Lambda (VPC) + API Gateway HTTP API.
# ---------------------------------------------------------------------------
module "service" {
  source = "./modules/service"

  name                     = local.rname
  environment              = var.environment
  role_name                = local.processor_role
  permissions_boundary_arn = local.boundary_arn
  artifact_path            = "${var.artifacts_dir}/processor.zip"

  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.lambda_security_group_id

  bucket_name        = module.data.bucket_name
  bucket_arn         = module.data.bucket_arn
  table_name         = module.data.table_name
  table_arn          = module.data.table_arn
  s3_vpc_endpoint_id = module.network.s3_vpc_endpoint_id

  redis_enabled        = var.enable_redis
  redis_host           = var.enable_redis ? module.cache[0].primary_endpoint : ""
  redis_port           = var.enable_redis ? module.cache[0].port : 6379
  redis_user_id        = var.enable_redis ? module.cache[0].iam_user_id : ""
  redis_cache_name     = var.enable_redis ? module.cache[0].replication_group_id : ""
  redis_connect_arns   = var.enable_redis ? module.cache[0].connect_arns : []
  cache_ttl_seconds    = var.cache_ttl_seconds
  memory_mb            = var.lambda_memory_mb
  timeout_seconds      = var.lambda_timeout_seconds
  reserved_concurrency = var.lambda_reserved_concurrency

  throttle_rate_limit  = var.api_throttle_rate_limit
  throttle_burst_limit = var.api_throttle_burst_limit
  log_retention_days   = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Observabilidad: SNS -> correo, alarmas y dashboard.
# ---------------------------------------------------------------------------
module "observability" {
  source = "./modules/observability"

  name                 = local.rname
  environment          = var.environment
  alert_email          = var.owner_email
  function_name        = module.service.function_name
  lambda_timeout_ms    = var.lambda_timeout_seconds * 1000
  api_id               = module.service.api_id
  table_name           = module.data.table_name
  redis_cluster_ids    = var.enable_redis ? module.cache[0].member_cluster_ids : []
  nat_gateway_enabled  = var.enable_nat_gateway
  nat_gateway_id       = module.network.nat_gateway_id
  metrics_namespace    = module.service.metrics_namespace
  api_5xx_threshold    = 1
  latency_p95_ms_limit = 1500
}

# ---------------------------------------------------------------------------
# DR automatizado (en la region DR): canary de salud + orquestador de failover.
# ---------------------------------------------------------------------------
module "dr_automation" {
  source = "./modules/dr-automation"
  count  = local.create_dr ? 1 : 0

  providers = {
    aws = aws.dr
  }

  # El canary no debe empezar a sondear hasta que la API (rutas, stage,
  # integracion y Lambda) exista por completo: en el primer deploy recibia
  # HTTP 404 durante ~14 min, la alarma entraba en ALARM y el orquestador
  # intentaba un failover (falso positivo detectado en la prueba de prod).
  depends_on = [module.service]

  name                     = "${local.name}-${local.dr_region_code}"
  project                  = var.project
  environment              = var.environment
  alert_email              = var.owner_email
  primary_health_url       = "${module.service.api_endpoint}/health"
  primary_region           = var.region
  repository               = var.repository
  auto_failover            = var.dr_auto_failover
  permissions_boundary_arn = local.boundary_arn
  artifacts_dir            = var.artifacts_dir
  log_retention_days       = var.log_retention_days
}
