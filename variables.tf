variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "The AWS region to deploy to"
}

variable "instance_type" {
  type        = string
  default     = "c8g.xlarge"
  description = "The instance type to deploy"
}

variable "ubuntu-version" {
  type        = string
  default     = "22.04"
  description = "The Ubuntu version to deploy"
}

variable "max_hourly_instance_price" {
  type        = number
  default     = 0.10
  description = "The maximum hourly price to pay per spot instance"
}
