#!/usr/bin/env bash
#
# Generic bootstrap of an Oracle Linux 9 ARM (aarch64) OCI instance into the
# shared single-node k3s host for the whole fleet (snoopy / gelp / transigen /
# my_website). Platform-owned: extracted from gelp/deploy/setup-server.sh
# (de-gelp-ified) and reconciled with snoopy_home/docs/prod-k3s-runbook.md.
#
# App-specific setup (cloning /opt/<app>, app secrets, webhook hook entries)
# does NOT belong here — each app repo's own setup script handles that, and
# install-webhook.sh (next to this file) owns the webhook listener.
#
# Idempotent; safe to re-run. On a stock OCI image the first run stops once on
# purpose (nm-cloud-setup + mandatory reboot), re-run after rebooting.
#
# Usage:  sudo bash bootstrap-node.sh
#
# RECONCILED DECISION — Traefik/servicelb are ENABLED here. snoopy's original
# runbook installed k3s with `--disable traefik --disable servicelb` (the bot
# alone needed no ingress). The shared node serves gelp/transigen/my_website
# on 80/443, so the fleet needs both. Adopting the EXISTING snoopy-built node:
# re-run the k3s installer as below — it rewrites the systemd unit and
# restarts k3s (running pods keep running; containerd is untouched), and k3s
# then auto-deploys its packaged Traefik + servicelb.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

if [ "$(uname -m)" != "aarch64" ]; then
  echo "WARNING: expected aarch64, found $(uname -m) — proceeding anyway." >&2
fi

# --- 1. Packages ------------------------------------------------------------
# podman: image builds (all apps build on-node, no registry). container-selinux:
# dependency of the k3s-selinux policy RPM; SELinux stays enforcing. gettext:
# envsubst for apps that render manifests. jq: hooks.json rendering.
echo "==> Installing packages"
dnf -y install git curl jq tar gettext podman container-selinux policycoreutils

# --- 2. nm-cloud-setup (k3s requirement on RHEL-family cloud images) --------
needs_reboot=0
for unit in nm-cloud-setup.service nm-cloud-setup.timer; do
  if systemctl is-enabled "$unit" >/dev/null 2>&1; then
    echo "==> Disabling $unit (required by k3s)"
    systemctl disable --now "$unit"
    needs_reboot=1
  fi
done
if [ "$needs_reboot" -ne 0 ]; then
  echo "############################################################"
  echo "# nm-cloud-setup disabled. REBOOT REQUIRED before k3s."
  echo "#   1. sudo reboot"
  echo "#   2. re-run this script (idempotent; it picks up here)"
  echo "############################################################"
  exit 0
fi

# --- 3. firewalld off (k3s docs; the OCI security list is the packet filter) -
if systemctl is-enabled firewalld >/dev/null 2>&1; then
  echo "==> Disabling firewalld"
  systemctl disable --now firewalld
fi

# --- 4. k3s — WITH Traefik + servicelb (see header). --------------------------
# --write-kubeconfig-mode 644 keeps bare kubectl working for the non-root SSH
# deploy user (snoopy's CI relies on this).
# Re-running the installer on an existing node updates flags/version and
# restarts k3s; workloads survive.
echo "==> Installing/updating k3s (Traefik + servicelb enabled)"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -

echo "==> Waiting for the k3s node to be Ready"
for i in $(seq 1 60); do
  /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
  echo "    waiting (${i}/60)..."; sleep 5
done

mkdir -p /root/.kube
ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /etc/rancher/k3s/k3s.yaml

# Non-interactive `sudo k3s ctr images import` for snoopy's CI (SSH deploy):
if [ ! -f /etc/sudoers.d/k3s-ctr ]; then
  echo "==> Allowing passwordless sudo for k3s (CI image imports)"
  echo 'opc ALL=(ALL) NOPASSWD: /usr/local/bin/k3s' > /etc/sudoers.d/k3s-ctr
fi

echo "==> Verifying Traefik is up (fleet needs 80/443)"
/usr/local/bin/k3s kubectl -n kube-system rollout status deployment/traefik --timeout=180s || \
  echo "WARNING: Traefik not Available yet — check: kubectl -n kube-system get pods"

cat <<'EOF'

############################################################
# Node bootstrap complete. Next (docs/runbook.md):
#   1. OCI security list: ingress TCP 22, 80, 443, 9000
#   2. cluster/: namespaces, data-postgres, cert-manager,
#      traefik (TLSStore + www redirect)
#   3. bootstrap/install-webhook.sh  (push-to-deploy listener)
#   4. Per-app setup from each app repo
############################################################
EOF
