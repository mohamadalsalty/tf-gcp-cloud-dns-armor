# --------------------------------------------------------------------------
# Service account — Cloud Function
# Needs dns.admin to create/delete Response Policy Rules at runtime.
# --------------------------------------------------------------------------
resource "google_service_account" "function_sa" {
  account_id   = "dns-armor-function-sa"
  display_name = "DNS Armor Cloud Function"
  description  = "Used by the block-domain function to modify Cloud DNS RPZ rules"
}

resource "google_project_iam_member" "function_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

# Cloud Functions (Gen 2) runs on Cloud Run — it needs to invoke itself
resource "google_project_iam_member" "function_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

# --------------------------------------------------------------------------
# Service account — test VM
# Only needs to publish to the block-domain topic (principle of least privilege).
# --------------------------------------------------------------------------
resource "google_service_account" "vm_sa" {
  account_id   = "dns-armor-vm-sa"
  display_name = "DNS Armor Test VM"
  description  = "Used by the test VM to publish block/unblock messages to Pub/Sub"
}

resource "google_pubsub_topic_iam_member" "vm_publisher" {
  topic  = google_pubsub_topic.block_domain.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.vm_sa.email}"
}

# --------------------------------------------------------------------------
# Allow Cloud Functions to acknowledge messages from the dead-letter topic
# (required by the dead-letter policy)
# --------------------------------------------------------------------------
data "google_project" "current" {}

# --------------------------------------------------------------------------
# Cloud Build service account — Gen 2 Cloud Functions build via Cloud Build.
# In fresh projects these roles are not auto-granted, causing build failures
# with "missing permission on build service account".
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# Dedicated build service account for the Cloud Function
#
# Using a custom build SA in build_config.service_account makes Cloud
# Functions grant this SA direct access to the staged source in the
# internal gcf-v2-sources-* bucket, bypassing default Cloud Build SA
# permission issues in fresh/org-policy-restricted projects.
# --------------------------------------------------------------------------
resource "google_service_account" "function_build_sa" {
  account_id   = "dns-armor-build-sa"
  display_name = "DNS Armor Function Build SA"
  description  = "Used by Cloud Build to build the dns-armor Cloud Function container"
}

# Allows the SA to run Cloud Build steps
resource "google_project_iam_member" "build_sa_builder" {
  project    = var.project_id
  role       = "roles/cloudbuild.builds.builder"
  member     = "serviceAccount:${google_service_account.function_build_sa.email}"
  depends_on = [google_project_service.apis]
}

# Allows the SA to push the built container image to Artifact Registry
resource "google_project_iam_member" "build_sa_ar_writer" {
  project    = var.project_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.function_build_sa.email}"
  depends_on = [google_project_service.apis]
}

# Allows the SA to read/write build artifacts and the staged source zip
resource "google_project_iam_member" "build_sa_storage_admin" {
  project    = var.project_id
  role       = "roles/storage.objectAdmin"
  member     = "serviceAccount:${google_service_account.function_build_sa.email}"
  depends_on = [google_project_service.apis]
}

# Allows the SA to write build logs
resource "google_project_iam_member" "build_sa_log_writer" {
  project    = var.project_id
  role       = "roles/logging.logWriter"
  member     = "serviceAccount:${google_service_account.function_build_sa.email}"
  depends_on = [google_project_service.apis]
}

# The Cloud Functions service agent must be able to act as the build SA
# Pub/Sub service agent needs to mint OIDC tokens for the trigger SA
# so it can make authenticated push calls to the Cloud Run endpoint
resource "google_service_account_iam_member" "pubsub_token_creator_block" {
  service_account_id = google_service_account.function_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# --------------------------------------------------------------------------
# Eventarc service agent — needs run.invoker to push Pub/Sub events to the
# Cloud Run endpoints backing both Gen 2 Cloud Functions.
# Without this the trigger gets HTTP 403 on every delivery attempt.
# --------------------------------------------------------------------------
resource "google_project_iam_member" "eventarc_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-eventarc.iam.gserviceaccount.com"
  depends_on = [google_project_service.apis]
}

resource "google_service_account_iam_member" "gcf_agent_acts_as_build_sa" {
  service_account_id = google_service_account.function_build_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcf-admin-robot.iam.gserviceaccount.com"
}

# --------------------------------------------------------------------------
# Allow Cloud Functions to acknowledge messages from the dead-letter topic
# (required by the dead-letter policy)
# --------------------------------------------------------------------------
resource "google_pubsub_subscription_iam_member" "deadletter_subscriber" {
  subscription = google_pubsub_subscription.block_domain.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "deadletter_publisher" {
  topic  = google_pubsub_topic.dead_letter.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
