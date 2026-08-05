#!/usr/bin/env bash
#
# Install/refresh the public fleet-snapshot timer.
#
# Usage (as root, from the platform checkout on the node):
#   sudo bash cluster/observability/scripts/install-public-metrics.sh
#
# It prompts for the metrics:read token unless /etc/observability/public-metrics.env
# already exists. Re-running with the env file present never re-prompts, so this
# is safe to run after every `git pull`.
#
# 安裝/更新公開快照 timer。env 檔已存在時不會再問 token,所以每次 git pull 後
# 直接重跑即可。
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="/etc/observability"
ENV_FILE="${ENV_DIR}/public-metrics.env"

# --- credentials -----------------------------------------------------------
# The token goes in a root-only file, never in git and never in a shell history.
#
# This is a metrics:READ token, unlike the write-only one Alloy uses (runbook
# §0c). Two separate access policies, never one policy with both scopes — so
# revoking either does not take down the other.
#
# On the exposure question, stated plainly rather than hidden: this read token
# sits on an internet-reachable node, which runbook §0c's argument was written
# to avoid. It is acceptable here for one specific reason — root on this node
# can already read every one of these metrics at its source (kubectl, the
# node-exporter endpoint, the Postgres socket). A token that reads the aggregate
# of the same data grants an attacker who already has root nothing new. It would
# NOT be acceptable to hand this token to anything less privileged than root,
# which is why the browser never sees it and why the file is 0600.
#
# 這是 metrics:read token,跟 Alloy 那支 write-only 的是兩組獨立 policy。它放在
# 一台對外可達的節點上 —— 可接受的理由是:能拿到這台 root 的人本來就讀得到這些
# 指標的來源。對權限低於 root 的東西就不可接受,所以瀏覽器永遠看不到它。
if [ ! -f "$ENV_FILE" ]; then
  echo "==> No ${ENV_FILE} — creating it."
  echo "    Portal -> Access Policies -> the metrics:read policy (runbook §0c, optional part)"
  read -rp "Prometheus query URL (e.g. https://prometheus-prod-65-prod-eu-west-2.grafana.net/api/prom): " Q_URL
  read -rp "Instance ID / username: " Q_USER
  read -rsp "metrics:read token (glc_… , not echoed): " Q_TOKEN; echo

  [ -n "$Q_URL" ] && [ -n "$Q_USER" ] && [ -n "$Q_TOKEN" ] || {
    echo "ERROR: all three values are required." >&2; exit 1; }

  install -d -o root -g root -m 0700 "$ENV_DIR"
  # Write with a restrictive umask so the token is never briefly world-readable.
  ( umask 077; cat > "$ENV_FILE" <<EOF
# metrics:READ token for the public fleet snapshot. 0600, root-only.
# Rotate by editing this file and running: systemctl start public-metrics.service
PROM_QUERY_URL=${Q_URL}
PROM_USER=${Q_USER}
PROM_READ_TOKEN=${Q_TOKEN}
EOF
  )
  chown root:root "$ENV_FILE"; chmod 0600 "$ENV_FILE"
  echo "==> Wrote ${ENV_FILE} (0600 root)"
else
  echo "==> ${ENV_FILE} exists — leaving credentials untouched."
fi

# --- script + units --------------------------------------------------------
# Copied out of the checkout, not run from it: SELinux is Enforcing and /home is
# user_home_t, which systemd's init_t cannot execute — a unit pointing into
# ~opc/platform fails 203/EXEC and reads like a chmod problem. Same reason as
# install-metrics-timer.sh.
echo "==> Installing /usr/local/sbin/public-metrics.sh"
install -o root -g root -m 0755 "${SCRIPT_DIR}/public-metrics.sh" /usr/local/sbin/public-metrics.sh
command -v restorecon >/dev/null 2>&1 && restorecon /usr/local/sbin/public-metrics.sh

echo "==> Installing public-metrics.{service,timer}"
install -o root -g root -m 0644 "${SCRIPT_DIR}/public-metrics.service" /etc/systemd/system/public-metrics.service
install -o root -g root -m 0644 "${SCRIPT_DIR}/public-metrics.timer"   /etc/systemd/system/public-metrics.timer

systemctl daemon-reload
systemctl enable --now public-metrics.timer

echo "==> Producing the first snapshot now"
systemctl start public-metrics.service || {
  echo "First run failed — see: journalctl -u public-metrics.service -n 40" >&2; exit 1; }

echo "==> Done. Next run:"
systemctl list-timers public-metrics.timer --no-pager
echo
echo "Verify the published snapshot:"
echo "  kubectl -n web get configmap fleet-public-metrics -o jsonpath='{.data.data\\.json}' | jq ."
