variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "my_wan_ip" {
  type    = string
  default = "123.123.123.123"
}
