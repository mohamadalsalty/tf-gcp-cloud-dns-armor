# --------------------------------------------------------------------------
# Cloud DNS Policy — enables query logging for all VMs in this VPC.
# Query logs land in Cloud Logging and feed the monitoring metrics below.
# --------------------------------------------------------------------------
resource "google_dns_policy" "logging" {
  name           = "dns-armor-logging-policy"
  enable_logging = true
  description    = "Enables Cloud DNS query logging for the PoC VPC"

  networks {
    network_url = google_compute_network.vpc.self_link
  }
}

# --------------------------------------------------------------------------
# Cloud DNS Response Policy (RPZ equivalent)
#
# A Response Policy is attached to a VPC network. Any DNS query that
# originates from a VM in this VPC is checked against the rules below
# BEFORE being forwarded to upstream resolvers.
#
# When a rule matches, Cloud DNS returns the local_data answer (0.0.0.0)
# instead of the real IP — effectively sinkholing the domain.
# --------------------------------------------------------------------------
resource "google_dns_response_policy" "rpz" {
  response_policy_name = "dns-armor-rpz"
  description          = "Sinkhole policy — matched domains resolve to 0.0.0.0"

  networks {
    network_url = google_compute_network.vpc.self_link
  }

  depends_on = [google_project_service.apis]
}

# Purge all RPZ rules (including dynamically added ones) before destroying
# the policy. Without this, destroy fails with "containerNotEmpty" because
# rules added at runtime by the Cloud Function are not in Terraform state.
resource "terraform_data" "rpz_cleanup" {
  # Store everything needed at destroy time in triggers_replace —
  # destroy provisioners can only reference self, not var.*
  triggers_replace = {
    policy_name = google_dns_response_policy.rpz.response_policy_name
    project_id  = var.project_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      for rule in $(gcloud dns response-policies rules list ${self.triggers_replace.policy_name} \
        --project=${self.triggers_replace.project_id} --format="value(ruleName)" 2>/dev/null); do
        gcloud dns response-policies rules delete "$rule" \
          --response-policy=${self.triggers_replace.policy_name} \
          --project=${self.triggers_replace.project_id} --quiet
      done
    EOT
  }
}

# --------------------------------------------------------------------------
# Pre-seeded block rules (Terraform-managed static blocklist)
#
# For runtime blocking use the Cloud Function via Pub/Sub instead.
# Domains added here will be destroyed when you run `terraform destroy`.
# --------------------------------------------------------------------------
resource "google_dns_response_policy_rule" "blocked" {
  for_each = toset(var.blocked_domains)

  response_policy = google_dns_response_policy.rpz.response_policy_name

  # Rule names must be unique within the policy; dots → dashes
  rule_name = "block-${replace(each.key, ".", "-")}"

  # Full DNS name requires a trailing dot
  dns_name = "${each.key}."

  local_data {
    local_datas {
      name = "${each.key}."
      type = "A"
      ttl  = 300

      # 0.0.0.0 = sinkhole. Change to a honeypot IP to capture traffic.
      rrdatas = ["0.0.0.0"]
    }
  }
}
