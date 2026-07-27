# Runbook — observability stack

Command-led install for the fleet monitoring stack. Runs on the prod node
`louis2` from the platform checkout (`~opc/platform`). Nothing here touches app
data; every step is revertible. Do them in order.

*機隊監控 stack 的 command-led 安裝步驟。在 prod 節點 `louis2` 上、從 platform
checkout(`~opc/platform`)執行。全程不碰 app 資料;每步可回退。照順序做。*

> **Status: built locally, NOT yet applied to the node.** These files were
> authored in the repo for review first (push = live). The steps below are what
> you run on the node once approved.
>
> *狀態:已在本機建檔,**尚未套用到節點**。先 review 再上(push 即上線)。*

---

## Step 0 — Grafana Cloud free-tier account

**Goal / 目標:** get the Prometheus remote_write endpoint + credentials that
Alloy ships to. Free tier: 10k active series, 14-day retention — enough for this
fleet.

*拿到 Alloy 要送達的 Prometheus remote_write endpoint 與憑證。免費層:10k active
series、14 天保留,對這個機隊夠用。*

```bash
# In a browser (no node command): grafana.com → create free account → a stack
# is auto-created. Then: Stack → Prometheus → "Send Metrics".
# Copy three values from that page:
#   - Remote Write Endpoint URL   (…/api/prom/push)
#   - Username / Instance ID      (a number)
#   - API token / password        (generate one with MetricsPublisher role)
```

**Expect / 預期:** you have `PROM_URL`, `PROM_USER`, `PROM_PASSWORD` in hand for
Step 3.

*預期:手上有 `PROM_URL`、`PROM_USER`、`PROM_PASSWORD` 供 Step 3 用。*

---

## Step 1 — namespace + monitoring role

**Goal / 目標:** create the `observability` namespace and the least-privilege
`postgres_exporter` role (pg_monitor; cannot read app data).

*建立 `observability` namespace 與最小權限的 `postgres_exporter` role
(pg_monitor;讀不到 app 資料)。*

```bash
cd ~/platform                                    # the node checkout (/home/opc/platform)
kubectl apply -f cluster/observability/namespace.yaml   # create the ns

# Create the monitoring role INSIDE the postgres pod (same pattern as provision-db.sh).
# Pick a strong password; you will reuse it in the DSN secret in Step 2.
POSTGRES_EXPORTER_PASSWORD='<choose-a-strong-pw>'
kubectl -n data exec -i deploy/postgres -- \
  env POSTGRES_EXPORTER_PASSWORD="$POSTGRES_EXPORTER_PASSWORD" \
  bash -s < cluster/observability/provision-monitoring-role.sh   # creates role, grants pg_monitor
```

**Expect / 預期:** `monitoring role ready: postgres_exporter (pg_monitor, CONNECT on postgres)`.

*預期:輸出 `monitoring role ready: postgres_exporter …`。*

---

## Step 2 — postgres-exporter (DSN secret, then deploy)

**Goal / 目標:** give the exporter its connection string as a Secret (never in
git), then start it. `sslmode=disable` is correct — this Postgres has no TLS by
design.

*把連線字串以 Secret 交給 exporter(絕不進 git),再啟動它。`sslmode=disable`
是對的——這台 Postgres 依設計無 TLS。*

```bash
kubectl create secret generic postgres-exporter-dsn -n observability \
  --from-literal=DATA_SOURCE_NAME="postgresql://postgres_exporter:${POSTGRES_EXPORTER_PASSWORD}@postgres.data.svc.cluster.local:5432/postgres?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f -          # DSN secret, idempotent

kubectl apply -f cluster/observability/postgres-exporter.yaml   # Deployment + Service
kubectl -n observability rollout status deploy/postgres-exporter
```

**Expect / 預期:** pod Ready; `kubectl -n observability port-forward
svc/postgres-exporter 9187:9187` then `curl -s localhost:9187/metrics | grep
pg_database_size_bytes` shows one line per app DB.

*預期:pod Ready;port-forward 後 curl 指標,`pg_database_size_bytes` 每個 app DB
各一行。*

---

## Step 3 — Alloy (Grafana Cloud secret, RBAC, collector)

**Goal / 目標:** stand up the collector that scrapes everything and remote_writes
to Grafana Cloud.

*啟動採集器:scrape 全部來源並 remote_write 到 Grafana Cloud。*

```bash
# Grafana Cloud creds from Step 0, as a Secret (Alloy reads them via env).
kubectl create secret generic grafana-cloud -n observability \
  --from-literal=prometheus-url="$PROM_URL" \
  --from-literal=prometheus-user="$PROM_USER" \
  --from-literal=prometheus-password="$PROM_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -          # creds secret

kubectl apply -f cluster/observability/alloy/rbac.yaml   # SA + read-only ClusterRole
kubectl apply -f cluster/observability/node-exporter.yaml   # host metrics + textfile collector
kubectl apply -f cluster/observability/alloy/alloy.yaml  # collector + config
kubectl -n observability rollout status ds/alloy
kubectl -n observability rollout status ds/node-exporter
```

**Expect / 預期:** both DaemonSets Ready (1/1). Alloy logs show no scrape auth
errors: `kubectl -n observability logs ds/alloy | grep -i error` → empty.

*預期:兩個 DaemonSet 皆 Ready(1/1);Alloy log 無 scrape 認證錯誤。*

---

## Step 4 — host textfile timer (image + log metrics)

**Goal / 目標:** install the systemd timer that writes the image/log textfile
metrics node-exporter exposes.

*安裝 systemd timer,產生 node-exporter 會吐出的 image/log textfile 指標。*

```bash
sudo install -m 0644 cluster/observability/scripts/observability-metrics.service /etc/systemd/system/   # unit
sudo install -m 0644 cluster/observability/scripts/observability-metrics.timer   /etc/systemd/system/   # timer
chmod +x cluster/observability/scripts/image-metrics.sh cluster/observability/scripts/log-size.sh       # exec bit
sudo systemctl daemon-reload
sudo systemctl enable --now observability-metrics.timer   # start + run on boot
sudo systemctl start observability-metrics.service        # run once now
```

**Expect / 預期:** `ls /var/lib/node_exporter/textfile_collector/` shows
`image_metrics.prom` and `log_size.prom`; `curl -s localhost:9100/metrics | grep
-E 'containerd_images_total|pod_log_total_bytes'` returns values.

*預期:textfile 目錄出現兩個 `.prom`;curl node-exporter 指標可見
`containerd_images_total` 與 `pod_log_total_bytes`。*

---

## Step 4b — (optional) opt an app in to its OWN metrics

**Goal / 目標:** collect an app's business metrics (not just CPU/RAM). Alloy
auto-scrapes any pod annotated `prometheus.io/scrape: "true"`. snoopy already
exports metrics (`prometheus-client`, `:8080/metrics`, e.g.
`reminders_fired_total`) — it just needs the annotation; no code change.

*採集 app 自己的業務指標(不只 CPU/RAM)。Alloy 會自動抓任何帶
`prometheus.io/scrape: "true"` annotation 的 pod。snoopy 早就用
`prometheus-client` 在 `:8080/metrics` 吐指標(如 `reminders_fired_total`)
——只差這個 annotation,不用改程式。*

Add to the app's Deployment **pod template** (`spec.template.metadata.annotations`),
in the app's OWN repo — done there, not here. For snoopy
(`snoopy_home/deploy/k8s/base/deployment.yaml`):

*加在 app Deployment 的 **pod template**(在該 app 自己的 repo,不是這裡)。snoopy 為例:*

```yaml
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"     # snoopy's metrics/health port
        prometheus.io/path: "/metrics" # the default; shown for clarity
```

**Expect / 預期:** after the app redeploys, `up{job="app-pods"}` in Grafana Cloud
shows the pod, and its custom metrics (e.g. `reminders_fired_total`) are queryable.
gelp/transigen would only need to expose a `/metrics` endpoint first, then the
same annotation.

*預期:app 重新部署後,Grafana Cloud 裡 `up{job="app-pods"}` 出現該 pod,自訂
指標(如 `reminders_fired_total`)可查。gelp/transigen 之後只要先開一個
`/metrics` 端點,再加同樣 annotation 即可。*

---

## Step 5 — verify in Grafana Cloud

**Goal / 目標:** confirm the samples arrived and the per-app views work.

*確認樣本已送達、per-app 視圖可用。*

```bash
# In Grafana Cloud → Explore, run:
#   sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~"snoopy|gelp|transigen|web|data"}[5m]))   # per-app CPU
#   sum by (namespace) (container_memory_working_set_bytes)                                                          # per-app RAM
#   pg_database_size_bytes                                                                                           # per-app DB size
#   node_filesystem_avail_bytes{mountpoint="/"}                                                                      # host disk free
#   image_store_disk_bytes                                                                                           # image disk pressure
#   pod_log_total_bytes                                                                                              # total log size
```

**Expect / 預期:** each query returns data. Set alerts on the ones that bite:
disk free < 15%, image_store_disk_bytes trend, Postgres connections near max.

*預期:每條查詢都有資料。對會咬人的幾條設告警:磁碟可用 < 15%、image 佔盤趨勢、
Postgres 連線數逼近上限。*

---

## Two things monitoring does NOT fix / 光監控解決不了的兩件事

Watching a number climb doesn't stop it. On the 200 GB boot volume, cap both:

*看著數字往上爬不會讓它停。在 200 GB boot volume 上,兩者都要設上限:*

### A. containerd log rotation / log 輪替

**Goal / 目標:** bound per-container log files so `pod_log_total_bytes` can't fill
the disk.

*限制每個容器的 log 檔大小,讓 `pod_log_total_bytes` 塞不爆盤。*

```bash
# Check the current k3s containerd config for max_container_log_line_size / rotation.
# k3s templates containerd config; add/confirm log limits, then restart k3s.
sudo grep -R "max_container_log" /var/lib/rancher/k3s/agent/etc/containerd/ 2>/dev/null   # inspect
# If unset, k3s/kubelet default rotation is 10Mi × 5 files per container (kubelet
# --container-log-max-size / --container-log-max-files). Confirm on the k3s unit:
sudo grep -E "container-log-max" /etc/systemd/system/k3s.service /etc/rancher/k3s/*.yaml 2>/dev/null   # inspect
```

**Expect / 預期:** kubelet is enforcing a per-container log cap (default 10Mi×5).
If not, add `--kubelet-arg=container-log-max-size=10Mi
--kubelet-arg=container-log-max-files=5` to the k3s config and restart k3s.

*預期:kubelet 有在限制每容器 log(預設 10Mi×5)。若沒有,在 k3s config 加上述
kubelet-arg 再重啟 k3s。*

### B. periodic image prune / 定期 image prune

**Goal / 目標:** stop old build layers + untagged images accumulating on the disk
(the usual first cause of a full disk on a build-on-node setup).

*阻止舊 build 層與 untagged image 在盤上堆積(在節點自建的環境最常見的爆盤主因)。*

```bash
# Safe prune: removes ONLY images no running container references.
sudo /usr/local/bin/k3s crictl rmi --prune          # containerd side
sudo podman image prune -f                          # podman build store side
# Optional: make it a weekly systemd timer, same pattern as observability-metrics.timer.
```

**Expect / 預期:** `image_store_disk_bytes` drops after a prune; the metric lets
you see it working and decide the cadence.

*預期:prune 後 `image_store_disk_bytes` 下降;有了這個指標就能看出效果、決定頻率。*

---

## Rollback / 回退

```bash
kubectl delete -f cluster/observability/alloy/alloy.yaml -f cluster/observability/alloy/rbac.yaml \
  -f cluster/observability/node-exporter.yaml -f cluster/observability/postgres-exporter.yaml   # remove workloads
sudo systemctl disable --now observability-metrics.timer                                          # stop host timer
kubectl delete ns observability                                                                   # drops secrets too
# The postgres_exporter role is harmless to leave; to remove it:
kubectl -n data exec -i deploy/postgres -- psql -U postgres -c 'DROP ROLE IF EXISTS postgres_exporter;'
```

*回退:刪掉 workloads、停 host timer、刪 namespace(連同 secret);monitoring role
留著無害,要刪就 DROP ROLE。*
