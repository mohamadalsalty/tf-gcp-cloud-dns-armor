# --------------------------------------------------------------------------
# Pub/Sub — event bus for block/unblock domain commands
#
# Publish a message here to dynamically update the DNS Response Policy:
#   {"domain": "evil.com", "action": "block"}
#   {"domain": "evil.com", "action": "unblock"}
# --------------------------------------------------------------------------

resource "google_pubsub_topic" "block_domain" {
  name = "dns-armor-block-domain"

  # Retain undelivered messages for 1 day before discarding
  message_retention_duration = "86400s"

  depends_on = [google_project_service.apis]
}

# Dead-letter topic — receives messages that fail after max_delivery_attempts
resource "google_pubsub_topic" "dead_letter" {
  name = "dns-armor-dead-letter"
}

# Subscription consumed by the Cloud Function event trigger
resource "google_pubsub_subscription" "block_domain" {
  name  = "dns-armor-block-domain-sub"
  topic = google_pubsub_topic.block_domain.name

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  # Cloud Functions Gen 2 manages its own push subscription;
  # this pull subscription is here for manual inspection and the dead-letter chain.
  ack_deadline_seconds = 60
}
