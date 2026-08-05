# observability

Fleet monitoring for the single node `louis2` (A1.Flex, **2 OCPU / 12 GB**).
The design principle is **offload**: a lightweight collector on the node ships
metrics to Grafana Cloud, so the node keeps none of the storage/query load — a
monitor must never compete for the resources it is monitoring. Three things run
on the node: Grafana Alloy, node-exporter, postgres-exporter.

*單節點 `louis2`(A1.Flex,**2 OCPU / 12 GB**)的機隊監控。設計原則是**外送**:
節點上只跑輕量採集器,把指標送到 Grafana Cloud,重活(儲存、查詢)全不落在節點
——監控系統絕不該跟它監控的對象搶資源。節點上只多三個東西:Grafana Alloy、
node-exporter、postgres-exporter。*

**Measured 2026-08-04, and it is not as light as this README first claimed.** An
earlier draft said "~200 MB total". The real figure, the day the stack went live:

***2026-08-04 實測,而且沒有本 README 原先聲稱的那麼輕。**舊稿寫「合計約 200 MB」,
上線當天的實際數字是:*

| namespace | working set | note |
|---|---|---|
| **observability** | **397 MB** | the largest on the node |
| kube-system | 269 MB | |
| cert-manager | 143 MB | |
| snoopy + gelp + transigen + web | 259 MB | **all four apps combined** |
| data (Postgres) | 58 MB | |

So the collector currently outweighs everything it collects from. The offload
principle still holds where it matters — no TSDB, no query engine, no PVC, and
CPU across the whole fleet is ~1.3% of two cores — but "a monitor must never
compete for the resources it is monitoring" is a claim this stack has not fully
earned yet, and pretending otherwise in the README would be the wrong kind of
documentation.

*所以採集器目前比它所採集的一切加起來還重。offload 原則在關鍵處仍然成立 —— 沒有
TSDB、沒有查詢引擎、沒有 PVC,整個機隊的 CPU 只用掉兩顆核心的約 1.3% —— 但「監控系統
絕不該跟它監控的對象搶資源」這句話,這個 stack 還沒有完全做到。在 README 裡假裝做到了
是錯誤的文件寫法。*

The cause is known and is being worked: the kubelet endpoint's ~46.5k series are
parsed into label sets before the allowlist discards 99.9% of them, and that
parse-and-discard is what Alloy's memory goes to. `scrape_interval = "5m"` on
that one job (2026-08-04) cuts how often it happens by 5x. Alloy's 400Mi limit is
**deliberately left alone until that is re-measured** — lowering a limit on a
process already near it buys an OOMKill, not a saving. See `pending.md` §2.8.

*成因已知且處理中:kubelet 端點那 ~46.5k 條 series 會先被解析成 label set,allowlist
才丟掉其中 99.9%,而 Alloy 的記憶體就花在這段「解析完再丟」。2026-08-04 為該 job 設
`scrape_interval = "5m"`,讓這件事少發生 5 倍。Alloy 的 400Mi limit **刻意先不動,等
重新量測**  —— 對一個已經逼近上限的行程調低 limit,換來的是 OOMKill 不是節省。見
`pending.md` §2.8。*

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
alloy/alloy.yaml               Alloy Deployment (1 replica) + config (remote_write → Grafana Cloud)
scripts/image-metrics.sh       host: image count/size → textfile .prom
scripts/log-size.sh            host: per-pod log dir size → textfile .prom
scripts/observability-metrics.{service,timer}   systemd: run the two scripts every 5m
scripts/install-metrics-timer.sh   installs both scripts to /usr/local/sbin (SELinux) + the units
runbook.md                     command-led install + verify (Grafana Cloud, secrets, rotation, prune)
pending.md                     MUST-READ before applying: pre-flight fixes + the open backend decision
```

**Read `pending.md` first.** This branch was authored before the Phase B-1..B-4
hardening landed on `main`; three of the runbook's steps fail silently against the
NetworkPolicies now in place, and two others are stale.

***先讀 `pending.md`。** 本分支撰寫於 Phase B-1..B-4 加固進 `main` 之前;runbook 有三
個步驟會被現行的 NetworkPolicy 靜默擋掉,另有兩處已過時。*

See `runbook.md` for the deploy order and the two things monitoring alone does
NOT fix: **containerd log rotation** and **periodic image prune**.

*部署順序見 `runbook.md`,以及光靠監控解決不了、必須另外做的兩件事:
**containerd log 輪替** 與 **定期 image prune**。*
