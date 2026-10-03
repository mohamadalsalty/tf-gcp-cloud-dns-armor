# --------------------------------------------------------------------------
# Test VM — used to verify DNS blocking works end-to-end
#
# No public IP. SSH via: gcloud compute ssh dns-armor-test-vm \
#   --zone=<zone> --tunnel-through-iap
#
# Once inside, run:
#   dig malicious-example.com   → should return 0.0.0.0
#   dig google.com              → should return real IP
# --------------------------------------------------------------------------
resource "google_compute_instance" "test_vm" {
  name         = "dns-armor-test-vm"
  machine_type = "e2-micro" # cheapest machine type, adequate for DNS testing
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10 # GB — minimum useful disk size
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.main.id
    # No access_config block = no ephemeral public IP (use IAP for SSH)
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"] # broad scope; VM SA has minimal IAM roles
  }

  metadata = {
    enable-oslogin = "TRUE" # IAP SSH requires OS Login
  }

  # Install dig (dnsutils) on first boot for DNS testing
  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update -q && apt-get install -y dnsutils
  EOT

  tags = ["dns-armor-test"] # matched by the IAP SSH firewall rule

  depends_on = [google_project_service.apis]
}
