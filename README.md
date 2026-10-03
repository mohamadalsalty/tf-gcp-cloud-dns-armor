# DNS Armor — GCP DNS Filtering PoC

A Terraform proof-of-concept that deploys an automated DNS filtering solution on GCP. When a VM queries a malicious domain, **Cloud DNS Armor** (powered by Infoblox) detects it, a Cloud Function adds a block rule to **Cloud DNS Response Policy (RPZ)**, and all future queries for that domain resolve to `0.0.0.0`.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  VPC: dns-armor-vpc  (10.10.0.0/29 — 6 usable IPs)             │
│                                                                 │
│  ┌──────────────┐  dig evil.com  ┌──────────────────────────┐  │
│  │  Test VM     │ ─────────────► │  Cloud DNS               │  │
│  │  e2-micro    │ ◄── 0.0.0.0 ── │  + Response Policy (RPZ) │  │
│  │  (no pub IP) │                └──────────────────────────┘  │
│  └──────────────┘                           ▲                   │
│        │ SSH via IAP                        │ add RPZ rule      │
└────────┼───────────────────────────────────-│───────────────────┘
         │                                    │
         ▼                              ┌─────┴──────────────┐
   Cloud Shell /                       │  Cloud Function     │
   gcloud CLI                          │  (Python, Gen 2)    │
         │                             └─────────────────────┘
         │ manual block                        ▲
         ▼                                     │ Pub/Sub trigger
   ┌─────────────────┐    Log Router    ┌──────┴───────────┐
   │  Pub/Sub Topic  │ ◄──────────────  │  Cloud DNS Armor │
   │  block-domain   │                  │  (Infoblox)      │
   └─────────────────┘                  └──────────────────┘
                                               ▲
                                        detects threat
                                               │
                                         VM queries
                                          evil.com
```

### How it works

1. A VM in the VPC queries a domain (e.g. `dnst-gcp-blox.com`)
2. **Cloud DNS Armor** (Infoblox) inspects the query asynchronously — no latency added
3. If the domain is malicious (High/Medium severity), Armor writes a threat log to **Cloud Logging**
4. A **Log Router sink** streams the finding to the **block-domain Pub/Sub topic**
5. The **Cloud Function** parses the finding and adds an RPZ rule returning `0.0.0.0`
6. All future queries for that domain from any VM → sinkholed immediately

Manual blocking is also supported by publishing directly to the Pub/Sub topic.

## Files

| File | Purpose |
|------|---------|
| `main.tf` | Provider config, API enablement, propagation wait |
| `variables.tf` | Input variables |
| `network.tf` | VPC, /29 subnet, Cloud NAT, IAP firewall |
| `dns.tf` | Cloud DNS logging policy + Response Policy (RPZ) + seed blocklist |
| `dns_armor_detector.tf` | DNS Armor threat detector, Log Router sink, Pub/Sub IAM |
| `pubsub.tf` | Block-domain topic, subscription, dead-letter |
| `function.tf` | Cloud Function (Gen 2) — source bucket + function resource |
| `vm.tf` | Test VM (e2-micro, IAP SSH, no public IP) |
| `iam.tf` | Service accounts and minimal IAM bindings |
| `monitoring.tf` | Log-based metrics + 3 alert policies + email channel |
| `outputs.tf` | Ready-to-run commands printed after apply |
| `function_source/main.py` | Cloud Function — handles DNS Armor findings + manual commands |
| `function_source/requirements.txt` | Python dependencies |
| `terraform.tfvars.example` | Variable template (copy to `terraform.tfvars`) |

## Prerequisites

- GCP project with billing enabled
- `gcloud` CLI installed and authenticated:
  ```bash
  gcloud auth application-default login
  ```
- Terraform >= 1.5

## Deploy

```bash
# 1. Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars

# 2. Deploy
terraform init
terraform apply
```

> **Note:** First `apply` takes ~5 minutes — it enables APIs, waits for propagation, builds the Cloud Function, and provisions DNS Armor.

## Validate

### 1. SSH into the test VM

```bash
gcloud compute ssh dns-armor-test-vm \
  --zone=us-central1-a --tunnel-through-iap --project=YOUR_PROJECT_ID
```

### 2. Test the seed blocklist

```bash
dig +short malicious-example.com   # → 0.0.0.0 (blocked by RPZ)
dig +short google.com              # → real IP  (not blocked)
```

### 3. Test DNS Armor automatic blocking

Query a domain that Infoblox's threat feed flags (e.g. a known DGA domain):

```bash
dig +short dnst-gcp-blox.com   # first query resolves normally (detection is async)
# wait ~10 seconds
dig +short dnst-gcp-blox.com   # → 0.0.0.0 (auto-blocked by DNS Armor)
```

### 4. Test manual blocking via Pub/Sub

```bash
# Block
gcloud pubsub topics publish dns-armor-block-domain \
  --message='{"domain":"evil-site.com","action":"block"}'

# Verify (from VM)
dig +short evil-site.com   # → 0.0.0.0

# Unblock
gcloud pubsub topics publish dns-armor-block-domain \
  --message='{"domain":"evil-site.com","action":"unblock"}'
```

### 5. View function logs

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" resource.labels.service_name="dns-armor-block-domain"' \
  --project=YOUR_PROJECT_ID --limit=20
```

### 6. List all blocked domains

```bash
gcloud dns response-policies rules list dns-armor-rpz --project=YOUR_PROJECT_ID
```

## Monitoring

Three alert policies send email to `alert_email` when:

| Alert | Trigger |
|-------|---------|
| **DNS Armor: Threat Detected** | DNS Armor logs any finding |
| **DNS Armor: RPZ Block Triggered** | A VM queries a blocked domain (returns 0.0.0.0) |
| **DNS Armor: Cloud Function Errors** | Block function logs an ERROR |

## Subnet sizing

| Subnet | CIDR | Usable IPs | Purpose |
|--------|------|-----------|---------|
| `dns-armor-subnet` | `10.10.0.0/29` | 6 | Test VM |

A `/29` is the smallest practical subnet for a single VM. The Cloud Function is serverless and needs no subnet.

## Cloud Function message formats

The function handles two formats on the same topic:

**DNS Armor finding** (from Log Router — automatic):
```json
{
  "jsonPayload": {
    "dnsQuery": { "queryName": "evil.com." },
    "threatInfo": { "severity": "HIGH", "type": "TI-DGA" }
  }
}
```

**Manual command** (publish directly to topic):
```json
{"domain": "evil.com", "action": "block"}
{"domain": "evil.com", "action": "unblock"}
```

Only `High` and `Medium` severity DNS Armor findings are auto-blocked. `Low` and `Info` are logged only.

## Cleanup

```bash
terraform destroy
```
