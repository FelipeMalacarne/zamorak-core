provider "cloudflare" {
  api_token = var.api_token
}

terraform {
  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      version = ">= 5.8.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "zamorak_tunnel" {
  account_id    = var.account_id
  name          = "Terraform Zamorak tunnel"
  config_src    = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "zamorak_tunnel_token" {
  account_id   = var.account_id
  tunnel_id   = cloudflare_zero_trust_tunnel_cloudflared.zamorak_tunnel.id
}

resource "cloudflare_dns_record" "traefik_dns_record" {
  zone_id = var.zone_id
  name    = "*"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.zamorak_tunnel.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "[terraform] Traefik Ingress Controller DNS record"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "zamorak_tunnel_config" {
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.zamorak_tunnel.id
  account_id = var.account_id
  config     = {
    ingress   = [
      {
        hostname = "*.${var.zone}"
        service  = "http://traefik:80"
      },
      {
        service  = "http_status:404"
      }
    ]
  }
}


# Outputs
output "tunnel_id" {
  description = "The ID of the Cloudflare Tunnel"
  value = cloudflare_zero_trust_tunnel_cloudflared.zamorak_tunnel.id
}

output "tunnel_token" {
  description = "The token for the Cloudflare Tunnel"
  value      = data.cloudflare_zero_trust_tunnel_cloudflared_token.zamorak_tunnel_token.token
  sensitive   = true
}

output "tunnel_cname" {
  description = "The CNAME for the Cloudflare Tunnel"
    value       = cloudflare_dns_record.traefik_dns_record.name
}

output "tunnel_domain" {
  description = "The full domain for the tunnel"
  value = "${cloudflare_dns_record.traefik_dns_record.name}.${var.zone}"
}