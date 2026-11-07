output "account_id" {
  value = local.account_id
}

output "state_bucket_primary" {
  value = module.state_primary.bucket_name
}

output "state_bucket_dr" {
  value = module.state_dr.bucket_name
}

output "permissions_boundary_arn" {
  value = aws_iam_policy.boundary.arn
}

output "github_plan_role_arn" {
  value = module.plan_role.role_arn
}

output "github_deploy_role_arns" {
  value = { for k, m in module.deploy_role : k => m.role_arn }
}
