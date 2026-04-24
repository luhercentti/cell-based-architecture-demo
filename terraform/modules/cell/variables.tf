variable "cell_id" {
  description = "Unique identifier for this cell (e.g. cell-001). Used to name all resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment (poc, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name prefix"
  type        = string
}

variable "alarm_sns_arn" {
  description = "SNS topic ARN to notify when cell health alarms trigger"
  type        = string
}
