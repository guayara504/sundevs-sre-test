terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "name" {
  description = "Nombre del rol IAM."
  type        = string
}

variable "description" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "github_owner" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "subject_suffixes" {
  description = "Sufijos del claim 'sub' permitidos, ej: environment:production, pull_request, ref:refs/heads/main."
  type        = list(string)
}

variable "managed_policy_arns" {
  type    = list(string)
  default = []
}

variable "inline_policy_json" {
  type = string
}

locals {
  # GitHub emite el 'sub' en dos formatos: el clasico (owner/repo) y el que
  # incluye IDs inmutables (owner@id/repo@id). Se aceptan ambos, pero SIEMPRE
  # anclados al owner/repo y a un sufijo explicito: nunca comodines abiertos.
  subjects = flatten([
    for s in var.subject_suffixes : [
      "repo:${var.github_owner}/${var.github_repo}:${s}",
      "repo:${var.github_owner}@*/${var.github_repo}@*:${s}",
    ]
  ])
}

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  description          = var.description
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}
