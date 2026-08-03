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
>
> Rebased onto `main` and reconciled with Phase B-1..B-4 on 2026-08-02: the
> `data` NetworkPolicy now admits `observability` (Step 2), the namespace carries
> an explicit PSA exemption, and the two stale closing sections were corrected.
> One deferred item remains — **Alloy cannot scrape app pods** until the app's own
> NetworkPolicy opts in (`pending.md` §1.2); that bites at Step 4b, not before.
>
> *2026-08-02 已 rebase 到 `main` 並與 Phase B-1..B-4 對齊:`data` 的 NetworkPolicy
> 已放行 `observability`(Step 2)、namespace 已明寫 PSA 豁免、結尾兩節過時內容已
> 更正。仍有一項刻意延後:**Alloy 抓不到 app pod**,要等該 app 自己的 NetworkPolicy
> 放行(`pending.md` §1.2)—— 這會在 Step 4b 才咬人,前面不受影響。*

---

## Step 0 — Grafana Cloud free-tier account

**Goal / 目標:** end this step holding **three strings** — a URL, a username and
a password — and having proved they work. That is all Step 0 produces. Steps 1–4
then install software that uses them.

*這一步結束時,手上要有**三個字串** —— 一個網址、一個帳號、一個密碼 —— 而且已經確認
它們可用。Step 0 的產出就只有這樣;Step 1–4 才是安裝會用到它們的軟體。*

### Why those three strings exist / 為什麼是這三個字串

Metrics need two halves: something that **collects** them, and something that
**stores and draws** them.

*監控需要兩半:一半**採集**,一半**儲存與繪圖**。*

- The collecting half is **Alloy**, installed on `louis2` in Step 3. It reads
  CPU/RAM/disk/DB numbers off the node and the cluster.
- The storing half is normally Prometheus + Grafana, which would want ~1.5 GB of
  RAM and a disk. `louis2` has 2 OCPU / 12 GB shared with k3s, Traefik, Postgres
  and four apps — running the monitor there makes it compete with the very thing
  it is supposed to watch. So this half is **rented from Grafana Cloud's free
  tier** instead: 10k active series, 14-day retention, no credit card.

*採集那半是 **Alloy**,Step 3 裝在 `louis2` 上,負責讀出節點與叢集的
CPU/記憶體/磁碟/資料庫數字。儲存繪圖那半通常是 Prometheus + Grafana,大約要 1.5 GB
記憶體加一顆磁碟;而 `louis2` 只有 2 OCPU / 12 GB,還要分給 k3s、Traefik、Postgres 和
四個 app —— 把監控放上去,等於讓它跟被監控的對象搶資源。所以這半**改用 Grafana Cloud
免費層**:10k active series、14 天保留、免信用卡。*

Alloy sends its samples **out** to that rented half over HTTPS. To do that it
needs to know *where to send* and *who it is*:

*Alloy 透過 HTTPS 把樣本**往外送**到租來的那半。要送,它得知道**送去哪**、以及**它是
誰**:*

| The string | What it is | Where it comes from |
|---|---|---|
| `PROM_URL` | the address Alloy POSTs samples to, ending `/api/prom/push` | 0b |
| `PROM_USER` | **a number**, not an email — Grafana Cloud's ID for your storage instance | 0b |
| `PROM_PASSWORD` | a token starting `glc_…` that proves Alloy is allowed to write | 0c |

*(`remote_write` is just Prometheus's name for "push samples to a URL over
HTTP". There is no inbound connection and nothing on `louis2` gets exposed —
which is also why this design survives the node being firewalled. 「remote_write」
只是 Prometheus 對「用 HTTP 把樣本推到某個網址」的稱呼。全程沒有任何對內連線,
`louis2` 不會因此開任何埠。)*

Step 0e adds a fourth string that has nothing to do with Grafana —
`POSTGRES_EXPORTER_PASSWORD`, a password you invent for a read-only database user
that Steps 1 and 2 both need. It is generated here only so the two steps cannot
disagree about it.

*0e 另外產生第四個字串,跟 Grafana 無關:`POSTGRES_EXPORTER_PASSWORD` —— 一個你自己
決定、給唯讀資料庫使用者用的密碼,Step 1 和 Step 2 都要用到。放在這裡產生,只是為了
避免兩步各自填出不一樣的值。*

### 0a. Create the stack / 建立 stack

Browser only — nothing runs on the node in this sub-step.

*純瀏覽器操作,這一小步不在節點上執行任何指令。*

```
1. grafana.com → "Create free account"  (GitHub / Google sign-in is fine)
2. It asks for a stack name → this becomes <name>.grafana.net. Use something
   fleet-scoped, e.g. lansh. 一經建立無法改名。
3. Region → pick the one closest to eu-frankfurt-1 (a EU/Germany region).
   louis2 is in Frankfurt; every sample crosses this link. 選離法蘭克福最近的區域。
4. Skip every "connect a data source / install an agent" wizard it offers.
   We install Alloy ourselves from this repo, with our own config.
   跳過所有精靈 —— Alloy 由本 repo 自己裝、用自己的設定檔。
```

**Expect / 預期:** a stack exists at `https://<name>.grafana.net`.

*預期:`https://<name>.grafana.net` 這個 stack 已存在。*

### 0b. Read the remote_write endpoint + username / 取得端點與帳號

```
Grafana Cloud Portal (grafana.com/orgs/<org>) → your stack → the
"Prometheus" tile → "Send Metrics" / "Details".

Copy TWO values from that page:
  - Remote Write Endpoint   https://prometheus-prod-NN-prod-<region>.grafana.net/api/prom/push
  - Username / Instance ID  a number, e.g. 1234567          ← 這是「使用者名稱」,不是 email
```

The username being a bare number is expected — Grafana Cloud's Prometheus uses
HTTP basic auth where the *user* is the numeric instance ID and the *password* is
a token. Your grafana.com login has nothing to do with it.

*帳號是一串純數字是正常的 —— Grafana Cloud 的 Prometheus 用 HTTP basic auth,
帳號是數字型的 instance ID、密碼是 token,跟你登入 grafana.com 的帳號無關。*

**Expect / 預期:** the endpoint ends in `/api/prom/push` and the username is
numeric.

*預期:端點結尾是 `/api/prom/push`,帳號是純數字。*

### 0c. Mint a write-only token / 產生只能寫入的 token

This is where `PROM_PASSWORD` comes from. Grafana Cloud splits it in two: an
**access policy** is a named set of permissions, and a **token** is a key issued
under that policy. You create the policy once, then generate a token from it —
the token string is the password Alloy uses.

*`PROM_PASSWORD` 是在這裡產生的。Grafana Cloud 把它拆成兩層:**access policy** 是一組
具名的權限,**token** 是依據那組權限發出的鑰匙。先建立 policy,再從它產生 token ——
token 那串字就是 Alloy 要用的密碼。*

```
Portal → Access Policies → "Create access policy"
  Display name : louis2-alloy            ← 一台機器一個 policy,撤銷時不影響其他
  Realm        : your stack
  Scopes       : metrics:write           ← ONLY this one. 不要勾 read / 不要勾 logs / traces
Then: on that policy → "Add token" → name louis2-alloy-token → expiry:
  set one (e.g. 1 year) rather than "no expiration", and note the date.
Copy the token NOW — it is shown exactly once. 只會顯示一次。
```

Older Grafana Cloud accounts show **API Keys** with a `MetricsPublisher` role
instead of Access Policies. Same thing; `MetricsPublisher` is the equivalent of
`metrics:write`. If both UIs are present, prefer Access Policies — API keys are
the deprecated path.

*較舊的帳號看到的是 **API Keys** 與 `MetricsPublisher` 角色,而不是 Access
Policies。兩者等價(`MetricsPublisher` ≙ `metrics:write`)。若兩種介面都在,用
Access Policies —— API key 是已被取代的舊路徑。*

Write-only matters: this token lives on a node that is reachable from the
internet. If it leaks, the blast radius is "someone can write junk metrics into
my stack", not "someone can read my fleet's telemetry".

*只給寫入權限是有意義的:這個 token 會放在一台對外可達的節點上。萬一外洩,影響是
「有人能往我的 stack 寫垃圾指標」,而不是「有人能讀走我機隊的遙測資料」。*

**Expect / 預期:** a token string starting `glc_…` in your password manager.

*預期:password manager 裡存好一串 `glc_…` 開頭的 token。*

### 0d. Load them into the shell and verify / 帶進 shell 並驗證

Run on the node (`louis2`), in the shell you will use for Steps 1–3. Two things
happen here: the three strings become shell variables (Steps 2 and 3 read them
from the environment), and one `curl` checks them **before** any software is
installed — so a typo surfaces now, not as a silent no-data dashboard later.

*在節點(`louis2`)上、你接下來要跑 Step 1–3 的那個 shell 執行。這裡做兩件事:把三個
字串變成 shell 變數(Step 2、3 會從環境變數讀取),以及用一個 `curl` 在**安裝任何軟體
之前**先驗證它們 —— 打錯字現在就會現形,而不是等到之後看到一個沒有資料的儀表板才發現。*

**The success code for that check is `400`, not `200`.** The endpoint only
accepts a compressed binary payload, and we deliberately send an empty body: the
server must first check the username/password (that is what we are testing) and
only then complain about the body. So a `400` means *"your credentials were
accepted, your payload was not"* — exactly what we want to see. A `200` is not
obtainable here without sending real metrics.

***這個檢查的成功碼是 `400`,不是 `200`。**該端點只收壓縮過的二進位內容,而我們刻意送
一個空的 body:伺服器會先檢查帳號密碼(這正是我們要測的),之後才抱怨 body。所以
`400` 的意思是**「憑證通過了,內容不合格」** —— 正是我們想看到的結果。這裡不送真實
指標就不可能拿到 `200`。*

```bash
set +o history                       # 這一段不要進 bash history;結束後再 set -o history

PROM_URL='https://prometheus-prod-NN-prod-<region>.grafana.net/api/prom/push'   # 0b 的端點
PROM_USER='1234567'                          # 0b 的數字型 instance ID
read -rs PROM_PASSWORD                       # 貼上 0c 的 glc_… token,不回顯,按 Enter
export PROM_URL PROM_USER PROM_PASSWORD

# Verify the credentials WITHOUT deploying anything: POST an empty body.
curl -s -o /dev/null -w '%{http_code}\n' \
  -u "$PROM_USER:$PROM_PASSWORD" \
  -X POST "$PROM_URL" \
  -H 'Content-Type: application/x-protobuf' \
  -H 'X-Prometheus-Remote-Write-Version: 0.1.0' \
  --data-binary ''                   # 空 body:認證會被檢查,內容則會被拒
```

**Expect / 預期:** `400` — the endpoint accepted the credentials and then
rejected the empty (non-snappy-encoded) body. That is success for this test.
**`401` or `403` means the credentials are wrong** — a wrong instance ID, a
mistyped token, or a token minted in a different stack. `000` means the node
could not reach the endpoint at all (egress/DNS), which is a different problem.

*預期:`400` —— 端點接受了憑證,然後拒絕了空的(未經 snappy 編碼的)body。這個測試
拿到 400 就是成功。**`401` / `403` 代表憑證錯了** —— instance ID 不對、token 打錯,
或 token 是在別的 stack 產生的。`000` 代表節點根本連不到端點(egress/DNS),那是另一
個問題。*

### 0e. Also decide the Postgres exporter password / 順帶決定 exporter 密碼

Step 1 creates a `postgres_exporter` role and Step 2 puts the same password into
the DSN Secret. Choose it now, in the same shell, so the two steps cannot drift.

*Step 1 會建立 `postgres_exporter` role,Step 2 把同一組密碼寫進 DSN Secret。現在就
在同一個 shell 決定,兩步才不會對不起來。*

```bash
POSTGRES_EXPORTER_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"   # 產生後存進 password manager
export POSTGRES_EXPORTER_PASSWORD
printf '%s\n' "$POSTGRES_EXPORTER_PASSWORD"                            # 存好後就別再印
```

**Expect / 預期:** four variables are exported in this shell — `PROM_URL`,
`PROM_USER`, `PROM_PASSWORD`, `POSTGRES_EXPORTER_PASSWORD` — and all four are
also saved in your password manager. **They exist nowhere in git**; on the node
their only persistent home is the two Kubernetes Secrets created in Steps 2–3.
If this shell dies before Step 3, re-export from the password manager rather than
minting new ones.

*預期:這個 shell 裡匯出了四個變數,而且四個都同時存進 password manager。**它們不會
出現在 git 的任何地方**;在節點上的唯一持久位置,是 Step 2–3 建立的兩個 Kubernetes
Secret。若 shell 在 Step 3 前中斷,從 password manager 重新匯出,不要重新產生新的。*

```bash
set -o history                       # 恢復 history 記錄
```

> **Cost / 額度:** at the estimated volume this is ~1 KB/s of egress ≈ 2.5 GB per
> month — against OCI's 10 TB/month free allowance, immaterial. The constraint to
> watch is the **10k active series** ceiling, not bandwidth or disk. Grafana Cloud
> shows current usage under Billing/Usage; check it a day after Step 5.
>
> *成本:估計的量約 1 KB/s 出站 ≈ 每月 2.5 GB,對照 OCI 每月 10 TB 免費額度可忽略。
> 要盯的是 **10k active series** 這個上限,不是頻寬或磁碟。Grafana Cloud 的
> Billing/Usage 頁可看目前用量;Step 5 之後隔一天再回來看。*

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
# POSTGRES_EXPORTER_PASSWORD was already generated and exported in Step 0e — do not
# re-generate it here, or Step 2's DSN will not match the role's password.
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
# FIRST: re-apply the data NetworkPolicy. It now admits the `observability`
# namespace on 5432 (pending.md §1.1). Without this the exporter's connection is
# SILENTLY DROPPED and the verification below just hangs — no error, no log line.
kubectl apply -f cluster/networkpolicies/data.yaml       # adds the observability selector

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
kubectl -n observability rollout status deploy/alloy         # Deployment, 單一 replica
kubectl -n observability rollout status ds/node-exporter     # DaemonSet, 每節點一份
```

**Expect / 預期:** `deploy/alloy` 1/1 and `ds/node-exporter` Ready on every node.
Alloy logs show no scrape auth errors:
`kubectl -n observability logs deploy/alloy | grep -i error` → empty.

*預期:`deploy/alloy` 1/1、`ds/node-exporter` 在每個節點上 Ready;Alloy log 無 scrape
認證錯誤。*

The shapes differ on purpose: node-exporter must run **on** each node (it reads
that node's `/proc`), while Alloy discovers all its targets through the API
server, so exactly one is needed and it can sit on any node. See the comment at
the top of the Deployment in `alloy/alloy.yaml`, and `pending.md` §4.

*兩者形狀不同是刻意的:node-exporter 必須跑在**每個**節點上(它要讀該節點的
`/proc`),而 Alloy 的目標全是透過 API server 查詢得來的,所以只需要一份、且放在哪個
節點都可以。理由見 `alloy/alloy.yaml` 裡 Deployment 上方的註解與 `pending.md` §4。*

---

## Step 4 — host textfile timer (image + log metrics)

**Goal / 目標:** install the systemd timer that writes the image/log textfile
metrics node-exporter exposes.

*安裝 systemd timer,產生 node-exporter 會吐出的 image/log textfile 指標。*

```bash
sudo bash cluster/observability/scripts/install-metrics-timer.sh   # scripts → /usr/local/sbin, units, enable timer
sudo systemctl start observability-metrics.service                 # run once now, don't wait 5 minutes
```

**問題 / Problem:** pointing `ExecStart` straight at the checkout
(`/home/opc/platform/cluster/observability/scripts/*.sh`) fails with
`203/EXEC … Permission denied` even at mode 0755.

*問題:unit 直接指向 checkout 裡的腳本會 203/EXEC 失敗,即使權限已是 0755。*

**解法 / Fix:** SELinux is Enforcing and `/home` is `user_home_t`, which
systemd's `init_t` may not execute — it is a label problem, not a mode problem.
The installer copies both scripts to `/usr/local/sbin` (`bin_t`) and
`restorecon`s them. Re-run it after any `git pull` that touches either script.

*解法:SELinux Enforcing 下 `/home` 是 `user_home_t`,systemd 不能執行 —— 這是
標籤問題不是權限問題。安裝器把腳本複製到 `/usr/local/sbin`(`bin_t`)並
`restorecon`。腳本有變動就要重跑安裝器。*

```bash
ls -Z /usr/local/sbin/image-metrics.sh   # 應為 system_u:object_r:bin_t:s0
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

**The annotation alone is NOT enough.** Alloy scrapes from a pod IP, and every app
NetworkPolicy (`cluster/networkpolicies/<app>.yaml`) admits only `kube-system`,
`10.42.0.1/32` and `10.0.0.240/32` on the app port — so the scrape is dropped.
The failure looks *identical* to a missing annotation (`up{job="app-pods"} == 0`),
which is why this is called out here rather than left to be debugged.

***只加 annotation 不夠。** Alloy 從 pod IP 發出 scrape,而每個 app 的
NetworkPolicy 只放行 `kube-system`、`10.42.0.1/32`、`10.0.0.240/32`,所以封包會被
丟掉。這個失敗跟「annotation 沒生效」長得**一模一樣**(都是
`up{job="app-pods"} == 0`),所以在這裡先講,而不是留給你事後 debug。*

So for each app that opts in — **that app only, not all four pre-emptively** — add
an `observability` selector on its metrics port to its policy, in this repo:

*所以每個要加入的 app —— **只改那一個,不要四個先開好** —— 在本 repo 的政策檔為它的
metrics 埠加一條 `observability` 選擇器:*

```yaml
# cluster/networkpolicies/snoopy.yaml — inside allow-ingress's ingress: list
- from:
    - namespaceSelector:
        matchLabels: { kubernetes.io/metadata.name: observability }
  ports:
    - { protocol: TCP, port: 8080 }     # snoopy 的 metrics 埠
```

```bash
kubectl apply -f cluster/networkpolicies/snoopy.yaml   # 該 app 加入時才套用
```

**Expect / 預期:** after the app redeploys **and** its policy admits
`observability`, `up{job="app-pods"}` in Grafana Cloud shows the pod, and its
custom metrics (e.g. `reminders_fired_total`) are queryable. gelp/transigen would
need a `/metrics` endpoint first, then the same annotation and the same policy
line.

*預期:app 重新部署**且**其政策放行 `observability` 後,Grafana Cloud 裡
`up{job="app-pods"}` 出現該 pod,自訂指標(如 `reminders_fired_total`)可查。
gelp/transigen 要先開 `/metrics` 端點,再加同樣的 annotation 與同樣一段政策。*

---

## Step 5 — verify in Grafana Cloud

**Goal / 目標:** confirm the samples arrived and the per-app views work.

*確認樣本已送達、per-app 視圖可用。*

```bash
# In Grafana Cloud → Explore, run:
#   sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~"snoopy|gelp|transigen|web|data"}[5m]))   # per-app CPU
#   sum by (namespace) (container_memory_working_set_bytes)                                                          # per-app RAM
#   pg_database_size_bytes                                                                                           # per-app DB size
#   node_filesystem_avail_bytes{mountpoint=~"/|/var/lib/rancher|/var/lib/containers"}                                # host disk free — ALL THREE
#   image_store_disk_bytes                                                                                           # image disk pressure
#   pod_log_total_bytes                                                                                              # total log size
```

**Expect / 預期:** each query returns data. Set alerts on the ones that bite:
disk free < 15%, image_store_disk_bytes trend, Postgres connections near max.

*預期:每條查詢都有資料。對會咬人的幾條設告警:磁碟可用 < 15%、image 佔盤趨勢、
Postgres 連線數逼近上限。*

> The disk query must match **all three** mountpoints. `docs/runbook-storage.md`
> split `/var/lib/rancher` (containerd) and `/var/lib/containers` (podman) onto
> their own volumes, so either one filling up is now **invisible in `/`** — which
> is the exact failure that split was done to make visible. An alert on `/` alone
> would go green through a full image store.
>
> *磁碟查詢必須涵蓋**三個**掛載點。`docs/runbook-storage.md` 已把
> `/var/lib/rancher`(containerd)與 `/var/lib/containers`(podman)拆成獨立卷,
> 所以其中任一塞爆**在 `/` 上完全看不出來** —— 而那正是當初拆卷想讓它可見的失敗
> 模式。只看 `/` 的告警,會在 image store 爆滿時一路顯示正常。*

---

## Two things monitoring does NOT fix / 光監控解決不了的兩件事

Watching a number climb doesn't stop it. Of the two caps below, **B is already
done on `main`** — it is recorded here so the metric has an owner. **A is still
genuinely open.**

*看著數字往上爬不會讓它停。以下兩項,**B 在 `main` 上已經做完**(寫在這裡是為了讓
指標有對應的處置),**A 則確實還沒做**。*

### A. containerd log rotation / log 輪替 — STILL OPEN / 尚未處理

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

Nothing on `main` sets these, so treat the check as "unverified" until run.
Changing them **requires restarting k3s**, which takes the whole fleet down for
the restart window — do it in the same maintenance slot as any other k3s-level
change, not as a drive-by during the observability install.

*`main` 上沒有任何地方設定這兩個值,所以在實際檢查前,狀態是「未經確認」。要改就
**必須重啟 k3s**,重啟期間整個機隊會斷 —— 請和其他 k3s 層級的變更排在同一個維護時
段,不要在裝 observability 的過程順手做。*

### B. periodic image prune / 定期 image prune — ALREADY DONE / 已完成

**Goal / 目標:** stop old build layers + untagged images accumulating on the disk
(the usual first cause of a full disk on a build-on-node setup).

*阻止舊 build 層與 untagged image 在盤上堆積(在節點自建的環境最常見的爆盤主因)。*

This is **already installed on the node** — `node/prune-images.{sh,service,timer}`
+ `node/install-prune-timer.sh`, running **daily at 03:00** (not the weekly timer
an earlier draft of this runbook proposed), pruning both stores with `PODMAN_KEEP`
retention on the podman side. Nothing to install here; just confirm it is armed.

*這件事**節點上已經裝好**:`node/prune-images.{sh,service,timer}` 加
`node/install-prune-timer.sh`,**每日 03:00** 執行(不是本 runbook 舊稿寫的 weekly),
兩個 store 一起清,podman 端另有 `PODMAN_KEEP` 保留策略。這裡不需要再裝,只要確認它是
啟用狀態。*

```bash
systemctl status prune-images.timer            # 應為 active(waiting)
systemctl list-timers prune-images.timer       # 下次觸發時間 + 上次執行結果
journalctl -u prune-images.service -n 30       # 上一次清了多少
```

**Expect / 預期:** the timer is `active (waiting)` with a next trigger tonight at
03:00. `image_store_disk_bytes` should show a sawtooth — a daily drop, then
regrowth as deploys land. **A flat line means the timer is not firing**, which is
exactly what this metric exists to catch.

*預期:timer 為 `active (waiting)`,下次觸發在今晚 03:00。`image_store_disk_bytes`
應該呈鋸齒狀 —— 每日下降、隨部署回升。**如果是一條平線,代表 timer 沒在跑** ——
這正是這個指標存在的意義。*

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
