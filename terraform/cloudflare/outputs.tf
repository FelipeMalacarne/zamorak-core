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