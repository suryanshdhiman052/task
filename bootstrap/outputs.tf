output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "backend_hcl" {
  description = "Paste into backend.hcl at the repo root, then run terraform init -backend-config=backend.hcl"
  value       = <<-HCL
    bucket         = "${aws_s3_bucket.state.bucket}"
    key            = "prod/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.lock.name}"
    encrypt        = true
  HCL
}
