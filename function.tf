# --------------------------------------------------------------------------
# GCS bucket — stores the Cloud Function source zip
# --------------------------------------------------------------------------
resource "google_storage_bucket" "function_src" {
  name                        = "${var.project_id}-dns-armor-fn-src"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true # PoC: bucket deleted with contents on destroy
}

# Zip the function_source/ directory; re-uploaded only when content changes
data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/function_source"
  output_path = "${path.module}/.build/function_source.zip"
}

resource "google_storage_bucket_object" "function_zip" {
  name   = "function_source_${data.archive_file.function_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_src.name
  source = data.archive_file.function_zip.output_path
}

# --------------------------------------------------------------------------
# Cloud Function (Gen 2 / Cloud Run Functions)
#
# Triggered by every message published to the block-domain Pub/Sub topic.
# Calls the Cloud DNS API to add or remove a Response Policy Rule.
# --------------------------------------------------------------------------
resource "google_cloudfunctions2_function" "block_domain" {
  name        = "dns-armor-block-domain"
  location    = var.region
  description = "Adds/removes blocked domains in Cloud DNS RPZ via Pub/Sub messages"

  build_config {
    runtime         = "python311"
    entry_point     = "block_domain" # must match the function name in main.py
    service_account = google_service_account.function_build_sa.id

    source {
      storage_source {
        bucket = google_storage_bucket.function_src.name
        object = google_storage_bucket_object.function_zip.name
      }
    }
  }

  service_config {
    min_instance_count    = 0   # scale to zero when idle (PoC cost saving)
    max_instance_count    = 3
    available_memory      = "256M"
    timeout_seconds       = 60
    service_account_email = google_service_account.function_sa.email

    environment_variables = {
      PROJECT_ID           = var.project_id
      RESPONSE_POLICY_NAME = google_dns_response_policy.rpz.response_policy_name
    }
  }

  # Pub/Sub CloudEvent trigger — fires on every new message
  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.block_domain.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.function_sa.email
  }

  depends_on = [
    google_project_service.apis,
    time_sleep.api_propagation,
    google_project_iam_member.build_sa_builder,
    google_project_iam_member.build_sa_ar_writer,
    google_project_iam_member.build_sa_storage_admin,
    google_project_iam_member.build_sa_log_writer,
    google_service_account_iam_member.gcf_agent_acts_as_build_sa,
  ]
}
