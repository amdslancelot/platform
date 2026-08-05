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
scripts/public-metrics.sh      host: Grafana Cloud -> allowlisted JSON -> ConfigMap (public page)
scripts/public-metrics.{service,timer}          systemd: refresh the public snapshot every 5m
scripts/install-public-metrics.sh  installs the above + prompts once for the metrics:read token
dashboards/fleet.json          the fleet dashboard — import into Grafana, see below
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

## Dashboard / 儀表板

`dashboards/fleet.json` — the fleet dashboard, kept in git rather than only in a
Grafana account. Import it with **Dashboards → New → Import → Upload JSON**, then
pick the Prometheus datasource when prompted.

*`dashboards/fleet.json` —— 機隊儀表板,存在 git 裡而不是只存在 Grafana 帳號裡。
匯入方式:**Dashboards → New → Import → Upload JSON**,系統詢問時選 Prometheus
datasource。*

It has a `cluster` variable driven by `label_values(up, cluster)`, so a second
cluster (§4.5 in `pending.md`) appears in the picker without editing anything.

*它有一個由 `label_values(up, cluster)` 驅動的 `cluster` 變數,所以之後若有第二個
cluster(見 `pending.md` §4.5),不用改任何東西就會出現在選單裡。*

Do **not** import the community Kubernetes dashboards. Almost all of them depend
on **kube-state-metrics**, which this stack does not run — every panel would read
"No data" and look like a collection failure. kube-state-metrics reports cluster
*object* state (desired vs available replicas, restart counts); cAdvisor reports
resource *usage*. Different things; adding the former is a separate decision with
its own memory and active-series cost.

*請**不要**匯入社群的 Kubernetes 儀表板。它們幾乎全部依賴 **kube-state-metrics**,
而本 stack 沒有跑它 —— 每個 panel 都會顯示 "No data",看起來像採集壞掉。
kube-state-metrics 報告的是叢集**物件**狀態(期望與實際 replica 數、重啟次數),
cAdvisor 報告的是資源**用量**,兩者不同;要不要加前者是另一個決定,有它自己的記憶體與
active series 成本。*

`1860` (Node Exporter Full) does work as-is if a deeper host view is wanted — it
reads only node-exporter, which this stack does run.

*若想要更深入的主機視圖,社群的 `1860`(Node Exporter Full)可以直接用 —— 它只讀
node-exporter,而本 stack 有跑。*

## The public snapshot / 公開快照

`lans-h.cc/fleet.html` shows a deliberately small subset of these metrics to the
public internet. It is **not** an embedded Grafana: a timer on the node runs a
fixed list of queries, reduces them to one JSON document, and publishes it as a
ConfigMap that `my_website`'s nginx pod mounts. The visitor gets a file, so there
is no query interface to go around — see `pending.md` §5.5 for why that beat
running Grafana OSS, and runbook **Step 6** to install it.

*`lans-h.cc/fleet.html` 把這些指標中刻意挑過的一小部分公開。它**不是**嵌入的 Grafana:
節點上一個 timer 跑固定的查詢,縮成一份 JSON,以 ConfigMap 發布給 `my_website` 的 nginx
pod 掛載。訪客拿到的是檔案,所以沒有可繞過的查詢介面 —— 為什麼這勝過跑 Grafana OSS
見 `pending.md` §5.5,安裝見 runbook **Step 6**。*

**Before adding a query to it, read the redaction contract** at the top of
`scripts/public-metrics.sh`. The namespace map there is an allowlist: a namespace
added to the cluster later does not appear on the public page by default.

***在替它加查詢之前,先讀 `scripts/public-metrics.sh` 開頭的 redaction contract。**
那裡的 namespace 對照表是白名單:之後新增到叢集的 namespace 不會預設出現在公開頁上。*
