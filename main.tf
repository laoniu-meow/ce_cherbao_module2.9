provider "aws" {
  region = var.region
}

# Automatically get your public IP (at apply-time)
data "http" "laoniu_wan_ip" {
  url = "http://checkip.amazonaws.com"
}

locals {
  laoniu_wan_ip = chomp(data.http.laoniu_wan_ip.response_body)
}

# Create VPC
resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"
}

# Create Public Subnets
resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.20.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
}

# Create Internet Gateway
resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main_vpc.id
}

# Create Route Table
resource "aws_route_table" "main_route_table" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id
  }
}

# Associate Route Table with Public Subnets
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.main_route_table.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.main_route_table.id
}

data "aws_availability_zones" "available" {}

# Create Application Load Balancer
resource "aws_lb" "main_alb" {
  name               = "laoniu-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
}

resource "aws_security_group" "alb_sg" {
  name        = "laoniu-alb-sg"
  description = "Allow HTTP"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
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

resource "aws_lb_target_group" "laoniu_alb_tg" {
  name     = "laoniu-alb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main_vpc.id
}

resource "aws_lb_listener" "laoniu_alb_listener" {
  load_balancer_arn = aws_lb.main_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.laoniu_alb_tg.arn
  }
}

# Create WAFv2 IP Set
resource "aws_wafv2_ip_set" "laoniu_wan_ip" {
  name               = "laoniu-wan-ip"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = ["${local.laoniu_wan_ip}/32"]
}

resource "aws_wafv2_web_acl" "laoniu_web_acl" {
  name  = "laoniu-web-acl"
  scope = "REGIONAL"

  default_action {
    block {} # Default: block everyone
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "laoniu_web_acl"
    sampled_requests_enabled   = true
  }

  # Rule 1: Allow my WAN IP
  rule {
    name     = "allow_laoniu_wan_ip"
    priority = 1
    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.laoniu_wan_ip.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "allow_laoniu_wan_ip"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Block all other IP addresses
  rule {
    name     = "block_other_ips"
    priority = 2
    action {
      block {}
    }

    statement {
      byte_match_statement {
        field_to_match {
          uri_path {}
        }

        positional_constraint = "EXACTLY"
        search_string         = "/admin"

        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block_other_ips"
      sampled_requests_enabled   = true
    }
  }

  # Optional Rule 3: Block bad IPs from AWS Reputation List
  rule {
    name     = "block_aws_ip_reputation"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block_aws_ip_reputation"
      sampled_requests_enabled   = true
    }
  }
}
