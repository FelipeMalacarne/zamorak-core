output "tunnel_token" {
  description = "Cloudflare Tunnel Token"
  value       = module.cloudflare.tunnel_token
  sensitive   = true
}

output "tunnel_cname" {
  description = "Cloudflare Tunnel CNAME"
  value       = module.cloudflare.tunnel_cname
}

output "vw_tunnel_token" {
  description = "Cloudflare Vaultwarden Tunnel Token"
  value       = module.cloudflare.vw_tunnel_token
  sensitive   = true
}