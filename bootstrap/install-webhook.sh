#!/usr/bin/env bash
#
# Install/refresh the fleet's push-to-deploy webhook listener (:9000).
# Platform-owned: replaces gelp's setup-server.sh steps 7-9 AND transigen's
# setup-app.sh jq-append — /etc/webhook/hooks.json is now rendered wholesale
# from the ONE tracked template (../webhook/hooks.json), eliminating the
# append relay race between app repos. Adding an app = edit the template here,
# re-run this script with all secrets.
#
# Usage (as root, secrets via environment so they never hit argv/ps):
#   sudo GELP_WEBHOOK_SECRET=... TRANSIGEN_WEBHOOK_SECRET=... \
#        bash install-webhook.sh
#
# Idempotent: unchanged config never bounces a listener that might be serving
# an in-flight delivery.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../webhook/hooks.json"

for var in GELP_WEBHOOK_SECRET TRANSIGEN_WEBHOOK_SECRET; do
  [ -n "${!var:-}" ] || { echo "ERROR: $var is not set." >&2; exit 1; }
done
export GELP_WEBHOOK_SECRET TRANSIGEN_WEBHOOK_SECRET

# --- 1. Pinned webhook binary (linux-arm64) ----------------------------------
WEBHOOK_VERSION="2.8.3"
if /usr/local/bin/webhook -version 2>/dev/null | grep -q "${WEBHOOK_VERSION}"; then
  echo "==> webhook ${WEBHOOK_VERSION} already installed"
else
  echo "==> Installing adnanh/webhook ${WEBHOOK_VERSION}"
  curl -sfL -o /tmp/webhook.tar.gz \
    "https://github.com/adnanh/webhook/releases/download/${WEBHOOK_VERSION}/webhook-linux-arm64.tar.gz"
  rm -rf /tmp/webhook-extract && mkdir -p /tmp/webhook-extract
  tar -xzf /tmp/webhook.tar.gz -C /tmp/webhook-extract
  install -o root -g root -m 0755 /tmp/webhook-extract/webhook-linux-arm64/webhook /usr/local/bin/webhook
  command -v restorecon >/dev/null 2>&1 && restorecon /usr/local/bin/webhook
  rm -rf /tmp/webhook.tar.gz /tmp/webhook-extract
fi

# --- 2. Render hooks.json (secrets substituted via jq env, never argv) -------
echo "==> Rendering /etc/webhook/hooks.json from ${TEMPLATE}"
mkdir -p /etc/webhook
changed=0
jq 'walk(
      if . == "{{GELP_WEBHOOK_SECRET}}"      then env.GELP_WEBHOOK_SECRET
      elif . == "{{TRANSIGEN_WEBHOOK_SECRET}}" then env.TRANSIGEN_WEBHOOK_SECRET
      else . end)' "${TEMPLATE}" > /etc/webhook/hooks.json.new
jq -e . /etc/webhook/hooks.json.new >/dev/null
if ! cmp -s /etc/webhook/hooks.json.new /etc/webhook/hooks.json; then
  install -o root -g root -m 0600 /etc/webhook/hooks.json.new /etc/webhook/hooks.json
  changed=1
fi
rm -f /etc/webhook/hooks.json.new

# --- 3. systemd unit ----------------------------------------------------------
if ! cmp -s "${SCRIPT_DIR}/webhook.service" /etc/systemd/system/webhook.service; then
  install -o root -g root -m 0644 "${SCRIPT_DIR}/webhook.service" /etc/systemd/system/webhook.service
  systemctl daemon-reload
  changed=1
fi
systemctl enable --now webhook.service
[ "${changed}" -ne 0 ] && systemctl restart webhook.service

echo "==> webhook listener ready on :9000 (hooks: deploy, deploy-transigen)"
