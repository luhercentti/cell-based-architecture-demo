variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "poc"
}

variable "project" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "cell-poc"
}
