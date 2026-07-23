#!/usr/bin/env bash
# One-time (idempotent) cert-manager install. Moved out of gelp/deploy/deploy.sh
# — installing cluster-wide infrastructure on every app deploy was the wrong
# place; platform owns it now. Pinned; bump the pin here to upgrade.
set -euo pipefail

CERT_MANAGER_VERSION="v1.15.3"
MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

if kubectl get ns cert-manager >/dev/null 2>&1; then
  echo "==> cert-manager namespace already exists, skipping install"
else
  echo "==> Installing cert-manager ${CERT_MANAGER_VERSION}"
  kubectl apply -f "${MANIFEST}"
fi

echo "==> Waiting for cert-manager deployments to become available"
kubectl wait --for=condition=Available --timeout=180s \
  deployment/cert-manager \
  deployment/cert-manager-webhook \
  deployment/cert-manager-cainjector \
  -n cert-manager

cat <<'EOF'
==> Next (see docs/runbook.md):
    1. Create the Cloudflare API token Secret (in the cert-manager namespace —
       ClusterIssuer solver secrets are read from there):
         kubectl create secret generic cloudflare-api-token -n cert-manager \
           --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
           --dry-run=client -o yaml | kubectl apply -f -
    2. kubectl apply -f cluster/cert-manager/clusterissuer.yaml
    3. kubectl apply -f cluster/namespaces.yaml   # `platform` ns must exist first
       kubectl apply -f cluster/cert-manager/wildcard-certificate.yaml
    4. Watch issuance: kubectl -n platform get certificate lans-h-cc -w
EOF
