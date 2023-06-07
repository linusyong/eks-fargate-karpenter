provider "aws" {
  region = "ap-southeast-1"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "eks-fargate-karpenter"
  }
}

variable "cluster_name" {
  default = "eks-fargate-karpenter"
}

variable "cluster_version" {
  default = "1.27"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.9.0"
    }
  }
}