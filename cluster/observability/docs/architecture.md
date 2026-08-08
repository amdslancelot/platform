# Architecture — observability stack

*架構 —— 可觀測性堆疊*

This document describes the **shape** of the stack: what each component is
responsible for, which way the data flows, where the trust boundaries are, and
what happens when each piece fails. It does not tell you how to install it
(`runbook.md`), what is monitored (`../README.md`), or why individual choices were
made and what is still open (`pending.md`).

*本文描述這個 stack 的**形狀**:每個元件負責什麼、資料往哪個方向流、trust boundary
在哪、以及每一塊壞掉時會發生什麼事。安裝步驟看 `runbook.md`,監控項目看
`../README.md`,個別決策的理由與未決事項看 `pending.md`。*

| Document | Answers |
|---|---|
| `../README.md` | What is monitored, and from which source |
| `data-path.md` | Where each number comes from, and what a break costs |
| `runbook.md` | How to install it, command by command |
| `pending.md` | Why each choice was made; what is deferred |
| `glossary.md` | What the words mean (`series`, `label`, `temporality`, `up`, …) |
| **`architecture.md`** | **What shape it is, and how it fails** |

---

## The whole picture / 全貌

```
                    THE NODE — louis2 (A1.Flex, 2 OCPU / 12 GB, OL9, k3s)
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │  SOURCES / 資料來源                                                          │
 │                                                                              │
 │    kubelet          :10250/metrics             ──┐                           │
 │    cAdvisor         :10250/metrics/cadvisor    ──┤                           │
 │    node-exporter    :9100/metrics              ──┤                           │
 │      ▲ textfile collector reads .prom files      │                           │
 │      └── image-metrics.sh, log-size.sh           │  (host, systemd, 5m)      │
 │    postgres-exporter :9187/metrics             ──┤                           │
 │    app pods (opt-in prometheus.io/scrape)      ──┘                           │
 │                          │                                                   │
 │                          │  scrape — PULL, plain HTTP, stays in-cluster      │
 │                          ▼                                                   │
 │               ┌─────────────────────────┐                                    │
 │               │     Grafana Alloy       │   5 × prometheus.scrape            │
 │               │     1 replica, 400Mi    │   1 × prometheus.relabel           │
 │               │                         │     └─ drops ~46.5k kubelet series │
 │               └───────────┬─────────────┘                                    │
 └───────────────────────────┼──────────────────────────────────────────────────┘
                             │  remote_write — PUSH, outbound HTTPS,
                             │  basic_auth with a WRITE-ONLY token
                             ▼
                 ┌───────────────────────────────┐
                 │      GRAFANA CLOUD            │  TSDB + query engine
                 │      free tier: 10k series    │  external_labels:
                 │      ~6k in use               │    cluster=fra-k3s
                 │                               │    fleet=lans-h-cc
                 └────┬─────────────────────┬────┘
                      │                     │
             PRIVATE  │                     │  PUBLIC — added 2026-08-04
                      │                     │  ▲ instant + query_range,
                      ▼                     │  │ read-only token
              Grafana UI (SaaS)             │  │
              dashboards/fleet.json         │  │
              19 panels in 5 rows           │  │
              ── authenticated ──           │  │
                                            │  │
        ┌───────────────────────────────────┼──┘
        │  BACK ON THE NODE                 │
        │                                   │
        │   public-metrics.timer  ──▶  public-metrics.sh  (root, every 5m)
        │                                   │   fixed query list
        │                                   │   allowlist ns / db / mountpoint
        │                                   │   reduce to RATIOS ONLY
        │                                   ▼
        │                        ConfigMap  web/fleet-public-metrics
        │                                   │  kubelet volume sync (~60s)
        │                                   ▼
        │                        nginx pod (my_website, ns `web`)
        └───────────────────────────────────┼──────────────────────────────────┘
                                            ▼
                              https://lans-h.cc/metrics/data.json
                                            ▲
                              https://lans-h.cc/fleet.html  renders it client-side
```

**Note the shape of the public path: it leaves the node and comes back.** The
snapshot producer runs *on* the node but reads *from* Grafana Cloud rather than
from the local exporters. That is not an accident — the node keeps no TSDB (see
"Offload" below), so it is the only place with 24 hours of history to draw a
chart from. The round trip is the price of not storing anything locally.

***注意公開路徑的形狀:它離開節點再繞回來。**快照產生器跑在節點上,但資料是跟
Grafana Cloud 要的,不是跟本機的 exporter 要的。這不是繞遠路 —— 節點上沒有 TSDB
(見下方 Offload),所以只有雲端那邊有 24 小時的歷史可以畫圖。這趟往返就是「本地
什麼都不存」的代價。*

---

## Three design principles / 三個設計原則

### 1. Offload — the node stores and queries nothing

*外送 —— 節點不儲存、不查詢*

No TSDB, no query engine, no PVC, no Grafana Deployment. The node runs only
collectors. A monitoring system that competes for the resources it is monitoring
will lie to you exactly when you most need it to be honest — during a resource
crunch.

*沒有 TSDB、沒有查詢引擎、沒有 PVC、沒有 Grafana Deployment。節點上只有採集器。
一套會跟監控對象搶資源的監控系統,會剛好在你最需要它誠實的時候(資源吃緊時)騙你。*

**"No PVC" is a consequence, not an economy.** The WAL is a **shipping queue,
not a history**: it holds only what Grafana Cloud has not acknowledged yet, and
each entry is discarded on ack, so its size tracks how far behind the network is
rather than how long the cluster has been running. A queue that empties itself
has nothing to persist. An `emptyDir` is therefore the *correct size of storage*
for it — not a corner cut to stay inside a storage budget, and not something to
"upgrade" to a PVC later. Measured 2026-08-08: 14 MB at `/var/lib/alloy/data`,
and the only PVC in the entire cluster is `data/postgres-data` (1Gi).

***「沒有 PVC」是結果,不是省下來的。**WAL 是一個**出貨佇列,不是歷史**:它只存
Grafana Cloud 還沒確認收到的東西,每一筆一經確認就丟掉,所以它的大小反映的是「網路
落後多少」,不是「cluster 跑了多久」。一個會自己清空的佇列沒有東西需要持久化。因此
`emptyDir` 是它*正確的儲存尺寸* —— 不是為了塞進 storage 額度而砍的角,也不是之後該
「升級」成 PVC 的東西。2026-08-08 實測:`/var/lib/alloy/data` 佔 14 MB,而整座 cluster
唯一的 PVC 是 `data/postgres-data`(1Gi)。*

**This principle is not fully earned yet.** The `observability` namespace is
currently 397 MB — the heaviest thing on the node, more than all four apps
combined. The storage/query half of the principle holds; the memory half does
not. `../README.md` states this plainly rather than rounding it off, and
`pending.md` §2.8 tracks the fix.

***這個原則目前還沒完全做到。** `observability` namespace 現在佔 397 MB,是節點上最重
的東西,比四個 app 加起來還多。「不儲存不查詢」這半做到了,「輕量」這半沒有。
`../README.md` 直說了這件事而不是四捨五入掉,修法追蹤在 `pending.md` §2.8。*

### 2. Pull, not push — the sources are passive

*拉取而非推送 —— 資料來源是被動的*

Every source in the diagram exposes a `/metrics` endpoint in Prometheus
**exposition format** and waits. No source knows Grafana Cloud exists; none
holds a credential; none needs configuring when the collector changes. Adding a
target is a change to Alloy's config, not to the target.

*圖上每個來源都只是暴露一個 `/metrics` 端點(Prometheus **exposition format**)然後
等著被抓。沒有任何來源知道 Grafana Cloud 的存在、沒有任何來源持有 credential、
採集器改了也不用去動它們。新增一個 target 是改 Alloy 的設定,不是改 target。*

The load-bearing consequence is the **`up` metric**: because the collector goes
looking, a target that stops answering produces `up=0`. Silence is itself a
signal. In a push model a dead sender and a healthy-but-idle sender look
identical. `fleet.html`'s `services.up / total` counter is entirely a product of
this choice.

*這個選擇最關鍵的後果是 **`up` 這個 metric**:因為是採集器主動去找,不回應的 target
就會產生 `up=0` —— 沉默本身就是訊號。在 push model 底下,一個死掉的發送端跟一個健康
但剛好沒事的發送端長得一模一樣。`fleet.html` 上的 `services.up / total` 完全是這個
選擇的產物。*

The one push in the diagram is `remote_write`, and it is the *collector → storage*
hop, not the *source → collector* hop. Those are different segments; conflating
them is the usual confusion.

*圖上唯一的 push 是 `remote_write`,而且是 *collector → storage* 那一段,不是
*source → collector* 那一段。這是兩個不同的區段,搞混是常見的誤解。*

### 3. Redaction lives in the producer, never in the page

*遮蔽做在產生端,絕不做在頁面上*

`data.json` is a public URL. Anything left in it is published whether or not a
panel renders it — "the layout does not show it" is not a control. So the
allowlist sits in `public-metrics.sh`, on the node, before the ConfigMap is
written.

*`data.json` 是一個公開 URL。留在裡面的東西不管有沒有 panel 去畫它,都已經公開了 ——
「版面上沒顯示」不是一種控制。所以白名單放在節點上的 `public-metrics.sh`,在 ConfigMap
被寫出去之前就過濾掉。*

This is also why a self-hosted anonymous Grafana was rejected: it exposes a
**datasource proxy** that forwards arbitrary PromQL, so a panel allowlist is
decoration — a visitor queries whatever they like. Full reasoning in
`pending.md` §5.5.

*這也是為什麼自架一個匿名 Grafana 被否決:它會暴露 **datasource proxy**,原封不動轉發
任意 PromQL,所以 panel 白名單只是裝飾 —— 訪客想查什麼就查什麼。完整推理見
`pending.md` §5.5。*

---

## Layer by layer / 逐層說明

### Sources / 來源

| Source | Runs as | Gives |
|---|---|---|
| kubelet | already part of k3s | node/pod state — **heavily filtered**, see below |
| cAdvisor | same endpoint, `/metrics/cadvisor` | per-container CPU / memory / I-O → per-app via `sum by (namespace)` |
| node-exporter | DaemonSet, `hostNetwork` | host disk, CPU, RAM, network, load |
| textfile collector | node-exporter reads `.prom` files written by two host scripts | image store bytes, pod log bytes — things no exporter reports |
| postgres-exporter | Deployment + Service | per-DB size, connections, cache hit, tx rate |
| app pods | opt-in `prometheus.io/scrape: "true"` annotation | an app's own business metrics |

Two of these deserve a note. The **textfile collector** is how a shell script
becomes a metric: a script writes `/var/lib/node_exporter/textfile_collector/*.prom` and
node-exporter serves its contents alongside its own. That is the escape hatch for
anything the exporter ecosystem does not cover — here, podman's on-disk image
store and the size of `/var/log/pods`.

*其中兩個值得說明。**textfile collector** 是 shell script 變成 metric 的途徑:script
寫檔到 `/var/lib/node_exporter/textfile_collector/*.prom`,node-exporter 把內容跟自己的指標一起
提供出去。這是 exporter 生態沒覆蓋到的東西的逃生口 —— 這裡是 podman 的 image store
實際佔用,以及 `/var/log/pods` 的大小。*

**App metrics are opt-in by annotation**, which is a Prometheus-ecosystem
convention with no OpenTelemetry equivalent (an OTel app knows its own
destination). It means an app repo can start publishing metrics without anyone
touching this repo.

***app 自己的 metric 靠 annotation 加入**,這是 Prometheus 生態的慣例,OpenTelemetry
沒有對應概念(OTel 的 app 自己就知道要往哪送)。它的意義是:app repo 可以自己開始送
指標,不用動到這個 repo。*

### Collection — Alloy / 採集

One Deployment, **one replica, deliberately**. `discovery.kubernetes "nodes"`
returns *all* nodes, so a second Alloy would scrape the same targets with
identical labels — duplicate-sample rejections at `remote_write` and doubled
active series. Redundancy here would buy corruption, not availability.

*一個 Deployment,**刻意只有一個 replica**。`discovery.kubernetes "nodes"` 回傳的是
*所有*節點,所以第二個 Alloy 會用完全相同的標籤去抓同一批 target —— `remote_write`
判為重複樣本、active series 加倍。這裡做冗餘買到的是資料損毀,不是可用性。*

Five scrape jobs, four of which forward straight to `remote_write`. The kubelet
job is the exception: it passes through `prometheus.relabel "kubelet_keep"`
first, which **discards ~46,513 of ~46,560 series**. That single filter is what
keeps the stack inside the free tier's 10k active series.

*五個 scrape job,其中四個直接 `forward_to` 到 `remote_write`。kubelet 那個是例外:
它先經過 `prometheus.relabel "kubelet_keep"`,**丟掉約 46,513 / 46,560 條 series**。
就是這一個 filter 讓整個 stack 待在免費層的 10k active series 以內。*

The cost of that filter is memory, not CPU: the series are still fetched and
still parsed into label sets before being dropped. `scrape_interval = "5m"` on
that one job makes it happen 5× less often. This is the direct cause of the
397 MB in principle #1.

*這個 filter 的代價是記憶體不是 CPU:那些 series 仍然被抓下來、仍然被解析成 label set,
然後才被丟掉。給那一個 job 設 `scrape_interval = "5m"` 讓這件事少發生 5 倍。這正是
原則 #1 那 397 MB 的直接成因。*

#### Where the WAL actually lives / WAL 實際上寫在哪

A recurring confusion worth settling in writing: **the WAL is local, on the
node.** It is not in Grafana Cloud, and Grafana Cloud does not have "a WAL" of
yours — it has accepted samples in its own storage, which is a different object
with a different lifetime. Verified 2026-08-08:

*一個反覆出現、值得白紙黑字寫下來的混淆:**WAL 是本地的,在節點上。**它不在 Grafana
Cloud,而 Grafana Cloud 那邊也沒有一份屬於你的「WAL」—— 它那邊有的是被接受的 sample,
存在它自己的儲存裡,是另一個物件、另一種生命週期。2026-08-08 驗證:*

```
Deployment/alloy
  volumes:      - name: data
                  emptyDir: {}                      # disk-backed, no medium: Memory
  volumeMounts: data -> /var/lib/alloy/data
  args:         --storage.path=/var/lib/alloy/data
  size on disk: 14 MB
```

The physical directory is on the node, under kubelet's per-pod volume tree —
`emptyDir` means Kubernetes creates it empty at placement and deletes it when the
pod goes away, so nothing here is shared with, or visible from, the backend.

*實體目錄在節點上,位於 kubelet 的 per-pod volume 目錄樹底下 —— `emptyDir` 的意思是
Kubernetes 在 pod 被排上去時建立一個空目錄,pod 消失時刪掉,所以這裡沒有任何東西是跟
backend 共用的,backend 也看不到。*

| Event | WAL |
|---|---|
| container restart — OOMKill, failed probe | **survives** — same pod, same directory |
| pod deleted / rollout / eviction / node reboot | **gone** — unacked samples are lost |
| reschedule to another node | **gone** — `emptyDir` never follows a pod |

*表格對照:container 重啟(OOMKill、probe 失敗)WAL **留著**,因為 pod 沒變、目錄沒變;
pod 被刪掉、rollout、eviction、節點重開,WAL **消失**,還沒被 ack 的 sample 就沒了;
被重新排到另一個節點也是 **消失**,`emptyDir` 永遠不會跟著 pod 走。*

This qualifies the backfill guarantee in §Failure modes. "A network-only outage
costs nothing" holds **as long as the Alloy pod is not recreated during it** —
a `rollout restart` in the middle of a network outage loses that window. The
fix would be a PVC for the WAL, which is deliberately not taken: it would spend a
permanent volume against a double coincidence, and would contradict principle #1.

*這一點限定了 §Failure modes 裡的 backfill 保證。「純網路中斷不損失任何東西」成立的
前提是**中斷期間 Alloy 的 pod 沒有被重建** —— 在網路中斷當中做 `rollout restart` 會
損失那個窗口。要消掉這個風險就得給 WAL 一個 PVC,而這是刻意不做的:為了一個雙重巧合
付出一個常駐 volume,而且會違反原則 #1。*

### Transport / 傳輸

`remote_write` — snappy-compressed protobuf over HTTPS, outbound only, no
inbound port opened on the node. Two `external_labels` are attached at this hop:

*`remote_write` —— snappy 壓縮的 protobuf over HTTPS,只出不進,節點上不開任何對內的
port。兩個 `external_labels` 在這一跳被加上:*

```
cluster = fra-k3s     ← identifies the source CLUSTER, not the node
fleet   = lans-h-cc
```

`cluster` is injected from an environment variable rather than hardcoded, so a
second cluster (e.g. one stood up on the unused ARM allowance) sets its own value
and its series do not silently merge with this one's in the same Grafana Cloud
stack. `fleet.json`'s dashboard variable reads `label_values(up, cluster)`, so
that second cluster appears in the picker with no dashboard edit.

*`cluster` 是從環境變數注入而不是寫死的,所以第二個 cluster(例如用那份沒動用的 ARM
額度開的)會帶自己的值,不會在同一個 Grafana Cloud stack 裡跟這台的 series 悄悄混在
一起。`fleet.json` 的 dashboard 變數讀 `label_values(up, cluster)`,所以那個 cluster
會自己出現在選單裡,不用改儀表板。*

### Storage and query / 儲存與查詢

Grafana Cloud free tier. Everything expensive lives here: retention, indexing,
the query engine, the UI. Budget and current usage are in "Constraints" below.

*Grafana Cloud 免費層。所有昂貴的東西都在這裡:retention、索引、查詢引擎、UI。
額度與目前用量見下方「限制」。*

### Private consumption — `fleet.json` / 私有消費端

19 panels in 5 rows, kept **in git** rather than only in a Grafana account, so
the dashboard survives the account and is reviewable in a diff. Import via
Dashboards → Import → Upload JSON, Overwrite, UID `lansh-fleet`.

*19 個 panel 分 5 個 row,**存在 git 裡**而不是只存在 Grafana 帳號裡,所以儀表板不會
隨帳號消失,而且改動可以在 diff 裡被審。匯入:Dashboards → Import → Upload JSON,
Overwrite,UID `lansh-fleet`。*

### Public consumption — the snapshot / 公開消費端

This is the layer added on 2026-08-04. Five stages, each of which can be
inspected on its own:

*這是 2026-08-04 加上的一層。五個階段,每一段都可以單獨檢查:*

```
1. public-metrics.timer fires        systemctl list-timers | grep public-metrics
2. public-metrics.sh queries GC      journalctl -u public-metrics.service -n 50
3. → ConfigMap web/fleet-public-metrics   kubectl -n web get cm fleet-public-metrics -o json
4. → kubelet syncs the volume        kubectl -n web exec deploy/lans-h-site -- ls -l /usr/share/nginx/html/metrics
5. → nginx serves it                 curl -sI https://lans-h.cc/metrics/data.json
```

Stage 4 has a mechanical trap worth remembering: the ConfigMap is mounted as a
**directory**, not with `subPath`. A `subPath` mount is a one-time copy and never
sees an update — the page would freeze at whatever the first snapshot said. What
kubelet actually swaps is a symlink (`data.json -> ..data/data.json`), atomically.

*第 4 階段有個機制上的陷阱值得記住:ConfigMap 是掛**整個目錄**,不是用 `subPath`。
`subPath` 掛載是一次性複製,永遠看不到更新 —— 頁面會凍結在第一份快照。kubelet 實際
在換的是一個 symlink(`data.json -> ..data/data.json`),而且是原子的。*

The volume is `optional: true`. Without it, a missing ConfigMap holds the pod in
`ContainerCreating` — an auxiliary display feature would take the entire website
down. With it, `fleet.html` degrades to "snapshot unavailable" and every other
page is unaffected.

*這個 volume 設了 `optional: true`。少了它,ConfigMap 不存在會讓 pod 卡在
`ContainerCreating` —— 一個附屬的展示功能反而弄掉整個網站。有了它,`fleet.html`
降級成「快照無法取得」,其他頁面完全不受影響。*

### Why a ConfigMap and not a hostPath / 為什麼用 ConfigMap 而不是 hostPath

The obvious alternative is simpler: have the timer write `/var/lib/fleet/data.json`
on the host and mount it into the site pod with `hostPath`. Four lines of YAML and
one less object in the cluster. Five reasons it was not taken — all verified
against the live cluster on **2026-08-08**.

*比較直觀的替代方案是:讓 timer 直接把 `/var/lib/fleet/data.json` 寫在 host 上,再用
`hostPath` 掛進網站的 pod。四行 YAML,而且 cluster 裡少一個物件。以下五個沒有這樣做的
理由,全部在 **2026-08-08** 對著線上 cluster 驗證過。*

**1. `hostPath` pins the pod to a node, and fails quietly when it moves.** A pod
with a `hostPath` can only run where that file exists. Today that costs nothing;
what it costs permanently is portability — a reschedule elsewhere mounts an empty
directory and nginx returns 404 with no pod-level error. A ConfigMap travels
through the API, so the pod can be placed anywhere.

***1. `hostPath` 會把 pod 釘在特定節點上,而且搬走的時候是安靜地壞掉。**掛了 `hostPath`
的 pod 只能跑在「那個檔案存在的地方」。今天這不花任何代價,永久的代價是可移植性 ——
一旦被重新排到別處,掛到的是空目錄,nginx 回 404,而 pod 層級不會有任何錯誤。
ConfigMap 走 API,pod 排到哪裡都拿得到。*

**2. The site pod is the most exposed pod in the fleet.** It is the only one
serving the public internet directly, so any host filesystem mount shortens the
distance between a container escape and host access — in exchange for a file that
the API can deliver anyway.

***2. 網站的 pod 是整個 fleet 裡最暴露的一個。**它是唯一直接對公開網際網路提供服務的
pod,所以任何 host 檔案系統的掛載都會縮短「container 逃逸」到「取得 host 檔案系統」之間
的距離 —— 而換來的只是一個本來就能靠 API 送達的檔案。*

> **Correction worth recording.** Pod Security Standards do forbid `hostPath` in
> the `baseline` and `restricted` profiles, but this cluster does not *enforce*
> them on `web`: the namespace carries `pod-security.kubernetes.io/audit` and
> `/warn` at `restricted`, and **no `enforce` label**. A `hostPath` there would be
> warned and audited, not rejected. The one namespace with an `enforce` label is
> `observability`, set to **`privileged`** — opened deliberately so node-exporter
> can do what it has to. The policy in this cluster is convention plus a warning,
> not admission control.
>
> ***一處值得記下來的更正。**Pod Security Standards 的 `baseline` 與 `restricted`
> profile 確實禁止 `hostPath`,但這座 cluster 並沒有對 `web` **enforce**:該 namespace
> 上掛的是 `pod-security.kubernetes.io/audit` 與 `/warn` 兩個標籤、值為 `restricted`,
> **沒有 `enforce` 標籤**。在那裡掛 `hostPath` 會被警告與稽核,不會被拒絕。唯一帶
> `enforce` 標籤的 namespace 是 `observability`,值為 **`privileged`** —— 那是為了讓
> node-exporter 做它非做不可的事而刻意開的。這座 cluster 的政策是慣例加警告,不是
> admission control。*

**3. Atomicity comes free, instead of being reimplemented.** This is the same
hazard as the textfile collector contract: a reader arriving mid-write. kubelet
updates a ConfigMap volume by writing the new content into a timestamped directory
and then atomically re-pointing a `..data` symlink at it, so nginx can never read
half a JSON document. On the live pod:

***3. 原子性是免費的,不必重寫一次。**這跟 textfile collector 契約遇到的是同一個危險:
讀的人在寫到一半的時候抵達。kubelet 更新 ConfigMap volume 的做法,是把新內容寫進一個帶
時間戳的目錄,然後原子地把 `..data` symlink 重指過去,所以 nginx 永遠讀不到半份 JSON。
線上 pod 的實況:*

```
..2026_08_08_01_39_30.3825801333          # 01:39 — the newest snapshot's own directory
..data -> ..2026_08_08_01_39_30.3825801333 # 01:39 — the only thing that gets re-pointed
data.json -> ..data/data.json              # 08:22 (pod start) — never rewritten
```

The outer symlink has not been touched since the pod started; every update swaps
only `..data`. A shared file would mean reimplementing this by hand — `mktemp` in
the *same* filesystem plus `mv`, or the guarantee is gone. The volume also carries
`defaultMode: 420` (`0644`), which is the textfile collector's `chmod` trap solved
by declaration rather than by remembering.

*外層的 symlink 從 pod 啟動之後就沒被動過,每次更新只換 `..data`。改用共用檔案就得自己
把這套重做一遍 —— `mktemp` 必須在**同一個** filesystem 再加 `mv`,否則保證就沒了。這個
volume 另外設了 `defaultMode: 420`(也就是 `0644`),等於把 textfile collector 那個
`chmod` 陷阱用宣告解決掉,而不是靠記得。*

**4. The writer needs to know nothing about the reader.** The timer only needs
`kubectl` to work. It does not need to know which node the pod is on, what path the
container mounts, what UID nginx runs as, or whether that path exists yet. All of
that stays Kubernetes' problem rather than the shell script's.

***4. 寫的那一端完全不需要知道讀的那一端。**timer 只需要 `kubectl` 通得了。它不用知道
pod 在哪個節點、container 掛在哪個路徑、nginx 用哪個 UID 跑、那個路徑存不存在。這些全部
留給 Kubernetes 處理,不是 shell script 的問題。*

**5. What is published becomes an inspectable API object.** This matters more here
than it would elsewhere, because the central question of this layer is *what am I
publishing*. `kubectl -n web get cm fleet-public-metrics -o json` returns the exact
public payload from anywhere with cluster access — diffable, and checkable from CI.
A file at some path on some host has none of those properties.

***5. 被公開出去的東西變成一個可以檢查的 API 物件。**這一點在這裡比在別處更重要,因為
這一層的核心問題就是**我到底公開了什麼**。`kubectl -n web get cm fleet-public-metrics
-o json` 在任何連得上 cluster 的地方都能取回確切的公開 payload —— 可以 diff,也可以放進
CI 檢查。放在某台機器某個路徑上的檔案完全沒有這些性質。*

There is also a host-level reason: **SELinux is `Enforcing`** on this node, and
`hostPath` mounts into containers routinely need relabelling or a policy exception.
That is one more thing that fails quietly.

*還有一個 host 層級的理由:這台節點的 **SELinux 是 `Enforcing`**,而 `hostPath` 掛進
container 經常需要 relabel 或加 policy 例外。那又是一件會安靜失敗的事。*

**What the choice costs / 這個選擇的代價**

| Limit | Measured 2026-08-08 | When it would bite |
|---|---|---|
| ConfigMap max size (etcd) | **96,026 bytes ≈ 9% of 1 MiB** | not "far away" — history growth is the first wall this layer will hit |
| kubelet volume sync latency | ~1 min, against a 5 min refresh | anything wanting second-level freshness |
| every update is an etcd write | 288/day | a faster cadence would be using the cluster datastore as a scratch file |

*表格對照:ConfigMap 的大小上限是 etcd 給的 1 MiB,2026-08-08 實測 96,026 bytes,
約 **9%** —— 這不是「離很遠」,歷史資料成長會是這一層最先撞到的牆。kubelet 同步 volume
的延遲約一分鐘,而更新週期是五分鐘,所以無所謂;想要秒級新鮮度就不行。每次更新都是一次
etcd 寫入,一天 288 次微不足道,但更快的頻率等於拿 cluster 的 datastore 當暫存檔用。*

**When `hostPath` is the right answer** — and this cluster has the example.
`node-exporter` runs with `hostNetwork: true`, `hostPID: true`, and **four**
`hostPath` mounts: `/proc`, `/sys`, `/`, and
`/var/lib/node_exporter/textfile_collector`. It has no alternative; without them
it reads its own container's view and every number is wrong. So the rule here is
not "never `hostPath`" — it is **use it only where nothing else can work**, and
the snapshot is not one of those places.

***什麼時候 `hostPath` 才是對的答案** —— 這座 cluster 裡就有例子。`node-exporter` 跑的
時候帶 `hostNetwork: true`、`hostPID: true`,以及**四個** `hostPath` 掛載:`/proc`、
`/sys`、`/`、還有 `/var/lib/node_exporter/textfile_collector`。它沒有替代方案;不掛的話
它讀到的是自己 container 的視角,量出來的數字全錯。所以這裡的規則不是「絕不用
`hostPath`」,而是**只在沒有任何其他做法可行的時候用**,而快照不屬於那種情況。*

---

## The two host timers / 節點上的兩個 timer

Both run as root on the host, both every 5 minutes, and they are **kept separate
on purpose**:

*兩個都在節點上以 root 執行、都是每 5 分鐘一次,而且是**刻意分開**的:*

| | `observability-metrics` | `public-metrics` |
|---|---|---|
| Does | writes `.prom` files for the textfile collector | queries Grafana Cloud → ConfigMap |
| Direction | local only | **outbound to the internet** |
| Credential | none | **the `metrics:read` token** |
| Output | private, in-cluster | **the public internet** |
| Fails when | disk/permissions | also: network, token, Grafana Cloud |

Merging them would give a credential to a script that does not need one, widen
what a compromise of either reaches, and report one failure for two unrelated
jobs. Keeping them apart also means `systemctl list-timers` makes it visibly
obvious that something public is running.

*合併它們會讓一個不需要 credential 的 script 拿到 credential、擴大任一邊被攻陷後能碰到
的範圍、而且會把兩件無關的工作報成同一個失敗。分開還有一個好處:`systemctl list-timers`
一眼就看得出來有東西在對外公開。*

---

## Trust boundaries and secrets / 信任邊界與機密

Three credentials exist. **None of them ever reaches a browser.**

*總共三個 credential。**沒有任何一個會到達瀏覽器。***

| Credential | Lives in | Scope | Rotate by |
|---|---|---|---|
| Grafana Cloud **write** token | k8s Secret `grafana-cloud`, ns `observability` → Alloy env | `metrics:write` — can push, **cannot read** | re-mint in portal, update Secret, restart Alloy |
| Grafana Cloud **read** token | `/etc/observability/public-metrics.env`, **0600 root, host filesystem** | `metrics:read` — can read **everything** in the stack | re-run `install-public-metrics.sh` |
| postgres-exporter password | k8s Secret (as a DSN), ns `observability` | `pg_monitor`, read-only | `provision-monitoring-role.sh` |

**The read token is the most powerful of the three and it is the one that lives
outside Kubernetes.** That is a conscious concession, recorded in `pending.md`
§5.5: the producer must run as root on the host to write to the kubeconfig-owning
filesystem and to publish a ConfigMap, so a host file at 0600 is where it goes.
The mitigation is scope — it can read metrics and nothing else — plus an expiry
date on the token rather than "no expiration".

***讀取 token 是三個裡面權限最大的,而且是唯一放在 Kubernetes 之外的那個。**這是一個
有意識的讓步,記錄在 `pending.md` §5.5:產生器必須以 root 在節點上跑(才能用
kubeconfig 發布 ConfigMap),所以它落在一個 0600 的 host 檔案裡。緩解手段是範圍 ——
它只能讀 metrics、不能做別的 —— 加上給 token 設到期日而不是選 "no expiration"。*

The write token being **write-only** matters more than it sounds: if Alloy is
compromised, the attacker can pollute the TSDB but cannot read back what the
fleet looks like.

*寫入 token 是**只能寫**這件事比聽起來重要:如果 Alloy 被攻陷,攻擊者可以污染 TSDB,
但沒辦法反過來讀出這個機隊長什麼樣子。*

---

## The redaction contract / 遮蔽契約

Every field published in `data.json` is a **ratio**. No memory size, no disk
size, no core count, no byte figure for any workload or database.

*`data.json` 裡發布的每一個欄位都是**比率**。沒有記憶體大小、沒有磁碟大小、沒有核心
數、沒有任何 workload 或 database 的位元組數字。*

**The removal had to be all-at-once, and this is the part that is easy to undo by
accident.** Absolute quantities recover each other by division:

***這個移除必須一次做完,而這正是最容易不小心破壞掉的部分。**絕對數量之間可以靠除法
互相還原:*

```
workload_bytes ÷ workload_share  =  total in use
total_in_use   ÷ used_ratio      =  the node's total memory
per-workload CPU seconds ÷ CPU share  =  core count
```

Ratios divided by ratios stay ratios. Adding back a single absolute figure —
however harmless it looks on its own — re-opens the whole chain. **Never add an
absolute quantity to that JSON without redoing this arithmetic.**

*比率除以比率還是比率。加回任何一個絕對數字 —— 不管它單獨看起來多無害 —— 都會把整條
鏈重新打開。**在沒有重做這個算術之前,絕不要把絕對數量加回那份 JSON。***

Three allowlists mean additions to the cluster do not leak by default:

*三個白名單確保之後加進 cluster 的東西不會預設洩漏:*

- `NS_LABELS` — a namespace created later does not appear publicly
- `DB_LABELS` — likewise for a new database
- `MP_LABELS` — mountpoints are **renamed**, never published as paths

The line is calibrated against `my_website/public/topology.html`, the
security-redacted twin of `platform/docs/topology.html`. Public already: the app names,
Postgres, OCI. Deliberately not: the node's IP, the hostname, the `:9000` webhook
port, and the string `k3s`. Also withheld: **which** scrape target is unhealthy
when one is — only a count is published, because naming it tells a stranger where
to aim.

*這條線是對照 `my_website/public/topology.html`(`platform/docs/topology.html` 的安全遮蔽版)
校準的。已經公開的:app 名稱、Postgres、OCI。刻意不公開的:節點 IP、hostname、
`:9000` webhook port、以及 `k3s` 這個字串。另外保留的:某個 scrape target 不健康時
**是哪一個** —— 只發布數量,因為講出名字等於告訴陌生人往哪裡打。*

A sanity gate in the producer refuses to overwrite a good ConfigMap with nulls:

*產生器裡有一道 sanity gate,拒絕用一份全是 null 的快照覆蓋掉好的 ConfigMap:*

```bash
jq -e '.usage.mem_used_ratio > 0 and (.workloads | length) > 0'
```

---

## Failure modes / 失效模式

The useful question about any monitoring stack is not "does it work" but "what
does it take down when it breaks". Here, the answer is almost always **nothing**.

*對任何監控系統該問的問題不是「它會不會動」,而是「它壞掉時會拖垮什麼」。這裡的答案
幾乎永遠是**什麼都不會**。*

| What breaks | Symptom | Blast radius |
|---|---|---|
| Alloy pod down | gaps in Grafana; public page stale after 15m | monitoring only — **apps unaffected** |
| Grafana Cloud unreachable | `remote_write` queues, then drops oldest | monitoring only |
| Write token revoked | all ingestion stops; dashboards freeze | the stack goes blind; apps fine |
| `public-metrics.sh` fails | ConfigMap keeps the **last good** snapshot; page shows its own staleness | public page only |
| ConfigMap deleted | `optional: true` → 404 on `data.json` | `fleet.html` only — **site stays up** |
| Read token revoked | snapshot stops refreshing | public page goes stale |
| node-exporter down | host + textfile metrics gone | disk panels, public disk section |
| postgres-exporter down | `pg_*` series gone | Postgres panels, public DB section |
| Active series > 10k | Grafana Cloud rejects the excess | partial, silent data loss — **watch for this** |

The last row is the one without a graceful degradation, which is why the series
budget is tracked rather than assumed.

*最後一列是唯一沒有優雅降級的,所以 series 額度是被追蹤的、不是靠假設的。*

---

## Constraints and budgets / 限制與額度

| Budget | Limit | Current |
|---|---|---|
| Grafana Cloud active series | 10,000 (free tier) | ~6,000 |
| kubelet series discarded | — | ~46,513 of ~46,560 |
| `observability` ns memory | 400Mi limit on Alloy | 397 MB namespace total |
| Node | 2 OCPU / 12 GB | fleet CPU ~1.3% of two cores |
| Public snapshot refresh | — | 5 min (~288 queries/day) |
| Grafana Cloud trial | **ends 2026-08-18** | check the usage curve before then |

If active series climbs above ~8k, the next lever is a **cadvisor allowlist**
(~3,099 series), applied the same way the kubelet filter already is.

*如果 active series 爬過約 8k,下一個手段是對 **cadvisor 做白名單**(約 3,099 條),
做法跟現有的 kubelet filter 一樣。*

---

## Why metrics came first / 為什麼先做 metrics

v1.0 ships one signal of three. That is a **coverage level, not a category
error** — observability's scope is set by the questions you want to answer, and
telemetry is the prerequisite for every one of them (`glossary.md` §1). The
direction is right; the coverage is roughly half. What follows is why this half
was the half to build first, so the ordering is a recorded decision rather than
an accident of what was easy.

*v1.0 只出了三種 signal 裡的一種。這是**覆蓋率的問題,不是方向錯了** ——
observability 的範圍由「你想回答什麼問題」決定,而 telemetry 是所有問題的前置條件
(`glossary.md` §1)。方向對,覆蓋率大約一半。下面記的是為什麼先做這一半,讓這個順序
是一個有記錄的決定,而不是「剛好這個比較好做」。*

| Signal | Answers / 回答什麼 | Cost scales with / 成本跟什麼成正比 | v1.0 |
|---|---|---|---|
| **metrics** | how much, how many, is it up | the **shape of the fleet** — container / namespace / mountpoint count. Independent of traffic | ✅ |
| **logs** | what happened, in words | log volume — traffic × verbosity | size only, never content |
| **traces** | why *this* request was slow, and which hop ate the time | **request rate** — one record per request | ❌ |
| **profiles** | which function burns the CPU, who allocates the memory | sampling rate × running processes | ❌ |

**1. Metrics answer the questions actually being asked.** The five this stack
was built for — disk, memory, target health, Postgres cache hit ratio, and the
history behind all four — are every one of them "how much" questions. A trace
cannot tell you how much disk is left; it is not the shape of that answer.

***1. metrics 剛好回答了現在真正在問的問題。**這座 stack 要回答的五個問題 —— 磁碟、
記憶體、target 健康、Postgres cache hit ratio,以及這四者的歷史 —— 全部都是「多少」型
的問題。trace 回答不了「磁碟還剩多少」,那不是它的形狀。*

**2. Its cost model is the only one compatible with a hard series cap.** Metrics
volume follows the shape of the fleet, which is under my control and changes
slowly. Trace volume follows traffic — meaning the signal costs most exactly
when the system is busiest, which is exactly when the quota failure would land.
That failure is *silent and partial* (§Failure modes): series stop arriving,
nothing reports an error. Pairing a hard ceiling with a traffic-proportional
producer puts the worst failure mode at the worst possible moment.

***2. 它的成本模型是唯一跟 hard series cap 相容的。**metrics 的量跟著 fleet 的形狀走,
那是我控制得住、而且變動很慢的東西。trace 的量跟著流量走 —— 也就是說,系統最忙的時候
這個 signal 最貴,而那正好是額度會爆掉的時候。爆掉的失效方式是 *silent and partial*
(§Failure modes):series 停止抵達,沒有任何地方報錯。把 hard ceiling 跟一個「量與流量
成正比」的產生端配在一起,等於把最糟的失效排在最糟的時機。*

Worth stating precisely, because it is easy to over-read: Grafana Cloud bills
traces on a **separate quota**, not against the 10,000 active series. The
ceiling is not literally shared. What *is* shared is collector memory on the
node — and per `pending.md` §2.8 the collector is already the heaviest thing
running, so a second receiver competes with the constraint the whole design
exists to respect (§Offload).

*這點要講精確,因為很容易讀過頭:Grafana Cloud 的 traces 走**另一組獨立額度**,不是算
在那 10,000 條 active series 裡,ceiling 並不是字面上共用的。真正共用的是節點上的
collector memory —— 依 `pending.md` §2.8,collector 已經是跑著的東西裡最重的一個,
再加一個 receiver 等於去搶那條「整個設計就是為了尊重它」的限制(§Offload)。*

**3. Detection comes before diagnosis.** Metrics say *that* something is wrong;
traces and profiles say *why*. Before this stack existed there were no numbers
at all, so the gap was detection. Building diagnosis on top of no detection
means owning a tool that answers a question you have no way of knowing you
should ask.

***3. 先有偵測,才輪得到診斷。**metrics 告訴你**有事**,traces 跟 profiles 告訴你
**為什麼**。這座 stack 出現之前一個數字都沒有,所以缺口在偵測那一端。在沒有偵測的
情況下先蓋診斷,等於養了一個工具去回答一個「你根本不知道自己該問」的問題。*

**4. Metrics needed no application change; the other two do.** node-exporter,
cAdvisor and postgres-exporter are off-the-shelf and produce data the moment
they are installed. Traces require an instrumentation SDK inside each of the
four apps; profiles require another agent. Both are "modify app code before the
first sample exists" — and **this repo never contains app code** (root
`CLAUDE.md`), so both cross a repo boundary that metrics do not. That is not a
small detail: it turns a one-repo change into a five-repo change.

***4. metrics 不用動到 application code,另外兩個要。**node-exporter、cAdvisor、
postgres-exporter 都是現成的,裝上去就有資料。traces 要在四個 app 裡各埋一套
instrumentation SDK;profiles 要再跑一個 agent。兩者都是「先改 app code,才會有第一筆
資料」—— 而**這個 repo 從來不放 app code**(根目錄 `CLAUDE.md`),所以兩者都跨過了
metrics 不用跨的 repo 邊界。這不是小事:它把一個 repo 的改動變成五個 repo 的改動。*

**What would change the order.** When the recurring question stops being "is
anything wrong" and becomes "why is *this* endpoint slow", traces become the
cheapest answer and this ordering should be revisited — but not before. Adding
a signal to close a question nobody is asking spends the two things this design
is shortest on: series budget and collector memory.

***什麼情況下順序會變。**當常態的問題不再是「有沒有出事」而變成「**這個** endpoint
為什麼慢」的時候,traces 就會是最便宜的答案,那時該重新檢視這個順序 —— 但在那之前不
必。為了一個沒人在問的問題去加一個 signal,花掉的正好是這個設計最缺的兩樣東西:
series 額度與 collector memory。*

---

## What this is NOT / 這不是什麼

**It is metrics-only so far — one signal of three, not all of them.** What that
costs is a *class of question*: metrics answer questions decided in advance —
dashboards and thresholds written yesterday — whereas a question you did not
anticipate generally needs traces or high-cardinality wide events. This is a
coverage limit and a deliberate ordering (§Why metrics came first), not a wrong
direction.

***目前只有 metrics —— 三種 signal 裡的一種,不是全部。**它的代價是一個**問題類別**:
metrics 回答的是事先決定好的問題 —— 昨天就寫好的 dashboard 跟 threshold;而事先沒
預料到的問題通常需要 traces 或 high-cardinality 的 wide events。這是覆蓋率的限制,
以及一個刻意選擇的順序(§Why metrics came first),不是方向錯了。*

```
metrics   ✅  Alloy → Grafana Cloud
logs      ❌  only log SIZE is shipped, never log CONTENT — no Loki
traces    ❌  none
profiles  ❌  none
```

The ~46,513 dropped series are this boundary made concrete: every dropped series
is a question given up in advance, in exchange for staying inside the free tier.

*那約 46,513 條被丟掉的 series 就是這條界線的具體化:每丟一條,就是預先放棄一個未來
可能想問的問題,換取待在免費層裡。*

**It is telemetry, but it is not OpenTelemetry.** The pipeline contains zero
`otelcol.*` components — it is `discovery.kubernetes` + `prometheus.scrape` +
`prometheus.relabel` + `prometheus.remote_write` throughout. Alloy happens to
speak OTLP as well (it ships both component families), but that half is unused,
and no OTLP receiver port is open on the node.

***這是 telemetry,但不是 OpenTelemetry。** 整條 pipeline 裡零個 `otelcol.*` 元件 ——
從頭到尾都是 `discovery.kubernetes` + `prometheus.scrape` + `prometheus.relabel` +
`prometheus.remote_write`。Alloy 剛好也會講 OTLP(兩組元件它都有),但那一半沒用到,
節點上也沒有開任何 OTLP receiver port。*

**It does not run kube-state-metrics**, so community Kubernetes dashboards will
show "No data" on nearly every panel. kube-state-metrics reports cluster *object*
state (desired vs available replicas, restart counts); cAdvisor reports resource
*usage*. Adding the former is a separate decision with its own memory and series
cost.

***它沒有跑 kube-state-metrics**,所以社群的 Kubernetes 儀表板幾乎每個 panel 都會顯示
"No data"。kube-state-metrics 報的是叢集**物件**狀態(期望與實際 replica 數、重啟次數),
cAdvisor 報的是資源**用量**。要不要加前者是另一個決定,有它自己的記憶體與 series 成本。*

**Monitoring does not fix what it observes.** Two known items are operational,
not observational: **containerd log rotation** (still open — needs a k3s restart,
i.e. fleet-wide downtime, so it waits for a maintenance slot) and **periodic
image prune** (done — a 03:01 timer). Seeing a disk fill up on a chart is not the
same as stopping it.

***監控不會修好它觀測到的東西。**有兩件已知的事屬於維運而非觀測:**containerd log
輪替**(尚未處理 —— 需要重啟 k3s,也就是全機隊停機,所以等維護時段)與**定期 image
prune**(已完成 —— 03:01 的 timer)。在圖表上看著磁碟被塞滿,跟阻止它被塞滿是兩回事。*

---

## Open items / 未決事項

Tracked in full in `pending.md`; the ones that bear on this architecture:

*完整清單在 `pending.md`,跟本架構有關的是:*

- **§2.8** — re-measure Alloy's memory ~1h after the 5m kubelet interval took
  effect, *then* decide on the 400Mi limit. Lowering it before that measurement
  buys an OOMKill, not a saving.
- **§3.4** — **there is no Postgres backup.** ~42 MB of live data on a
  no-redundancy local-path PVC. This is the most serious open item on the node
  and it is not an observability problem.
- Grafana Cloud trial ends **2026-08-18** — check the active-series curve first.
- `load1_per_core` read 0 on the first snapshot; if it stays 0 while CPU does
  not, `node_load1` has a problem.
- Whether to link `fleet.html` from the homepage — a presentation choice, **not**
  a security control (the URL is guessable and `canonical` is set).
