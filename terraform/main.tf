terraform {
  required_version = ">= 1.0"

  backend "gcs" {
    bucket = "ftm-terraform-state"
    prefix = "terraform/state"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

module "cloudflare" {
  source     = "./cloudflare"
  api_token  = var.cloudflare_api_token
  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  zone       = var.cloudflare_zone
}

# Outputs
output "tunnel_token" {
  description = "Cloudflare Tunnel Token"
  value       = module.cloudflare.tunnel_token
  sensitive   = true
}

output "tunnel_cname" {
  description = "Cloudflare Tunnel CNAME"
  value       = module.cloudflare.tunnel_cname
}