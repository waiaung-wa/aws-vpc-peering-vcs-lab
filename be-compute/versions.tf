terraform {
  required_version = ">= 1.12" # ephemeral resources need >= 1.10

  cloud {
    organization = "waiaung-vpc-lab"

    workspaces {
      project = "aws-vpc-peering-infra"
      name    = "be-compute-ws"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}
