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

# The same allowlist discipline for database names. A database provisioned later
# is absent from this map and is therefore dropped — it does not appear on the
# public chart merely because someone ran provision-db.sh.
# 同樣的白名單紀律用在 database 名稱上:之後新增的 database 不在表上就會被丟掉,
# 不會因為有人跑了 provision-db.sh 就自動出現在公開圖上。
DB_LABELS='{
  "snoopy":    "Snoopy",
  "gelp":      "Gelp",
  "transigen": "Transigen"
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

# Per-database SHARE of the shared Postgres. Bytes are fetched here and thrown
# away below — only the ratios reach the document.
#
# This narrows §5.3's rule rather than obeying it as first written. That rule
# excluded `pg_database_size_bytes{datname=…}` outright. Shares are a weaker
# disclosure than sizes: they say who holds proportionally more data, never how
# much data exists, so the absolute volume — the figure that actually
# characterises the system — stays unpublished. The database names themselves are
# already public: topology.html shows Postgres serving these apps by name.
# Decision recorded in pending.md §5.5.
#
# 各 database 在共用 Postgres 裡的**佔比**。bytes 在這裡取得,但下面就丟掉,只有比例
# 進得了文件。這是把 §5.3 的規則收窄而不是照原文遵守:原文整條排除
# pg_database_size_bytes{datname=…}。比例比大小弱 —— 它只說誰佔比較多,不說總共有多少,
# 所以真正能刻畫這個系統的絕對量仍然沒有公開。database 名字本來就是公開的:
# topology.html 已經指名 Postgres 服務這些 app。
vector "pg_database_size_bytes{${C}, datname!=\"\", datname!~\"postgres|template.*\"}" \
  datname > "$work/db.json"

vector "sum by (namespace) (container_memory_working_set_bytes{${CADV}})" namespace > "$work/mem.json"
vector "sum by (namespace) (rate(container_cpu_usage_seconds_total{${CADV}}[5m]))" namespace > "$work/cpu.json"

# ---------------------------------------------------------------------------
# Assemble. Every number is rounded on the way out: a byte-exact memory figure
# is a fingerprint, and nothing on the page needs that precision.
# ---------------------------------------------------------------------------
jq -n \
  --slurpfile mem "$work/mem.json" \
  --slurpfile cpu "$work/cpu.json" \
  --slurpfile db "$work/db.json" \
  --argjson labels "$NS_LABELS" \
  --argjson dblabels "$DB_LABELS" \
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
    # RATIOS ONLY. The byte totals are queried above, used as denominators here,
    # and never written out.
    #
    # This has to happen in the PRODUCER, not in the page. data.json is served at
    # a public URL — anything left in it is published whether or not a panel
    # renders it, and "the page does not show it" is not a control.
    #
    # Removing the node totals alone would not have worked either. With
    # `mem_used_bytes` and a per-workload share, in-use memory is recoverable by
    # division, and with the used ratio the node total falls out of that. The
    # absolute figures had to go as a set, which is why workloads carry a share
    # below and not a byte count.
    #
    # 只給比例。位元組總量只在上面當分母,不寫進輸出。這必須做在**產生端**:
    # data.json 是公開 URL,留在裡面的東西不管畫面有沒有畫都已經公開,
    # 「頁面沒顯示」不是一種控制。只拿掉節點總量也不夠 —— 有 mem_used_bytes
    # 和一個 per-workload 佔比就能除回 in-use,再配上 used ratio 就能還原節點總量。
    #
    # The core COUNT is gone for the same reason. load1_per_core survives it
    # because dividing by the count destroys it: 0.09 per core is the same
    # reading on 2 cores or on 64, which is exactly why load is normalised that
    # way in the first place.
    # core 數也一併拿掉。load1_per_core 留得下來,是因為除以核心數就把核心數消掉了:
    # 0.09 per core 在 2 核和 64 核上是同一個讀數。
    node: {
      uptime_seconds:   ($uptime_s | floor)
    },
    usage: {
      cpu_used_ratio:   ($cpu_ratio | r4),
      mem_used_ratio:   ((($mem_total - $mem_avail) / $mem_total) | r4),
      disk_used_ratio:  ((($disk_total - $disk_avail) / $disk_total) | r4),
      load1_per_core:   (($load1 / $cpu_cores) | r2)
    },
    services: { up: $svc_up, total: $svc_total },
    # null when the exporter has no answer, so the page can show "—" rather than
    # invent a zero. r4 because this sits at ~0.99x and 2 places would flatten
    # every real change into "99%".
    postgres: {
      cache_hit_ratio: (if $pg_cache == null then null else ($pg_cache | r4) end),
      # SHARES ONLY — the byte values are the denominator and are then discarded.
      # Nothing downstream can recover an absolute size from this array.
      databases: (
        (($db[0] // []) | map(select($dblabels[.key] != null))) as $rows
        | ($rows | map(.value) | add // 0) as $tot
        | if $tot <= 0 then []
          else $rows
            | map({ name: $dblabels[.key], share: ((.value / $tot) | r4) })
            | sort_by(-.share)
          end)
    },
    # Shares, not absolute values, for BOTH memory and CPU.
    #
    # An absolute per-workload core figure would have reopened what removing the
    # core count just closed: summing the workloads and dividing by
    # cpu_used_ratio recovers the core count. Ratios divided by ratios stay
    # ratios, so nothing here reconstructs the machine.
    #
    # NOTE the denominators are what is IN USE, not the totals — so neither
    # column sums to 1. The rest is the kernel, the page cache, and every host
    # process outside a container.
    #
    # 記憶體和 CPU 都用佔比而非絕對值。留著 per-workload 的絕對核心數,等於把剛剛
    # 拿掉 core 數關上的門再打開:把各 workload 加總再除以 cpu_used_ratio 就還原了。
    # 注意分母是「使用中」的量而不是總量,所以兩欄都不會加總到 1。
    workloads: (
      (($cpu_ratio * $cpu_cores) as $cpu_in_use
       | $m
       | map(select($labels[.key] != null))
       | map({ name:      $labels[.key],
               mem_share: ((.value / ($mem_total - $mem_avail)) | r4),
               cpu_share: (if $cpu_in_use > 0
                           then ((($cpumap[.key] // 0) / $cpu_in_use) | r4)
                           else 0 end) })
       | sort_by(-.mem_share))
    )
  }' > "$work/metrics.json"

# Refuse to publish an obviously broken snapshot. Overwriting a good ConfigMap
# with nulls would make the public page lie; keeping the previous one is right.
# 拒絕發布明顯壞掉的快照 —— 用 null 蓋掉好資料會讓公開頁說謊,保留上一份才對。
if ! jq -e '.usage.mem_used_ratio > 0 and (.workloads | length) > 0' "$work/metrics.json" >/dev/null; then
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
