#!/usr/bin/env bash
#
# Install/refresh the host textfile-metrics timer (image footprint + log sizes).
# The two scripts run on the HOST as root, not in a pod — they need host tooling
# (k3s crictl) and host paths no container should see.
#
# Usage (as root, from the platform checkout on the node):
#   sudo bash cluster/observability/scripts/install-metrics-timer.sh
#
# Idempotent: re-running re-copies the scripts and units and reloads systemd.
# To produce metrics immediately: sudo systemctl start observability-metrics.service
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The scripts are COPIED out of the checkout rather than run from it. SELinux is
# Enforcing on this node and everything under /home is user_home_t, which
# systemd's init_t cannot execute: a unit whose ExecStart points into
# ~opc/platform fails with 203/EXEC "Permission denied" even at mode 0755 — it
# reads like a chmod problem and is not one. /usr/local/sbin gets bin_t, the
# same label as the webhook binary. Same reason node/prune-images.sh is
# installed rather than run in place.
# Corollary: re-run this after any `git pull` that touches either script, or the
# node keeps producing metrics from the previous copy.
for s in image-metrics.sh log-size.sh; do
  echo "==> Installing /usr/local/sbin/${s}"
  install -o root -g root -m 0755 "${SCRIPT_DIR}/${s}" "/usr/local/sbin/${s}"
  command -v restorecon >/dev/null 2>&1 && restorecon "/usr/local/sbin/${s}"
done

echo "==> Installing observability-metrics.{service,timer}"
install -o root -g root -m 0644 "${SCRIPT_DIR}/observability-metrics.service" /etc/systemd/system/observability-metrics.service
install -o root -g root -m 0644 "${SCRIPT_DIR}/observability-metrics.timer" /etc/systemd/system/observability-metrics.timer

systemctl daemon-reload
systemctl enable --now observability-metrics.timer

echo "==> Done. Next run:"
systemctl list-timers observability-metrics.timer --no-pager
