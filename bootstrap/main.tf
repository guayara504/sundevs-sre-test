###############################################################################
# Bootstrap (se aplica UNA vez, localmente, con credenciales de administrador)
#
# Crea lo minimo para que GitHub Actions despliegue sin llaves estaticas:
#   - Buckets de estado de Terraform (uno por region: el DR no depende de us-east-1)
#   - Roles IAM asumibles via OIDC por ambiente (plan / dev / prod / dr)
#   - Permissions boundary obligatorio para todo rol que creen los pipelines
#   - Presupuesto mensual con alerta por correo
#
# El OIDC provider de GitHub YA existe en la cuenta (lo usan otros proyectos):
# se referencia con un data source y no se recrea ni se modifica.
###############################################################################

provider "aws" {
  region = var.primary_region
  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  allowed_regions = [var.primary_region, var.dr_region]
  boundary_name   = "${var.project}-workload-boundary"
  boundary_arn    = "arn:aws:iam::${local.account_id}:policy/${local.boundary_name}"

  tags = {
    Project    = var.project
    ManagedBy  = "terraform"
    Stack      = "bootstrap"
    Repository = "${var.github_owner}/${var.github_repo}"
  }

  # Servicios globales que no deben quedar bloqueados por la restriccion de region.
  global_services = [
    "iam:*", "sts:*", "organizations:*", "account:*", "budgets:*", "ce:*",
    "cloudfront:*", "route53:*", "support:*", "health:*", "pricing:*",
  ]

  # Ambientes de despliegue. "dr" despliega el ambiente prod en la region DR,
  # por eso comparte el prefijo de recursos de prod pero tiene su propio rol,
  # su propio environment de GitHub y su propio bucket de estado.
  deploy_targets = {
    dev = {
      resource_env = "dev"
      github_env   = "dev"
      state_bucket = module.state_primary.bucket_arn
      state_prefix = "${var.project}/dev/"
    }
    prod = {
      resource_env = "prod"
      github_env   = "production"
      state_bucket = module.state_primary.bucket_arn
      state_prefix = "${var.project}/prod/"
    }
    dr = {
      resource_env = "prod"
      github_env   = "dr"
      state_bucket = module.state_dr.bucket_arn
      state_prefix = "${var.project}/prod-dr/"
    }
  }
}

# ----------------------------------------------------------------------------
# Estado remoto: S3 con versionado, cifrado, TLS obligatorio y lock nativo
# (use_lockfile, Terraform >= 1.10: ya no hace falta tabla DynamoDB de locks).
# ----------------------------------------------------------------------------
module "state_primary" {
  source      = "./modules/state-bucket"
  bucket_name = "tfstate-${var.project}-${local.account_id}-use1"
}

module "state_dr" {
  source      = "./modules/state-bucket"
  bucket_name = "tfstate-${var.project}-${local.account_id}-use2"
  providers = {
    aws = aws.dr
  }
}

# ----------------------------------------------------------------------------
# Permissions boundary: techo de permisos de TODO rol creado por los pipelines
# (Lambda, flow logs, replicacion S3). Evita que un pipeline comprometido cree
# un rol con mas privilegios que los que la carga de trabajo necesita.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "boundary" {
  statement {
    sid    = "WorkloadData"
    effect = "Allow"
    actions = [
      "s3:*",
      "dynamodb:*",
    ]
    resources = [
      "arn:aws:s3:::${var.project}-*",
      "arn:aws:s3:::${var.project}-*/*",
      "arn:aws:dynamodb:*:${local.account_id}:table/${var.project}-*",
    ]
  }

  statement {
    sid    = "WorkloadRuntime"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "elasticache:Connect",
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "WorkloadIntegrations"
    effect = "Allow"
    actions = [
      "sns:Publish",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "ssm:GetParameter",
      "ssm:PutParameter",
    ]
    resources = [
      "arn:aws:sns:*:${local.account_id}:${var.project}-*",
      "arn:aws:secretsmanager:*:${local.account_id}:secret:${var.project}-*",
      "arn:aws:ssm:*:${local.account_id}:parameter/${var.project}/*",
    ]
  }

  statement {
    sid         = "DenyOutsideAllowedRegions"
    effect      = "Deny"
    not_actions = local.global_services
    resources   = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = local.allowed_regions
    }
  }
}

resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  description = "Permissions boundary obligatorio para los roles de carga de trabajo de ${var.project}."
  policy      = data.aws_iam_policy_document.boundary.json
}

# ----------------------------------------------------------------------------
# Politica de despliegue por ambiente (minimo privilegio pragmatico):
#   - Servicios con ARN predecible quedan acotados al prefijo del ambiente.
#   - IAM solo puede crear roles del ambiente y SIEMPRE con el boundary.
#   - Guardrail tipo SCP: deny fuera de las regiones permitidas.
#   - Estado de Terraform: solo la llave del propio ambiente.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy" {
  for_each = local.deploy_targets

  statement {
    sid         = "DenyOutsideAllowedRegions"
    effect      = "Deny"
    not_actions = local.global_services
    resources   = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = local.allowed_regions
    }
  }

  statement {
    sid    = "DenyTamperingWithGuardrails"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeleteRolePermissionsBoundary",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DeleteRole",
    ]
    resources = [
      local.boundary_arn,
      "arn:aws:iam::${local.account_id}:role/${var.project}-gha-*",
    ]
  }

  statement {
    sid    = "RegionalInfrastructure"
    effect = "Allow"
    actions = [
      "ec2:*",
      "elasticache:*",
      "apigateway:*",
      "logs:*",
      "cloudwatch:*",
      "events:*",
      "xray:*",
      "tag:GetResources",
      "s3:ListAllMyBuckets",
      "dynamodb:ListTables",
      "dynamodb:DescribeLimits",
      "ssm:DescribeParameters",
      "lambda:ListFunctions",
      "lambda:GetAccountSettings",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ScopedServices"
    effect  = "Allow"
    actions = ["s3:*", "dynamodb:*", "lambda:*", "sns:*", "secretsmanager:*", "ssm:*"]
    resources = [
      "arn:aws:s3:::${var.project}-${each.value.resource_env}-*",
      "arn:aws:s3:::${var.project}-${each.value.resource_env}-*/*",
      "arn:aws:dynamodb:*:${local.account_id}:table/${var.project}-${each.value.resource_env}-*",
      "arn:aws:dynamodb:*:${local.account_id}:table/${var.project}-${each.value.resource_env}-*/*",
      "arn:aws:dynamodb::${local.account_id}:global-table/${var.project}-${each.value.resource_env}-*",
      "arn:aws:lambda:*:${local.account_id}:function:${var.project}-${each.value.resource_env}-*",
      "arn:aws:sns:*:${local.account_id}:${var.project}-${each.value.resource_env}-*",
      "arn:aws:secretsmanager:*:${local.account_id}:secret:${var.project}-${each.value.resource_env}-*",
      "arn:aws:ssm:*:${local.account_id}:parameter/${var.project}/${each.value.resource_env}/*",
    ]
  }

  statement {
    sid       = "CreateRolesOnlyWithBoundary"
    effect    = "Allow"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.value.resource_env}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid    = "ManageEnvironmentRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.value.resource_env}-*"]
  }

  statement {
    sid       = "PassEnvironmentRolesToServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.value.resource_env}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "vpc-flow-logs.amazonaws.com", "s3.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadManagedPolicies"
    effect    = "Allow"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListEntitiesForPolicy"]
    resources = ["*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "elasticache.amazonaws.com",
        "replication.dynamodb.amazonaws.com",
        "ops.apigateway.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "TerraformStateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [each.value.state_bucket]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.value.state_prefix}*"]
    }
  }

  statement {
    sid       = "TerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${each.value.state_bucket}/${each.value.state_prefix}*"]
  }
}

module "deploy_role" {
  source   = "./modules/github-role"
  for_each = local.deploy_targets

  name               = "${var.project}-gha-${each.key}"
  description        = "GitHub Actions (environment ${each.value.github_env}) despliega ${var.project}-${each.value.resource_env}."
  oidc_provider_arn  = data.aws_iam_openid_connect_provider.github.arn
  github_owner       = var.github_owner
  github_repo        = var.github_repo
  subject_suffixes   = ["environment:${each.value.github_env}"]
  inline_policy_json = data.aws_iam_policy_document.deploy[each.key].json
}

# ----------------------------------------------------------------------------
# Rol de solo lectura para "terraform plan" en PRs y antes de cada apply.
# No puede modificar infraestructura; solo escribe los .tflock del estado.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "StateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [module.state_primary.bucket_arn, module.state_dr.bucket_arn]
  }

  statement {
    sid     = "StateRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${module.state_primary.bucket_arn}/${var.project}/*",
      "${module.state_dr.bucket_arn}/${var.project}/*",
    ]
  }

  statement {
    sid     = "StateLock"
    effect  = "Allow"
    actions = ["s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${module.state_primary.bucket_arn}/${var.project}/*.tflock",
      "${module.state_dr.bucket_arn}/${var.project}/*.tflock",
    ]
  }

  # ReadOnlyAccess incluye lectura de datos de negocio; el plan no la necesita.
  statement {
    sid    = "DenyBusinessDataReads"
    effect = "Deny"
    actions = [
      "s3:GetObject",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "secretsmanager:GetSecretValue",
    ]
    not_resources = [
      "${module.state_primary.bucket_arn}/*",
      "${module.state_dr.bucket_arn}/*",
    ]
  }
}

module "plan_role" {
  source = "./modules/github-role"

  name              = "${var.project}-gha-plan"
  description       = "GitHub Actions: terraform plan (solo lectura) para PRs y ramas develop/main."
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  github_owner      = var.github_owner
  github_repo       = var.github_repo
  subject_suffixes = [
    "pull_request",
    "ref:refs/heads/develop",
    "ref:refs/heads/main",
  ]
  managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  inline_policy_json  = data.aws_iam_policy_document.plan.json
}

# ----------------------------------------------------------------------------
# Costos: presupuesto mensual filtrado por la etiqueta Project.
# ----------------------------------------------------------------------------
resource "aws_budgets_budget" "project" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.project}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
