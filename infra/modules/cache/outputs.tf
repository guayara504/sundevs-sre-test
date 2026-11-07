output "primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  value = aws_elasticache_replication_group.this.port
}

output "replication_group_id" {
  value = aws_elasticache_replication_group.this.id
}

output "iam_user_id" {
  value = aws_elasticache_user.app.user_id
}

output "connect_arns" {
  description = "ARNs que la Lambda necesita en elasticache:Connect (cluster + usuario)."
  value = [
    aws_elasticache_replication_group.this.arn,
    aws_elasticache_user.app.arn,
  ]
}

output "member_cluster_ids" {
  # Determinista (conocido en plan) para poder crear alarmas por nodo con count.
  value = [for i in range(var.num_nodes) : format("%s-%03d", var.name, i + 1)]
}
