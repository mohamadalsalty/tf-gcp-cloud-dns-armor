# --------------------------------------------------------------------------
# Cloud DNS Armor Threat Detector
# --------------------------------------------------------------------------
resource "terraform_data" "dns_armor_detector" {
  triggers_replace = {
    project_id = var.project_id
    name       = "dns-armor-detector"
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud network-security dns-threat-detectors create ${self.triggers_replace.name} \
        --project=${self.triggers_replace.project_id} \
        --location=global \
        --provider=infoblox \
        --quiet
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud network-security dns-threat-detectors delete ${self.triggers_replace.name} \
        --project=${self.triggers_replace.project_id} \
        --location=global \
        --quiet
    EOT
  }

  depends_on = [google_project_service.apis]
}

# --------------------------------------------------------------------------
# Log Router sink — streams DNS Armor findings directly into the block topic.
# The single block function handles both DNS Armor log entries and manual
# block/unblock commands — no second function needed.
# --------------------------------------------------------------------------
resource "google_logging_project_sink" "dns_armor_findings" {
  name        = "dns-armor-findings-sink"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.block_domain.id}"

  filter = <<-EOT
    resource.type="networksecurity.googleapis.com/DnsThreatDetector"
    jsonPayload.threatInfo.severity=("High" OR "Medium")
  EOT

  unique_writer_identity = true
}

# Sink writer identity takes ~30s to propagate before IAM grants work
resource "time_sleep" "log_sink_sa_propagation" {
  create_duration = "30s"
  depends_on      = [google_logging_project_sink.dns_armor_findings]
}

# Grant the sink permission to publish to the block topic
resource "google_pubsub_topic_iam_member" "log_sink_publisher" {
  topic  = google_pubsub_topic.block_domain.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.dns_armor_findings.writer_identity

  depends_on = [time_sleep.log_sink_sa_propagation]
}
