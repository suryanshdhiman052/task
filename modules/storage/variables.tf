variable "name" {
  type        = string
  description = "Stack name prefix for the assets S3 bucket."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,20}$", var.name))
    error_message = "name must be lowercase alphanumeric with hyphens, max 21 characters."
  }
}
