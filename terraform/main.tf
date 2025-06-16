provider "aws" {
  region = var.region
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Public subnets
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
}

# Private subnets
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.101.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.102.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway in public subnet
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  depends_on    = [aws_internet_gateway.igw]
}

# Route table for private subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# Bastion Host in public subnet
resource "aws_instance" "bastion" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public_a.id
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.bastion.id]
}

resource "aws_security_group" "bastion" {
  name        = "bastion_sg"
  description = "Allow SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# API Gateway
resource "aws_apigatewayv2_api" "api" {
  name          = "python-api"
  protocol_type = "HTTP"
}

# SQS Queue
resource "aws_sqs_queue" "queue" {
  name = "python-queue"
}

# Lambda role
resource "aws_iam_role" "lambda_role" {
  name = "lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Lambda function - Kafka producer
resource "aws_lambda_function" "kafka_producer" {
  function_name = "kafka_producer"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.9"

  filename         = var.lambda_producer_zip
  source_code_hash = filebase64sha256(var.lambda_producer_zip)

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
}

resource "aws_security_group" "lambda_sg" {
  name   = "lambda_sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Event source mapping Lambda -> SQS
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn  = aws_sqs_queue.queue.arn
  function_name     = aws_lambda_function.kafka_producer.arn
  batch_size        = 10
}

# MSK Cluster
resource "aws_msk_cluster" "cluster" {
  cluster_name           = "python-cluster"
  kafka_version          = "3.3.1"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.m5.large"
    client_subnets  = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups = [aws_security_group.msk_sg.id]
  }
}

resource "aws_security_group" "msk_sg" {
  name   = "msk_sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    security_groups = [aws_security_group.lambda_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 instance in private subnet for MSK access
resource "aws_instance" "msk_client" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.msk_client_sg.id]
  key_name               = var.key_pair_name
}

resource "aws_security_group" "msk_client_sg" {
  name   = "msk_client_sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.msk_sg.id]
  }
}

# Lambda consumer connected via NAT
resource "aws_lambda_function" "kafka_consumer" {
  function_name = "kafka_consumer"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.9"

  filename         = var.lambda_consumer_zip
  source_code_hash = filebase64sha256(var.lambda_consumer_zip)

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
}

# Kinesis Data Stream
resource "aws_kinesis_stream" "stream" {
  name             = "python-stream"
  shard_count      = 1
  retention_period = 24
}

# Firehose delivery stream
resource "aws_kinesis_firehose_delivery_stream" "firehose" {
  name        = "python-firehose"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.firehose_bucket.arn
  }
}

resource "aws_iam_role" "firehose_role" {
  name = "firehose_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
    }]
  })
}

resource "aws_s3_bucket" "firehose_bucket" {
  bucket = "${var.project}-firehose-bucket"
  force_destroy = true
}

# Glue Catalog Database
resource "aws_glue_catalog_database" "db" {
  name = "pythondb"
}

# Glue Crawler
resource "aws_glue_crawler" "crawler" {
  name         = "${var.project}-crawler"
  role         = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.db.name
  s3_target {
    path = aws_s3_bucket.firehose_bucket.arn
  }
}

resource "aws_iam_role" "glue_role" {
  name = "glue_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
  })
}

data "aws_ami" "amazon_linux" {
  owners      = ["amazon"]
  most_recent = true
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
}

data "aws_availability_zones" "available" {}
