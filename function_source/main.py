"""
DNS Armor — Block Function (Gen 2)

Handles two message formats on the same Pub/Sub topic:

  1. Manual command:
       {"domain": "evil.com", "action": "block"}
       {"domain": "evil.com", "action": "unblock"}

  2. DNS Armor threat finding (Cloud Logging LogEntry from Log Router):
       {"jsonPayload": {"dnsQuery": {"queryName": "evil.com."}, "threatInfo": {"severity": "High", "type": "C2"}}}
       High/Medium severity → auto-block; Low/Info → log only.
"""

import base64
import json
import logging
import os
import re

import functions_framework
from googleapiclient import discovery
from googleapiclient.errors import HttpError

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PROJECT_ID = os.environ["PROJECT_ID"]
RESPONSE_POLICY_NAME = os.environ["RESPONSE_POLICY_NAME"]
SINKHOLE_IP = "0.0.0.0"
AUTO_BLOCK_SEVERITIES = {"High", "Medium"}


@functions_framework.cloud_event
def block_domain(cloud_event):
    raw = cloud_event.data.get("message", {}).get("data", "")

    try:
        payload = json.loads(base64.b64decode(raw).decode("utf-8"))
    except Exception as exc:
        logger.error("Could not decode message: %s", exc)
        return

    # DNS Armor log entries (from Log Router) have a "jsonPayload" wrapper
    if "jsonPayload" in payload:
        _handle_dns_armor(payload)
    else:
        _handle_manual(payload)


def _handle_dns_armor(log_entry: dict) -> None:
    """Parse a DNS Armor Cloud Logging entry and auto-block the domain."""
    inner = log_entry.get("jsonPayload", {})
    domain = inner.get("dnsQuery", {}).get("queryName", "").strip().lower()
    severity = inner.get("threatInfo", {}).get("severity", "Low").title()
    threat_type = inner.get("threatInfo", {}).get("type", "unknown")

    if not domain:
        logger.warning("DNS Armor finding has no queryName — skipping")
        return

    if severity not in AUTO_BLOCK_SEVERITIES:
        logger.info("Severity %s on '%s' (%s) — log only, not blocking", severity, domain, threat_type)
        return

    logger.info("DNS Armor: %s threat (severity=%s) on '%s' — blocking", threat_type, severity, domain)
    fqdn, rule_name = _normalize(domain)
    dns = discovery.build("dns", "v1", cache_discovery=False)
    _block(dns, fqdn, rule_name)


def _handle_manual(payload: dict) -> None:
    """Handle a manual {"domain": "...", "action": "block/unblock"} command."""
    domain = payload.get("domain", "").strip().lower()
    action = payload.get("action", "block").lower()

    if not domain:
        logger.error("Manual message missing 'domain' field")
        return

    fqdn, rule_name = _normalize(domain)
    dns = discovery.build("dns", "v1", cache_discovery=False)

    if action == "block":
        _block(dns, fqdn, rule_name)
    elif action == "unblock":
        _unblock(dns, rule_name)
    else:
        logger.error("Unknown action '%s' — use 'block' or 'unblock'", action)


def _normalize(domain: str):
    fqdn = domain if domain.endswith(".") else domain + "."
    rule_name = re.sub(r"[^a-z0-9-]", "-", domain.rstrip("."))[:63].strip("-")
    return fqdn, rule_name


def _block(dns, fqdn: str, rule_name: str) -> None:
    body = {
        "ruleName": rule_name,
        "dnsName": fqdn,
        "localData": {
            "localDatas": [{"name": fqdn, "type": "A", "ttl": 300, "rrdatas": [SINKHOLE_IP]}]
        },
    }
    try:
        dns.responsePolicyRules().create(
            project=PROJECT_ID, responsePolicy=RESPONSE_POLICY_NAME, body=body
        ).execute()
        logger.info(json.dumps({"action": "blocked", "domain": fqdn, "rule": rule_name}))
    except HttpError as exc:
        if exc.resp.status == 409:
            logger.info("Already blocked: %s", fqdn)
        else:
            raise


def _unblock(dns, rule_name: str) -> None:
    try:
        dns.responsePolicyRules().delete(
            project=PROJECT_ID, responsePolicy=RESPONSE_POLICY_NAME, responsePolicyRule=rule_name
        ).execute()
        logger.info(json.dumps({"action": "unblocked", "rule": rule_name}))
    except HttpError as exc:
        if exc.resp.status == 404:
            logger.info("Rule not found (already unblocked): %s", rule_name)
        else:
            raise
