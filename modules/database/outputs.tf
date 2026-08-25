output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "master_user_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "availability_zone" {
  description = "AZ of this single-AZ instance. Restore to another AZ if this one fails."
  value       = aws_db_instance.this.availability_zone
}
