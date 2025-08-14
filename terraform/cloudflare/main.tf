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

resource "cloudflare_zero_trust_tunnel_cloudflared" "portainer_tunnel" {
  account_id    = var.account_id
  name          = "Terraform Zamorak Portainer tunnel"
  config_src    = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "portainer_tunnel_token" {
  account_id   = var.account_id
  tunnel_id   = cloudflare_zero_trust_tunnel_cloudflared.portainer_tunnel.id
}

resource "cloudflare_dns_record" "portainer_dns_record" {
  zone_id = var.zone_id
  name    = "portainer.${var.zone}"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.portainer_tunnel.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "[terraform] Portainer Ingress Controller DNS record"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "portainer_tunnel_config" {
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.portainer_tunnel.id
  account_id = var.account_id
  config     = {
    ingress   = [
      {
        hostname = "*.${var.zone}"
        service  = "http://portainer:9000"
      },
      {
        service  = "http_status:404"
      }
    ]
  }
}
