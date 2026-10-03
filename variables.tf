variable "project_id" {
  description = "GCP project ID where resources will be deployed"
  type        = string
}

variable "region" {
  description = "GCP region for all regional resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the test VM"
  type        = string
  default     = "us-central1-a"
}

variable "alert_email" {
  description = "Email address to receive monitoring alerts"
  type        = string
}

# Seed list — the Cloud Function can add more at runtime via Pub/Sub
variable "blocked_domains" {
  description = "Initial domains to block in the DNS Response Policy (PoC seed list)"
  type        = list(string)
  default     = [
    "malicious-example.com",
    "phishing-test.example.com",
  ]
}
