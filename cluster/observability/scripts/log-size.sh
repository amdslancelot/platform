#!/usr/bin/env bash
# Emit Prometheus textfile metrics for container-log size, per pod and total.
# Runs on the HOST as root (via observability-metrics.timer). k3s/containerd
# writes each container's stdout/stderr under /var/log/pods/<ns>_<pod>_<uid>/;
# this measures those directories so you can see log growth per app (the dir
# name carries the namespace, i.e. the app).
#
# NOTE: this MEASURES size only. Bounding it is containerd log rotation
# (max_size/max_file) — see runbook.md. Monitoring without a rotation cap will
# still let logs fill the 200GB disk; do both.
set -euo pipefail

OUT_DIR="/var/lib/node_exporter/textfile_collector"
POD_LOG_DIR="/var/log/pods"

mkdir -p "$OUT_DIR"
tmp="$(mktemp "$OUT_DIR/.log_size.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# 0600 from mktemp would be unreadable by node-exporter, which runs as `nobody`.
# See the same note in image-metrics.sh — the failure mode is a silently missing
# metric, not an error.
chmod 0644 "$tmp"

{
  echo "# HELP pod_log_dir_size_bytes Size of a pod's on-host container-log directory."
  echo "# TYPE pod_log_dir_size_bytes gauge"
  total=0
  if [ -d "$POD_LOG_DIR" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      name="$(basename "$d")"        # <namespace>_<pod>_<uid>
      ns="${name%%_*}"
      bytes="$(du -sb "$d" 2>/dev/null | awk '{print $1+0}')"
      total=$((total + bytes))
      echo "pod_log_dir_size_bytes{namespace=\"${ns}\",pod_dir=\"${name}\"} ${bytes}"
    done < <(find "$POD_LOG_DIR" -mindepth 1 -maxdepth 1 -type d)
  fi
  echo "# HELP pod_log_total_bytes Total size of all pod container-log directories."
  echo "# TYPE pod_log_total_bytes gauge"
  echo "pod_log_total_bytes ${total}"
} > "$tmp"

mv "$tmp" "$OUT_DIR/log_size.prom"
trap - EXIT
echo "wrote $OUT_DIR/log_size.prom"
