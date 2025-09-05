output "tunnel_id" {
  description = "The ID of the Cloudflare Tunnel"
  value = cloudflare_zero_trust_tunnel_cloudflared.portainer_tunnel.id
}

output "tunnel_token" {
  description = "The token for the Cloudflare Tunnel"
  value      = data.cloudflare_zero_trust_tunnel_cloudflared_token.portainer_tunnel_token.token
  sensitive   = true
}

output "tunnel_cname" {
  description = "The CNAME for the Cloudflare Tunnel"
    value       = cloudflare_dns_record.portainer_dns_record.name
}

output "tunnel_domain" {
  description = "The full domain for the tunnel"
  value = "${cloudflare_dns_record.portainer_dns_record.name}.${var.zone}"
}

output "vw_tunnel_token" {
  description = "The token for the Vaultwarden Cloudflare Tunnel"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.vaultwarden_tunnel_token.token
  sensitive   = true
}