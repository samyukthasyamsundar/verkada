variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "operator_ip" {
  description = "Your public IP in CIDR notation (e.g. 1.2.3.4/32) — only this IP can SSH to the bastion"
  type        = string
}

variable "account_id" {
  description = "AWS account ID (used to make S3 bucket name globally unique)"
  type        = string
  default     = "019256649628"
}
