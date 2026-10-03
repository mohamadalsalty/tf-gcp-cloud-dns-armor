# --------------------------------------------------------------------------
# VPC — single custom-mode network, no auto-subnets
# --------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "dns-armor-vpc"
  auto_create_subnetworks = false
  description             = "PoC network for DNS filtering with Cloud DNS RPZ"

  depends_on = [google_project_service.apis]
}

# /29 = 8 IPs total, 6 usable hosts — smallest practical subnet for a PoC VM
resource "google_compute_subnetwork" "main" {
  name                     = "dns-armor-subnet"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.10.0.0/29"
  private_ip_google_access = true # reach Google APIs without a public IP
  description              = "/29 = 6 usable IPs, enough for one test VM"
}

# --------------------------------------------------------------------------
# Cloud NAT — lets the VM download packages without a public IP
# --------------------------------------------------------------------------
resource "google_compute_router" "router" {
  name    = "dns-armor-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "dns-armor-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# --------------------------------------------------------------------------
# Firewall rules
# --------------------------------------------------------------------------

# SSH via Identity-Aware Proxy only — no public firewall hole needed
resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "dns-armor-allow-iap-ssh"
  network     = google_compute_network.vpc.name
  description = "Allow SSH from IAP to tagged VMs (35.235.240.0/20 is Google's IAP range)"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["dns-armor-test"]
}
