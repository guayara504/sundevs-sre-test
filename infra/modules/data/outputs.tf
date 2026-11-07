output "bucket_name" {
  value = var.create ? aws_s3_bucket.results[0].id : data.aws_s3_bucket.results[0].id
}

output "bucket_arn" {
  value = var.create ? aws_s3_bucket.results[0].arn : data.aws_s3_bucket.results[0].arn
}

output "table_name" {
  value = var.create ? aws_dynamodb_table.results[0].name : data.aws_dynamodb_table.results[0].name
}

output "table_arn" {
  value = var.create ? aws_dynamodb_table.results[0].arn : data.aws_dynamodb_table.results[0].arn
}
