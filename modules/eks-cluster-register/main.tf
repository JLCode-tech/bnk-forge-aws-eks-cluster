terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token != "" ? var.aws_session_token : null
}

data "aws_eks_cluster" "existing" {
  name = var.eks_cluster_name
}

# aws_eks_cluster_auth produces a short-lived STS token usable in the
# kubeconfig we emit. BNK Forge ingests the kubeconfig on first scan,
# well within the token validity window.
data "aws_eks_cluster_auth" "existing" {
  name = var.eks_cluster_name
}

locals {
  kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = data.aws_eks_cluster.existing.name
    clusters = [{
      name = data.aws_eks_cluster.existing.name
      cluster = {
        server                     = data.aws_eks_cluster.existing.endpoint
        certificate-authority-data = data.aws_eks_cluster.existing.certificate_authority[0].data
      }
    }]
    contexts = [{
      name = data.aws_eks_cluster.existing.name
      context = {
        cluster = data.aws_eks_cluster.existing.name
        user    = data.aws_eks_cluster.existing.name
      }
    }]
    users = [{
      name = data.aws_eks_cluster.existing.name
      user = {
        token = data.aws_eks_cluster_auth.existing.token
      }
    }]
  })
}

resource "terraform_data" "registration_marker" {
  input = {
    cluster_id   = data.aws_eks_cluster.existing.arn
    cluster_name = data.aws_eks_cluster.existing.name
  }
}
