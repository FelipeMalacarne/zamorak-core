output "tunnel_token" {
  description = "Cloudflare Tunnel Token"
  value       = module.cloudflare.tunnel_token
  sensitive   = true
}

output "tunnel_cname" {
  description = "Cloudflare Tunnel CNAME"
  value       = module.cloudflare.tunnel_cname
}