terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "verkada-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "verkada-igw" }
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = { Name = "verkada-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"

  tags = { Name = "verkada-private" }
}

# ── Routing ───────────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "verkada-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# S3 VPC endpoint — lets the private subnet reach S3 without a NAT gateway
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]

  tags = { Name = "verkada-s3-endpoint" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "verkada-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "bastion" {
  name        = "verkada-bastion-sg"
  description = "SSH access to bastion from operator IP only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "verkada-bastion-sg" }
}

resource "aws_security_group" "mgmt_server" {
  name        = "verkada-mgmt-sg"
  description = "Camera management server: SSH from bastion, HTTPS out only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from bastion only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Outbound HTTPS only — mirrors Verkada camera outbound-only model
  egress {
    description = "HTTPS to Verkada cloud"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "verkada-mgmt-sg" }
}

# ── EC2 Instances ─────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = aws_key_pair.deployer.key_name

  tags = { Name = "verkada-bastion" }
}

resource "aws_instance" "mgmt_server" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.mgmt_server.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.mgmt_profile.name

  tags = { Name = "verkada-mgmt-server" }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ── SSH Key ───────────────────────────────────────────────────────────────────

resource "tls_private_key" "deployer" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "deployer" {
  key_name   = "verkada-deployer-key"
  public_key = tls_private_key.deployer.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.deployer.private_key_pem
  filename        = "${path.module}/verkada-key.pem"
  file_permission = "0600"
}

# ── S3 Backup Bucket ──────────────────────────────────────────────────────────

resource "aws_s3_bucket" "footage" {
  bucket        = "verkada-footage-${var.account_id}"
  force_destroy = true

  tags = { Name = "verkada-footage" }
}

resource "aws_s3_bucket_public_access_block" "footage" {
  bucket                  = aws_s3_bucket.footage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── IAM: least-privilege role for mgmt server ─────────────────────────────────

resource "aws_iam_role" "mgmt_role" {
  name = "verkada-mgmt-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "footage_access" {
  name        = "verkada-footage-access"
  description = "Allow mgmt server to read/write footage bucket only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.footage.arn,
        "${aws_s3_bucket.footage.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mgmt_attach" {
  role       = aws_iam_role.mgmt_role.name
  policy_arn = aws_iam_policy.footage_access.arn
}

resource "aws_iam_instance_profile" "mgmt_profile" {
  name = "verkada-mgmt-profile"
  role = aws_iam_role.mgmt_role.name
}
