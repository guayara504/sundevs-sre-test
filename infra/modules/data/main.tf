terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_caller_identity" "current" {}

###############################################################################
# Modo primary: se crean bucket y tabla.
###############################################################################
resource "aws_s3_bucket" "results" {
  count  = var.create ? 1 : 0
  bucket = var.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "results" {
  count  = var.create ? 1 : 0
  bucket = aws_s3_bucket.results[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  count                   = var.create ? 1 : 0
  bucket                  = aws_s3_bucket.results[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "results" {
  count  = var.create ? 1 : 0
  bucket = aws_s3_bucket.results[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  count  = var.create ? 1 : 0
  bucket = aws_s3_bucket.results[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  count  = var.create ? 1 : 0
  bucket = aws_s3_bucket.results[0].id

  rule {
    id     = "results-tiering"
    status = "Enabled"
    filter {
      prefix = "results/"
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.results]
}

locals {
  replication_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.replication_role_name}"
  bucket_arn           = "arn:aws:s3:::${var.bucket_name}"
}

data "aws_iam_policy_document" "results" {
  count = var.create ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Plano de datos restringido al rol de la Lambda (y al de replicacion DR).
  # Las acciones de gestion (politica, versionado, etc.) quedan para IaC.
  statement {
    sid       = "DenyObjectAccessExceptProcessor"
    effect    = "Deny"
    actions   = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*"]
    resources = ["${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [var.processor_role_arn, local.replication_role_arn]
    }
  }

  # La Lambda solo puede llegar al bucket a traves del VPC Gateway Endpoint.
  statement {
    sid       = "DenyProcessorOutsideVpcEndpoint"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [var.processor_role_arn]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      values   = [var.s3_vpc_endpoint_id]
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  count      = var.create ? 1 : 0
  bucket     = aws_s3_bucket.results[0].id
  policy     = data.aws_iam_policy_document.results[0].json
  depends_on = [aws_s3_bucket_public_access_block.results]
}

# --- Replicacion cross-region (CRR) hacia la region DR ----------------------
data "aws_iam_policy_document" "replication_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "replication" {
  count                = var.create && var.enable_replication ? 1 : 0
  name                 = var.replication_role_name
  assume_role_policy   = data.aws_iam_policy_document.replication_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "replication" {
  count = var.create && var.enable_replication ? 1 : 0

  statement {
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [local.bucket_arn]
  }
  statement {
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${local.bucket_arn}/*"]
  }
  statement {
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${var.replication_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "replication" {
  count  = var.create && var.enable_replication ? 1 : 0
  name   = "s3-crr"
  role   = aws_iam_role.replication[0].id
  policy = data.aws_iam_policy_document.replication[0].json
}

resource "aws_s3_bucket_replication_configuration" "results" {
  count  = var.create && var.enable_replication ? 1 : 0
  bucket = aws_s3_bucket.results[0].id
  role   = aws_iam_role.replication[0].arn

  rule {
    id     = "results-to-dr"
    status = "Enabled"
    filter {
      prefix = "results/"
    }
    delete_marker_replication {
      status = "Disabled"
    }
    destination {
      bucket        = var.replication_bucket_arn
      storage_class = "STANDARD_IA"
    }
  }

  depends_on = [aws_s3_bucket_versioning.results]
}

# --- DynamoDB: registro durable de resultados (fuente de verdad) ------------
resource "aws_dynamodb_table" "results" {
  count = var.create ? 1 : 0

  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = var.deletion_protection

  # Global table (v2019) si hay region DR: replica asincrona con RPO de
  # segundos y costo solo por escrituras replicadas + almacenamiento.
  stream_enabled   = length(var.replica_regions) > 0
  stream_view_type = length(var.replica_regions) > 0 ? "NEW_AND_OLD_IMAGES" : null

  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region_name            = replica.value
      point_in_time_recovery = true
    }
  }
}

###############################################################################
# Modo dr: los datos ya existen (replicados); solo se referencian.
###############################################################################
data "aws_s3_bucket" "results" {
  count  = var.create ? 0 : 1
  bucket = var.bucket_name
}

data "aws_dynamodb_table" "results" {
  count = var.create ? 0 : 1
  name  = var.table_name
}
