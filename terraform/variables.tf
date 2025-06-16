variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project python Linkedin"
  type        = string
  default     = "python"
}

variable "key_pair_name" {
  description = "Python EC2 key pair"
  type        = string
  default     = "python-key"
}

variable "lambda_producer_zip" {
  description = "Path to Kafka producer lambda zip"
  type        = string
}

variable "lambda_consumer_zip" {
  description = "Path to Kafka consumer lambda zip"
  type        = string
}