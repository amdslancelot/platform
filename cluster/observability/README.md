# observability

Fleet monitoring for the single node `louis2` (A1.Flex, **2 OCPU / 12 GB**).
The design principle is **offload**: a lightweight collector on the node ships
metrics to Grafana Cloud, so the node keeps none of the storage/query load — a
monitor must never compete for the resources it is monitoring. Only three small
things run on the node (~200 MB total): Grafana Alloy, node-exporter,
postgres-exporter.

*單節點 `louis2`(A1.Flex,**2 OCPU / 12 GB**)的機隊監控。設計原則是**外送**:
節點上只跑輕量採集器,把指標送到 Grafana Cloud,重活(儲存、查詢)全不落在節點
——監控系統絕不該跟它監控的對象搶資源。節點上只多三個小東西(合計約 200 MB):
Grafana Alloy、node-exporter、postgres-exporter。*

## What it monitors / 監控什麼

| Area | Metrics | Source |
|---|---|---|
| **Per-app** (by namespace) | CPU, RAM, disk I/O*, ephemeral disk usage | kubelet + cAdvisor (already running) |
| **Host** | disk space, CPU, RAM, network, load | node-exporter |
| **Images** | count, logical size, actual on-disk bytes (containerd + podman stores) | `scripts/image-metrics.sh` → textfile |
| **Logs** | per-pod container-log dir size + total | `scripts/log-size.sh` → textfile |
| **Postgres** | per-app DB size, connections, cache hit, tx rate | postgres-exporter |
| **App metrics** | an app's own business metrics (opt-in) | pod `prometheus.io/scrape` annotation → Alloy |

\* Per-app disk **I/O** is best-effort (cgroup v2 `io.stat`; page-cache
writeback attribution is fuzzy). For accurate I/O, read Postgres's own stats via
postgres-exporter — Postgres is the only real disk-I/O generator here.

*\* per-app disk **I/O**只能盡力而為(cgroup v2 `io.stat`;page-cache 回寫的歸屬
不精確)。要精準 I/O 就看 Postgres 自己的統計——這台真正會產生磁碟 I/O 的只有
Postgres。*

## Why per-app comes for free / 為什麼 per-app 免費得到

Every app has its own namespace (`snoopy` / `gelp` / `transigen` / `web` /
`data`), so cAdvisor's per-container series become per-app with `sum by
(namespace)`. Postgres is db-per-app, so `pg_database_size_bytes{datname=...}`
is already the per-app data size. No per-app instrumentation needed.

*每個 app 各有自己的 namespace,所以 cAdvisor 的 per-container 指標用
`sum by (namespace)` 就成了 per-app;Postgres 是 db-per-app,
`pg_database_size_bytes{datname=...}` 本身就是該 app 的資料量。不需額外埋點。*

## Files / 檔案

```
namespace.yaml                 observability ns (holds the collector + exporters)
node-exporter.yaml             DaemonSet: host metrics + textfile collector
postgres-exporter.yaml         Deployment + Service: per-app DB metrics
provision-monitoring-role.sh   least-priv pg_monitor role for the exporter
alloy/rbac.yaml                Alloy ServiceAccount + read-only ClusterRole
alloy/alloy.yaml               Alloy DaemonSet + config (remote_write → Grafana Cloud)
scripts/image-metrics.sh       host: image count/size → textfile .prom
scripts/log-size.sh            host: per-pod log dir size → textfile .prom
scripts/observability-metrics.{service,timer}   systemd: run the two scripts every 5m
runbook.md                     command-led install + verify (Grafana Cloud, secrets, rotation, prune)
```

See `runbook.md` for the deploy order and the two things monitoring alone does
NOT fix: **containerd log rotation** and **periodic image prune**.

*部署順序見 `runbook.md`,以及光靠監控解決不了、必須另外做的兩件事:
**containerd log 輪替** 與 **定期 image prune**。*
