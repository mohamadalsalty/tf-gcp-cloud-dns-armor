output "test_vm_name" {
  description = "Name of the test VM"
  value       = google_compute_instance.test_vm.name
}

output "response_policy_name" {
  description = "Cloud DNS Response Policy name (RPZ equivalent)"
  value       = google_dns_response_policy.rpz.response_policy_name
}

output "pubsub_topic" {
  description = "Pub/Sub topic for block/unblock domain commands"
  value       = google_pubsub_topic.block_domain.name
}

output "cloud_function_name" {
  description = "Cloud Function that updates the DNS Response Policy"
  value       = google_cloudfunctions2_function.block_domain.name
}

output "ssh_to_test_vm" {
  description = "SSH into the test VM via Identity-Aware Proxy (no public IP needed)"
  value       = "gcloud compute ssh ${google_compute_instance.test_vm.name} --zone=${var.zone} --tunnel-through-iap"
}

output "block_domain_command" {
  description = "Publish a Pub/Sub message to block a domain at runtime"
  value       = <<-EOT
    gcloud pubsub topics publish ${google_pubsub_topic.block_domain.name} \
      --message='{"domain":"evil-site.com","action":"block"}'
  EOT
}

output "unblock_domain_command" {
  description = "Publish a Pub/Sub message to unblock a domain at runtime"
  value       = <<-EOT
    gcloud pubsub topics publish ${google_pubsub_topic.block_domain.name} \
      --message='{"domain":"evil-site.com","action":"unblock"}'
  EOT
}

output "test_dns_blocking" {
  description = "Run inside the test VM to verify a domain is blocked"
  value       = "dig malicious-example.com  # should return 0.0.0.0"
}

output "view_function_logs" {
  description = "Stream real-time Cloud Function logs"
  value       = "gcloud beta run services logs tail ${google_cloudfunctions2_function.block_domain.name} --region=${var.region}"
}
