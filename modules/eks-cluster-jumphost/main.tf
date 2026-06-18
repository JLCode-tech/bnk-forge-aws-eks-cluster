# =============================================================================
# eks-cluster-jumphost
# =============================================================================
# Provisions a single-instance bastion / jumphost for an EKS cluster whose
# public API endpoint is CIDR-locked. The jumphost sits in a public subnet,
# gets an Elastic IP, and carries an IAM role with eks:DescribeCluster +
# AmazonSSMManagedInstanceCore so it can self-configure kubectl via
# aws eks update-kubeconfig at boot.
#
# Security posture:
#   - SSH inbound locked to var.user_ip (/32 only)
#   - IMDSv2 required (http_tokens = "required")
#   - Root volume encrypted gp3
#   - SSM Session Manager available as a fallback if SSH is unreachable
#   - No secondary ENIs (single ENI via subnet_id)
#
# Key pair: a fresh RSA-4096 key pair is generated each apply. The private
# key PEM is exposed as a sensitive output — retrieve it once and store it
# securely. It is not written to disk by this module.

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token != "" ? var.aws_session_token : null
}

locals {
  jumphost_subnet_id = var.public_subnet_ids[0]

  common_tags = merge(var.tags, {
    "bnk-forge:module"  = "eks-cluster-jumphost"
    "bnk-forge:cluster" = var.eks_cluster_name
  })
}

# ---------------------------------------------------------------------------
# AMI — Amazon Linux 2023 (x86_64)
# ---------------------------------------------------------------------------

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Key pair (generated per apply; private key exposed as sensitive output)
# ---------------------------------------------------------------------------

resource "tls_private_key" "jumphost" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "jumphost" {
  key_name   = "${var.eks_cluster_name}-jumphost-kp"
  public_key = tls_private_key.jumphost.public_key_openssh

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Security group — SSH from user_ip only; egress unrestricted
# ---------------------------------------------------------------------------

resource "aws_security_group" "jumphost" {
  name        = "${var.eks_cluster_name}-jumphost-sg"
  description = "SSH access for EKS jumphost - locked to operator IP"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from operator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.user_ip]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.eks_cluster_name}-jumphost-sg"
  })
}

# ---------------------------------------------------------------------------
# IAM — instance role with SSM + scoped EKS read
# ---------------------------------------------------------------------------

resource "aws_iam_role" "jumphost" {
  name = "${var.eks_cluster_name}-jumphost-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jumphost.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "eks_describe" {
  name = "eks-describe-cluster"
  role = aws_iam_role.jumphost.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:${data.aws_partition.current.partition}:eks:${var.aws_region}:*:cluster/${var.eks_cluster_name}"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jumphost" {
  name = "${var.eks_cluster_name}-jumphost-profile"
  role = aws_iam_role.jumphost.name

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------

resource "aws_instance" "jumphost" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.jumphost_instance_type
  key_name                    = aws_key_pair.jumphost.key_name
  iam_instance_profile        = aws_iam_instance_profile.jumphost.name
  subnet_id                   = local.jumphost_subnet_id
  vpc_security_group_ids      = [aws_security_group.jumphost.id]
  associate_public_ip_address = false

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.jumphost_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  user_data_base64 = base64encode(templatefile("${path.module}/manifests/jumphost-userdata.sh.tftpl", {
    region          = var.aws_region
    cluster_name    = var.eks_cluster_name
    kubectl_version = var.kubectl_version
  }))

  tags = merge(local.common_tags, {
    Name = "${var.eks_cluster_name}-jumphost"
  })
}

# ---------------------------------------------------------------------------
# Elastic IP
# ---------------------------------------------------------------------------

resource "aws_eip" "jumphost" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.eks_cluster_name}-jumphost-eip"
  })
}

resource "aws_eip_association" "jumphost" {
  instance_id   = aws_instance.jumphost.id
  allocation_id = aws_eip.jumphost.id
}
