
variable "aws_region" {
  description = "us-east-1"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "darylsmith.dev"
  type        = string
}

variable "account_suffix" {
  description = "darylsmithdev"
  type        = string
}

variable "hosted_zone_id" {
  description = "Z03958751LAWXI1SDY0VK"
  type        = string
}

variable "manage_oidc_provider" {
  description = "Create the GitHub OIDC provider (admin/bootstrap only). Otherwise, look up the existing provider."
  type        = bool
  default     = false
}
