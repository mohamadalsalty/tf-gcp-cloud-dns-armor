# --------------------------------------------------------------------------
# Email notification channel
# --------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  display_name = "DNS Armor Alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

# --------------------------------------------------------------------------
# Log-based metric — counts Cloud Function invocations that block a domain
#
# The Python function emits a structured log line:
#   {"action": "blocked", "domain": "evil.com"} at INFO level.
# This metric counts those lines so we can alert on blocking spikes.
# --------------------------------------------------------------------------
resource "google_logging_metric" "domains_blocked" {
  name        = "dns_armor_domains_blocked"
  description = "Number of domains blocked by the dns-armor Cloud Function"

  # Cloud Run (Gen 2 Functions) logs under this resource type
  filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${google_cloudfunctions2_function.block_domain.name}"
    jsonPayload.action="blocked"
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "DNS Domains Blocked"
  }
}

# --------------------------------------------------------------------------
# Log-based metric — counts Cloud DNS queries that hit the response policy
# (i.e., queries for blocked domains from VMs in the PoC VPC)
# --------------------------------------------------------------------------
resource "google_logging_metric" "rpz_hits" {
  name        = "dns_armor_rpz_hits"
  description = "Cloud DNS queries answered by the RPZ response policy (blocked domains)"

  filter = <<-EOT
    resource.type="dns_query"
    jsonPayload.authAnswer=true
    jsonPayload.queryType="A"
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "DNS RPZ Hits"
  }
}

# --------------------------------------------------------------------------
# Alert: DNS Armor threat detected (any severity)
#
# Uses condition_matched_log — fires directly on log entries, no metric
# warm-up needed. Rate-limited to one notification per 5 minutes.
# --------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "dns_armor_threat" {
  display_name = "DNS Armor: Threat Detected"
  combiner     = "OR"

  conditions {
    display_name = "DNS Armor threat finding in Cloud Logging"

    condition_matched_log {
      filter = "resource.type=\"networksecurity.googleapis.com/DnsThreatDetector\""
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    notification_rate_limit {
      period = "300s" # max one email per 5 minutes — avoids alert spam
    }
    auto_close = "86400s"
  }

  documentation {
    content   = "DNS Armor (Infoblox) detected a threat from a VM in this project. High/Medium findings are auto-blocked via RPZ. Check Cloud Logging: resource.type=\"networksecurity.googleapis.com/DnsThreatDetector\""
    mime_type = "text/markdown"
  }
}

# --------------------------------------------------------------------------
# Alert: RPZ block triggered (a blocked domain was queried)
#
# Fires when Cloud DNS returns 0.0.0.0 (our sinkhole IP) for a query.
# Confirms the RPZ rule is working and a VM tried to reach a blocked domain.
# --------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "rpz_block" {
  display_name = "DNS Armor: RPZ Block Triggered"
  combiner     = "OR"

  conditions {
    display_name = "DNS query returned sinkhole IP 0.0.0.0"

    condition_matched_log {
      filter = <<-EOT
        resource.type="dns_query"
        jsonPayload.rrdatas="0.0.0.0"
      EOT
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "86400s"
  }

  documentation {
    content   = "A VM queried a domain blocked by the DNS Response Policy (RPZ) — it resolved to 0.0.0.0. Check Cloud Logging: resource.type=\"dns_query\" jsonPayload.rrdatas=\"0.0.0.0\""
    mime_type = "text/markdown"
  }
}

# --------------------------------------------------------------------------
# Alert: Cloud Function errors
# --------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "function_errors" {
  display_name = "DNS Armor: Cloud Function Errors"
  combiner     = "OR"

  conditions {
    display_name = "Block or threat handler function logged an error"

    condition_matched_log {
      filter = <<-EOT
        resource.type="cloud_run_revision"
        resource.labels.service_name="${google_cloudfunctions2_function.block_domain.name}"
        severity="ERROR"
      EOT
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "1800s"
  }
}
