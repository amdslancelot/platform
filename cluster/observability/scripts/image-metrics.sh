#!/usr/bin/env bash
# Emit Prometheus textfile metrics for the node's container-image footprint.
# Runs on the HOST as root (via observability-metrics.timer), NOT in a pod — it
# needs host tooling (k3s crictl) and host paths that no container should see.
#
# Two views, because they answer different questions:
#   * crictl inventory  -> HOW MANY images, and each image's LOGICAL size.
#     Good for spotting old/untagged images that never got pruned.
#   * du on the stores  -> ACTUAL bytes on the 200GB boot volume. Layer sharing
#     means this is < sum(logical); this is the real disk-pressure number.
# There are TWO stores because images are built with podman then imported into
# containerd — both consume the disk.
#
# secure_path gotcha (see CLAUDE.md): systemd/root PATH excludes /usr/local/bin,
# so k3s is called by full path. Output is written atomically (temp + mv in the
# same dir) so node-exporter never reads a half-written file.
set -euo pipefail

OUT_DIR="/var/lib/node_exporter/textfile_collector"
K3S="/usr/local/bin/k3s"
CONTAINERD_STORE="/var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content"
PODMAN_STORE="/var/lib/containers/storage"

mkdir -p "$OUT_DIR"
tmp="$(mktemp "$OUT_DIR/.image_metrics.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

imgs_json="$("$K3S" crictl images --output json 2>/dev/null || echo '{"images":[]}')"
count="$(echo "$imgs_json" | jq '.images | length')"
logical_total="$(echo "$imgs_json" | jq '[.images[].size | tonumber] | add // 0')"
cd_bytes="$(du -sb "$CONTAINERD_STORE" 2>/dev/null | awk '{print $1+0}')"
podman_bytes="$(du -sb "$PODMAN_STORE" 2>/dev/null | awk '{print $1+0}')"

{
  echo "# HELP containerd_images_total Number of images in containerd's k8s.io namespace."
  echo "# TYPE containerd_images_total gauge"
  echo "containerd_images_total ${count}"

  echo "# HELP containerd_images_logical_size_bytes Sum of per-image logical sizes (pre layer-sharing; > actual disk)."
  echo "# TYPE containerd_images_logical_size_bytes gauge"
  echo "containerd_images_logical_size_bytes ${logical_total}"

  echo "# HELP image_store_disk_bytes Actual on-disk bytes of an image store (real disk pressure)."
  echo "# TYPE image_store_disk_bytes gauge"
  echo "image_store_disk_bytes{store=\"containerd\"} ${cd_bytes}"
  echo "image_store_disk_bytes{store=\"podman\"} ${podman_bytes}"

  echo "# HELP container_image_logical_size_bytes Per-image logical size, labelled by tag/id."
  echo "# TYPE container_image_logical_size_bytes gauge"
  echo "$imgs_json" | jq -r '
    .images[]
    | ((.repoTags // [])[0] // .id) as $name
    | "container_image_logical_size_bytes{image=\"" + ($name | gsub("\"";"")) + "\"} " + (.size|tostring)'
} > "$tmp"

mv "$tmp" "$OUT_DIR/image_metrics.prom"
trap - EXIT
echo "wrote $OUT_DIR/image_metrics.prom (images=$count, containerd_disk=${cd_bytes}B, podman_disk=${podman_bytes}B)"
