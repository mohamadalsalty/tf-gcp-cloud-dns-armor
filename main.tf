terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
  # terraform_data is built-in (Terraform >= 1.4) — no extra provider needed
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable all GCP APIs needed for this PoC
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "dns.googleapis.com",
    "pubsub.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "iam.googleapis.com",
    "artifactregistry.googleapis.com",
    "iap.googleapis.com",
    "eventarc.googleapis.com",
    "networksecurity.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# GCP API activation can take up to 60s to propagate across regions.
# This wait runs once after all APIs are enabled, before any resource
# that would fail with "API not enabled" (e.g. Eventarc, Cloud Run).
resource "time_sleep" "api_propagation" {
  create_duration = "60s"
  depends_on      = [google_project_service.apis]
}
