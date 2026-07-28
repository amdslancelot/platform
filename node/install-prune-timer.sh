#!/usr/bin/env bash
#
# Install/refresh the image-prune timer on the node. Platform-owned node-level
# maintenance: no app repo installs this, because all four deploy paths leak
# into the same two image stores.
#
# Usage (as root, from the platform checkout on the node):
#   sudo bash node/install-prune-timer.sh
#
# Idempotent: re-running re-copies the script and units and reloads systemd.
# It does not fire a prune — for that:
#   sudo DRY_RUN=1 /usr/local/sbin/prune-images.sh   # show the plan
#   sudo systemctl start prune-images.service        # actually prune
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/usr/local/sbin/prune-images.sh"

# The script is COPIED out of the checkout rather than run from it. SELinux is
# Enforcing on this node and everything under /home is user_home_t, which
# systemd's init_t cannot execute: running ExecStart against the checkout fails
# with 203/EXEC "Permission denied", which reads like a chmod problem and is
# not one. /usr/local/sbin gets bin_t, same as the webhook binary next door.
# Corollary: re-run this script after every `git pull` that touches
# prune-images.sh, or the node keeps executing the previous copy.
echo "==> Installing ${TARGET}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/prune-images.sh" "${TARGET}"
command -v restorecon >/dev/null 2>&1 && restorecon "${TARGET}"

echo "==> Installing prune-images.{service,timer}"
install -o root -g root -m 0644 "${SCRIPT_DIR}/prune-images.service" /etc/systemd/system/prune-images.service
install -o root -g root -m 0644 "${SCRIPT_DIR}/prune-images.timer" /etc/systemd/system/prune-images.timer

systemctl daemon-reload
systemctl enable --now prune-images.timer

echo "==> Done. Next run:"
systemctl list-timers prune-images.timer --no-pager
