#!/usr/bin/env bash
# Produce the PUBLIC fleet snapshot served at https://lans-h.cc/metrics/data.json
#
# Runs on the HOST as root (via public-metrics.timer). It queries Grafana Cloud
# with a read-only token, reduces the answers to a small fixed JSON document, and
# publishes that document as a ConfigMap which the my_website nginx pod mounts.
#
# WHY THIS SHAPE, and not a self-hosted Grafana:
#   * The public page gets a STATIC FILE. There is no query passthrough, so a
#     visitor cannot ask for anything that is not listed below. An anonymous
#     Grafana would expose a datasource proxy that forwards arbitrary PromQL —
#     that is a redaction bypass, not a dashboard.
#   * Nothing new runs. No Grafana Deployment, no second Ingress. The node's
#     observability namespace is already the heaviest thing on it (README.md).
#   * The read token never reaches a browser. It lives only in
#     /etc/observability/public-metrics.env (0600 root).
#
# REDACTION CONTRACT — read before adding a query.
# my_website/public/topology.html is the security-redacted twin of
# docs/topology.html. Measured against it, these are public already: the app
# names (snoopy/gelp/transigen), Postgres, OCI. These are deliberately NOT:
# the node's IP, the hostname, the :9000 webhook port, and the string "k3s".
# Anything emitted here must stay on the public side of that line, which is why
# the code below is an ALLOWLIST of namespaces and a fixed set of queries, and
# why mountpoints and pod names never appear in the output.
#
# 公開快照產生器。用唯讀 token 查 Grafana Cloud,把結果縮成一份固定的小 JSON,
# 再以 ConfigMap 發布給 my_website 的 nginx pod 掛載。給訪客的是靜態檔,沒有
# query passthrough,所以問不到白名單以外的東西。
set -euo pipefail

ENV_FILE="/etc/observability/public-metrics.env"
NAMESPACE="web"                       # my_website's namespace
CONFIGMAP="fleet-public-metrics"
CLUSTER="${CLUSTER_NAME:-fra-k3s}"    # used IN the queries, never emitted
KUBECTL="/usr/local/bin/kubectl"      # secure_path excludes /usr/local/bin (CLAUDE.md)
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# How long the page may keep showing this snapshot before it calls itself stale.
# 3x the timer interval, so one missed run is not an outage.
STALE_AFTER_SECONDS=900

[ -r "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE missing — see install-public-metrics.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ENV_FILE"
: "${PROM_QUERY_URL:?PROM_QUERY_URL not set in $ENV_FILE}"
: "${PROM_USER:?PROM_USER not set in $ENV_FILE}"
: "${PROM_READ_TOKEN:?PROM_READ_TOKEN not set in $ENV_FILE}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

# promq <promql> -> writes the raw Prometheus JSON response to stdout.
# A non-success status is fatal: publishing a snapshot with silently-missing
# fields is worse than publishing nothing, because the page cannot tell the
# difference between "zero" and "the query broke".
promq() {
  local q="$1" out
  out="$(curl -sS --max-time 20 -u "${PROM_USER}:${PROM_READ_TOKEN}" \
              --data-urlencode "query=${q}" \
              "${PROM_QUERY_URL}/api/v1/query")" || {
    echo "ERROR: query transport failed: ${q}" >&2; return 1; }
  if [ "$(printf '%s' "$out" | jq -r '.status')" != "success" ]; then
    echo "ERROR: query rejected: ${q}" >&2
    printf '%s\n' "$out" | jq -r '.error // .errorType // "unknown"' >&2
    return 1
  fi
  printf '%s' "$out"
}

# scalar <promql> -> the single sample value, or "null" if the series is absent.
scalar() { promq "$1" | jq -r '.data.result[0].value[1] // "null"'; }

# vector <promql> <label> -> [{"key":<label value>,"value":<number>}, …]
vector() {
  promq "$1" | jq -c --arg l "$2" \
    '[.data.result[] | {key: .metric[$l], value: (.value[1]|tonumber)}] | map(select(.key != null))'
}

# ---------------------------------------------------------------------------
# The allowlist. A namespace absent from this map is DROPPED, not passed
# through — new namespaces do not leak by default.
# 白名單:不在這張表裡的 namespace 直接丟掉,新增的 namespace 不會預設外洩。
# ---------------------------------------------------------------------------
NS_LABELS='{
  "snoopy":       "Snoopy",
  "gelp":         "Gelp",
  "transigen":    "Transigen",
  "web":          "Website",
  "data":         "Postgres",
  "observability":"Monitoring",
  "cert-manager": "TLS automation",
  "kube-system":  "Ingress & platform"
}'

C="cluster=\"${CLUSTER}\""
# cAdvisor emits a series for the pod cgroup (container="") and for the pause
# container (container="POD") as well as for each real container. Summing without
# both filters double-counts — it produced a bogus 890 MB once (pending.md §2.8).
CADV="${C}, container!=\"\", container!=\"POD\""

echo "==> querying Grafana Cloud"
cpu_cores="$(scalar "count(count by (cpu) (node_cpu_seconds_total{${C}, mode=\"idle\"}))")"
cpu_ratio="$(scalar "1 - avg(rate(node_cpu_seconds_total{${C}, mode=\"idle\"}[5m]))")"
mem_total="$(scalar "node_memory_MemTotal_bytes{${C}}")"
mem_avail="$(scalar "node_memory_MemAvailable_bytes{${C}}")"
uptime_s="$(scalar "node_time_seconds{${C}} - node_boot_time_seconds{${C}}")"
load1="$(scalar "node_load1{${C}}")"

# Root filesystem ONLY. The other two mountpoints this node has
# (/var/lib/rancher, /var/lib/containers) name the orchestrator and the build
# tooling in their paths, and "k3s" is redacted from the public topology — so
# they are measured internally (fleet.json) and never published here.
# 只發布根檔案系統;另外兩個 mountpoint 的路徑會透露 orchestrator,公開版已把它拿掉。
disk_total="$(scalar "node_filesystem_size_bytes{${C}, mountpoint=\"/\"}")"
disk_avail="$(scalar "node_filesystem_avail_bytes{${C}, mountpoint=\"/\"}")"

# Health is published as a COUNT, never as a list. "5 of 6 up" is a status;
# naming which target is down tells a stranger exactly where to aim.
# 只發「幾個健康」的數字,不發清單 —— 指名哪個掛了等於告訴陌生人往哪打。
svc_up="$(scalar "sum(up{${C}})")"
svc_total="$(scalar "count(up{${C}})")"

# Postgres cache hit ratio, aggregated across every database — NOT
# `by (datname)`. Per-database would name the databases, and a database name
# here is an app name plus the fact that app stores data; §5.3's redaction line
# excluded per-app DB figures and this stays on the public side of it.
#
# LIFETIME counters, deliberately not the 5m rate the internal panel uses. A rate
# is 0/0 whenever nothing queried the database in the window, and this card would
# read "0%" every idle night — indistinguishable from a genuinely cold cache.
# clamp_min guards the remaining division-by-zero on a freshly reset stats view.
#
# 跨所有 database 聚合,不用 by (datname) —— database 名字就是 app 名字加上「該 app
# 有存資料」這個事實。刻意用 lifetime 累計而不是內部 panel 的 5m rate:rate 在無查詢
# 的時段是 0/0,這張卡每個閒置的夜晚都會顯示 0%,跟真的 cache 沒命中分不出來。
PGH="pg_stat_database_blks_hit{${C}, datname!=\"\"}"
PGR="pg_stat_database_blks_read{${C}, datname!=\"\"}"
pg_cache="$(scalar "sum(${PGH}) / clamp_min(sum(${PGH}) + sum(${PGR}), 1)")"

vector "sum by (namespace) (container_memory_working_set_bytes{${CADV}})" namespace > "$work/mem.json"
vector "sum by (namespace) (rate(container_cpu_usage_seconds_total{${CADV}}[5m]))" namespace > "$work/cpu.json"

# ---------------------------------------------------------------------------
# Assemble. Every number is rounded on the way out: a byte-exact memory figure
# is a fingerprint, and nothing on the page needs that precision.
# ---------------------------------------------------------------------------
jq -n \
  --slurpfile mem "$work/mem.json" \
  --slurpfile cpu "$work/cpu.json" \
  --argjson labels "$NS_LABELS" \
  --argjson stale "$STALE_AFTER_SECONDS" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson cpu_cores "$cpu_cores" \
  --argjson cpu_ratio "$cpu_ratio" \
  --argjson mem_total "$mem_total" \
  --argjson mem_avail "$mem_avail" \
  --argjson uptime_s "$uptime_s" \
  --argjson load1 "$load1" \
  --argjson disk_total "$disk_total" \
  --argjson disk_avail "$disk_avail" \
  --argjson svc_up "$svc_up" \
  --argjson svc_total "$svc_total" \
  --argjson pg_cache "$pg_cache" '
  def r2: (. * 100 | round) / 100;
  def r3: (. * 1000 | round) / 1000;
  # Fleet CPU sits near 1.3%. Rounding a RATIO to 2 places quantises that to
  # whole percent and the page would read "1%" forever — 4 places keeps it.
  def r4: (. * 10000 | round) / 10000;
  ($mem[0] // []) as $m |
  (($cpu[0] // []) | map({(.key): .value}) | add // {}) as $cpumap |
  {
    generated_at: $generated_at,
    stale_after_seconds: $stale,
    node: {
      cpu_cores:        $cpu_cores,
      mem_total_bytes:  $mem_total,
      disk_total_bytes: $disk_total,
      uptime_seconds:   ($uptime_s | floor)
    },
    usage: {
      cpu_used_ratio:   ($cpu_ratio | r4),
      mem_used_bytes:   ($mem_total - $mem_avail),
      disk_used_bytes:  ($disk_total - $disk_avail),
      load1_per_core:   (($load1 / $cpu_cores) | r2)
    },
    services: { up: $svc_up, total: $svc_total },
    # null when the exporter has no answer, so the page can show "—" rather than
    # invent a zero. r4 because this sits at ~0.99x and 2 places would flatten
    # every real change into "99%".
    postgres: { cache_hit_ratio: (if $pg_cache == null then null else ($pg_cache | r4) end) },
    workloads: (
      $m
      | map(select($labels[.key] != null))
      | map({ name:      $labels[.key],
              mem_bytes: (.value | round),
              cpu_cores: (($cpumap[.key] // 0) | r3) })
      | sort_by(-.mem_bytes)
    )
  }' > "$work/metrics.json"

# Refuse to publish an obviously broken snapshot. Overwriting a good ConfigMap
# with nulls would make the public page lie; keeping the previous one is right.
# 拒絕發布明顯壞掉的快照 —— 用 null 蓋掉好資料會讓公開頁說謊,保留上一份才對。
if ! jq -e '.node.cpu_cores > 0 and (.workloads | length) > 0' "$work/metrics.json" >/dev/null; then
  echo "ERROR: snapshot failed sanity check, keeping the previous ConfigMap:" >&2
  cat "$work/metrics.json" >&2
  exit 1
fi

echo "==> publishing ConfigMap ${NAMESPACE}/${CONFIGMAP}"
"$KUBECTL" create configmap "$CONFIGMAP" \
  --namespace "$NAMESPACE" \
  --from-file=data.json="$work/metrics.json" \
  --dry-run=client -o yaml | "$KUBECTL" apply -f -

echo "==> done"
jq -c '{generated_at, services, workloads: (.workloads | length)}' "$work/metrics.json"
