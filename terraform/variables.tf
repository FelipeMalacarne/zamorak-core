variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "felipemalacarne"
}

variable "gcp_region" {
  description = "GCP Region"
  type        = string
  default     = "southamerica-east1"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID for your domain"
  type        = string
}

variable "cloudflare_zone" {
  description = "Domain used to expose the zamorak VM instance to the Internet"
  type        = string
}
