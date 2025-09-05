variable "api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "zone_id" {
  description = "Zone ID for your domain"
  type        = string
}

variable "zone" {
  description = "Domain used to expose the zamorak VM instance to the Internet"
  type        = string
}

variable "traefik_host" {
  description = "Host to point traefik DNS to"
  type = string
}
