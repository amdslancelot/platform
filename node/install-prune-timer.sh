#!/usr/bin/env bash
#
# Install/refresh the image-prune timer on the node. Platform-owned node-level
# maintenance: no app repo installs this, because all four deploy paths leak
# into the same two image stores.
#
# Usage (as root, from the platform checkout on the node):
#   sudo bash node/install-prune-timer.sh
#
# Idempotent: re-running only re-copies the units and reloads systemd. It does
# not fire a prune — run `sudo systemctl start prune-images.service` for that,
# or `sudo DRY_RUN=1 bash node/prune-images.sh` to see the plan first.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The unit's ExecStart is an absolute path into the checkout; installing from
# somewhere else would produce a timer that fires and immediately fails.
EXPECTED="/home/opc/platform/node"
if [ "${SCRIPT_DIR}" != "${EXPECTED}" ]; then
  echo "ERROR: run this from ${EXPECTED} (prune-images.service hard-codes that path)." >&2
  echo "       Current location: ${SCRIPT_DIR}" >&2
  exit 1
fi

echo "==> Installing prune-images.{service,timer}"
# The unit runs the script straight out of the checkout, so the executable bit
# has to survive a fresh clone that didn't preserve it.
chmod 0755 "${SCRIPT_DIR}/prune-images.sh"
install -o root -g root -m 0644 "${SCRIPT_DIR}/prune-images.service" /etc/systemd/system/prune-images.service
install -o root -g root -m 0644 "${SCRIPT_DIR}/prune-images.timer" /etc/systemd/system/prune-images.timer

systemctl daemon-reload
systemctl enable --now prune-images.timer

echo "==> Done. Next run:"
systemctl list-timers prune-images.timer --no-pager
