# Glossary — observability stack

*名詞表 —— 可觀測性堆疊*

Terms used across `architecture.md`, `data-path.md`, `runbook.md` and
`pending.md` without being defined there. Each entry gives the definition first,
then where the term actually appears in **this** stack — a definition you cannot
point at in your own system is not yet knowledge.

*本目錄下其他文件(`architecture.md`、`data-path.md`、`runbook.md`、`pending.md`)
會用到但沒有定義的名詞。每一條先給定義,再給它在**這座** stack 裡的實際落點 ——
指不到自己系統上的定義還不算學會。*

Technical terms stay in English throughout, including inside the Chinese halves.
The English word is the one that appears in upstream docs, in `kubectl` output,
and in interviews; translating it destroys the takeaway.

*全文技術名詞一律保留英文,中文段落裡也一樣。英文詞才是 upstream 文件、`kubectl`
輸出和面試裡會出現的那個詞,翻掉就沒有可帶走的東西了。*

| Document | Answers |
|---|---|
| `../README.md` | What is monitored, and from which source |
| `architecture.md` | What shape it is, and how it fails |
| `data-path.md` | Where each number comes from, and what a break costs |
| `runbook.md` | How to install it, command by command |
| `pending.md` | Why each choice was made; what is deferred |
| **`glossary.md`** | **What the words mean** |

---

## 1. The two words that get conflated / 最常被混用的兩個詞

**telemetry** — the signals themselves, plus the act of moving them from where
they are produced to somewhere else. Three signal kinds: metrics, logs, traces.
It is a noun about a **pipeline**: instrument → collect → transmit. `data-path.md`
§1–§2 is entirely telemetry.

*telemetry —— 訊號本身,加上「把它從產生處搬到別處」這個行為。三種 signal:metrics、
logs、traces。它是一個關於 **pipeline** 的名詞:instrument → collect → transmit。
`data-path.md` §1–§2 整章講的都是 telemetry。*

**observability** — borrowed from control theory: a system is observable if its
internal state can be inferred from its external outputs. In operations one
clause is added — **including questions you did not anticipate**. It is a
property of the **monitored system**, not of the tooling. `data-path.md` §3–§4
and `architecture.md`'s failure-mode tables are observability.

*observability —— 借自控制理論:若一個系統的內部狀態能從它的外部輸出推斷出來,
則該系統可觀測。維運語境多加一句限定 —— **包含你事先沒預料到的問題**。它是**被監控
系統**的性質,不是工具的性質。`data-path.md` §3–§4 和 `architecture.md` 的 failure
mode 表格談的是 observability。*

Telemetry is necessary and not sufficient. This stack ships
`node_textfile_mtime_seconds`, `node_textfile_scrape_error` and `pg_up` to
Grafana Cloud today; no dashboard, alert or query reads any of them. Telemetry
100%, observability 0% — which is only a coherent sentence if the two words mean
different things.

*telemetry 是必要而不充分的。這座 stack 今天就把 `node_textfile_mtime_seconds`、
`node_textfile_scrape_error`、`pg_up` 送進了 Grafana Cloud,但沒有任何 dashboard、
alert 或查詢讀它們。telemetry 100%、observability 0% —— 這句話只有在兩個詞意義不同時
才成立。*

> **A practical test.** If the fix is "collect more data", it is a telemetry gap.
> If the fix is "declare an expectation" or "ask a question nobody asked", it is
> an observability gap. `services.up < total` cannot see a target that vanished
> entirely — `up` is collected perfectly; what is missing is a declared
> `EXPECTED_TARGETS`, not a metric.
>
> ***一個實用判準。**如果解法是「多收一點資料」,那是 telemetry 缺口;如果解法是
> 「宣告一個期望」或「問一個沒人問過的問題」,那是 observability 缺口。
> `services.up < total` 看不到一個整個消失的 target —— `up` 收得好好的,缺的是一個
> 被宣告出來的 `EXPECTED_TARGETS`,不是一條 metric。*

The name of this directory follows industry convention (Grafana, Datadog and
CNCF all say "observability stack" for what is mostly a telemetry pipeline). The
convention is not wrong to follow; it is only worth knowing that the label
covers two things of very different completeness.

*這個目錄的命名沿用業界慣例(Grafana、Datadog、CNCF 都把「大部分是 telemetry
pipeline」的東西叫 observability stack)。跟著慣例沒有錯,只是要知道這個標籤底下蓋著
兩件完成度差很多的東西。*

---

## 2. The data model / 資料模型

**metric** — a named measurement, e.g. `node_filesystem_avail_bytes`. On its own
a metric name is a *family*, not one thing to plot: it usually expands into many
series once labels are attached.

*metric —— 一個具名的量測,例如 `node_filesystem_avail_bytes`。單看名字它是一個
**family**,不是一條可以直接畫的線:加上 label 之後通常會展開成很多條 series。*

**label** — a key/value pair attached to a metric that says *which instance* of
it this is: `{device="/dev/sda1", mountpoint="/"}`. Labels are the dimensions you
can later slice by; they are the reason `sum by (namespace)` gives per-app
numbers with zero per-app instrumentation.

*label —— 掛在 metric 上的鍵值對,說明「這是它的哪一個實例」:
`{device="/dev/sda1", mountpoint="/"}`。label 就是你事後可以切的維度;也正是
`sum by (namespace)` 能在零埋點的情況下給出 per-app 數字的原因。*

**series** — a metric name **plus its full label set**. This is the unit of
identity: change any one label value and it is a different series, stored
separately, charted as a different line. `__name__` is itself just a label, so
"metric name plus labels" is really "the complete label set".

*series —— metric 名稱**加上它完整的 label 集合**。這是身分的單位:任何一個 label 值
變了就是另一條 series,分開儲存、畫成不同的線。`__name__` 本身也只是一個 label,
所以「名稱加 label」其實就是「完整的 label 集合」。*

**sample** — one (value, timestamp) pair belonging to one series. One scrape of a
target produces exactly one sample per series that target currently exposes.

*sample —— 屬於某一條 series 的一組(值、時間戳)。對一個 target 做一次 scrape,會為
它當下暴露的每一條 series 各產生剛好一個 sample。*

**cardinality** — how many series exist. It **multiplies**: a metric with 3
devices × 5 mountpoints is 15 series, not 8. This is why one careless
high-variance label (a user ID, a request path, a timestamp) is the classic way
to destroy a metrics backend.

*cardinality —— 存在多少條 series。它是**相乘**的:3 個 device × 5 個 mountpoint
是 15 條 series,不是 8 條。所以一個沒想清楚的高變異 label(user ID、request path、
時間戳)是搞垮 metrics backend 的經典手法。*

**active series** — the series a backend currently holds as live. This is the
unit **Grafana Cloud bills on**, not sample count and not bytes — which is why
the kubelet allowlist (§3) matters commercially and not just for memory.

*active series —— backend 當下視為存活的 series 數。**Grafana Cloud 是按這個計費的**,
不是 sample 數、也不是位元組 —— 所以 §3 的 kubelet allowlist 是商業問題,不只是記憶體
問題。*

---

## 3. Metric types / metric 型別

**counter** — a value that only ever goes up (or resets to 0 on restart).
`node_cpu_seconds_total`. You never read a counter directly; you read `rate()` of
it. Because each sample carries the running total, **losing one sample costs
resolution, not data** — the next sample still contains everything.

*counter —— 只會往上加的值(或在重啟時歸零)。例如 `node_cpu_seconds_total`。你不會
直接讀 counter,而是讀它的 `rate()`。因為每個 sample 都帶著累計總量,**掉一個 sample
損失的是解析度,不是資料** —— 下一個 sample 仍然包含全部。*

**gauge** — a value that goes up and down and means something on its own:
`node_filesystem_avail_bytes`, and every metric the two textfile scripts write.
A gauge sample describes only that instant, so **a missed scrape is a hole
nothing can fill in later**. This asymmetry is the whole of `data-path.md` §3.1.

*gauge —— 會上下變動、而且本身就有意義的值:`node_filesystem_avail_bytes`,以及兩支
textfile script 寫出來的每一條 metric。gauge 的 sample 只描述那一瞬間,所以**漏掉一次
scrape 就是一個之後補不回來的洞**。這個不對稱就是 `data-path.md` §3.1 的全部內容。*

**histogram** — a bucketed distribution, exposed as N `_bucket` series plus
`_sum` and `_count`. One histogram with one label combination is **N+2 series**,
which is where kubelet's ~46,563 samples per scrape come from. Histograms are
the single biggest cardinality amplifier in a normal stack.

*histogram —— 分桶的分佈,暴露成 N 條 `_bucket` series 再加 `_sum` 與 `_count`。
一個 histogram 配一組 label 就是 **N+2 條 series**,kubelet 每次 scrape 那 ~46,563
個 sample 就是這樣來的。在一般的 stack 裡,histogram 是最大的 cardinality 放大器。*

**info** — a metric whose **value is always 1** and whose entire payload is in
its labels: `node_uname_info{release="5.15.0", machine="aarch64"}`. Used to join
metadata onto other series at query time.

*info —— **值恆為 1**、真正的內容全在 label 裡的 metric:
`node_uname_info{release="5.15.0", machine="aarch64"}`。用來在查詢時把 metadata
join 到其他 series 上。*

---

## 4. Collection / 採集

**registry** — the in-memory table inside an exporter that holds every metric it
knows how to expose. It is the thing `/metrics` renders. node-exporter's registry
is rebuilt on each scrape by asking its collectors; it is not a database and
survives nothing.

*registry —— exporter 內部那張放著它所有可暴露 metric 的記憶體表格。`/metrics` 渲染的
就是它。node-exporter 的 registry 在每次 scrape 時透過詢問各個 collector 重建,它不是
資料庫,重啟後什麼都不留。*

**exposition format** — the plain-text line format Prometheus reads:
`name{labels} value [timestamp]`, one series per line. It is **cumulative-only by
structure**, not by convention: there is one optional timestamp slot per line and
no slot for a start time, so a delta has nowhere to say what interval it covers.

*exposition format —— Prometheus 讀的純文字行格式:`name{labels} value [timestamp]`,
一行一條 series。它**在結構上就只能是 cumulative**,不是慣例問題:每行只有一個選用的
時間戳欄位、沒有起始時間的欄位,所以 delta 根本沒有地方說明自己涵蓋哪一段區間。*

**scrape** — one HTTP GET against a target's `/metrics`, parsed into samples. It
is a **read with no side effects**, which is what makes pull viable: anyone may
call it, any number of times, and nothing changes. A delta format would have to
consume-on-read and break that.

*scrape —— 對某個 target 的 `/metrics` 做一次 HTTP GET,解析成 sample。它是**沒有副
作用的讀取**,這正是 pull 模式可行的原因:任何人、任何次數呼叫它,什麼都不會改變。
delta 格式必須「讀取即消費」,那就破壞了這件事。*

**target** — one endpoint to be scraped. This stack has five scrape jobs:
kubelet, cadvisor, node_exporter, postgres, app_pods. Four of them **discover**
their targets from the Kubernetes API; `postgres` alone is a **static** target
(a literal Service address), which is why it can never leave discovery and
therefore fails visibly as `up = 0` rather than by disappearing.

*target —— 一個要被 scrape 的端點。這座 stack 有五個 scrape job:kubelet、cadvisor、
node_exporter、postgres、app_pods。其中四個從 Kubernetes API **discover** 自己的
target;只有 `postgres` 是**靜態** target(寫死的 Service 位址),所以它永遠不會從
discovery 中消失,壞掉時會誠實地變成 `up = 0`,而不是整條不見。*

**`up`** — a **synthetic** metric Prometheus/Alloy creates itself, one per
target: 1 if the last scrape succeeded, 0 if it failed. It comes from the
collector, never from the target — which is exactly why a target that stops
being *discovered* produces no `up = 0`; it produces **no series at all**.

*`up` —— Prometheus/Alloy 自己生出來的**合成** metric,每個 target 一條:上次 scrape
成功是 1、失敗是 0。它來自 collector、從來不是來自 target —— 所以一個不再被 **discover**
的 target 不會產生 `up = 0`,它會**什麼 series 都不產生**。*

**staleness marker** — a special NaN sample the collector writes when a series it
was previously scraping disappears, so queries stop returning the last known
value immediately instead of coasting.

*staleness marker —— 當一條先前有在 scrape 的 series 消失時,collector 寫入的一個特殊
NaN sample,讓查詢立刻停止回傳最後已知值,而不是繼續滑行。*

**lookback delta** — the backstop for the same problem: a query at time *t* looks
back at most **5 minutes** (default) for a sample. Beyond that a series is
treated as absent even without a staleness marker. This is also why
`scrape_interval = "5m"` on the kubelet job sits exactly on the boundary and is
noted as unverified in `data-path.md` §5.

*lookback delta —— 同一個問題的後備機制:時間點 *t* 的查詢最多往回找 **5 分鐘**(預設)
內的 sample,超過就視為該 series 不存在,即使沒有 staleness marker。這也是為什麼
kubelet job 的 `scrape_interval = "5m"` 剛好壓在邊界上,`data-path.md` §5 把它標為未驗證。*

**exporter** — a process that translates some existing source into exposition
format. It **measures nothing itself**: node-exporter reads `/proc` and `/sys`
(the kernel is the one counting), postgres-exporter runs SQL against Postgres's
own statistics views.

*exporter —— 把某個既有來源翻譯成 exposition format 的行程。它**自己不量測任何東西**:
node-exporter 讀 `/proc` 和 `/sys`(在數數的是 kernel),postgres-exporter 對 Postgres
自己的統計 view 下 SQL。*

**textfile collector** — a node-exporter collector whose input is **a directory**:
it reads every `*.prom` file in `/var/lib/node_exporter/textfile_collector` and
splices the contents verbatim into its `/metrics` response. The directory *is*
the interface — no API, no handshake, two independent lifecycles (a systemd timer
writes as root; the pod reads as `nobody`). See `data-path.md` §1.2 for the two
traps this creates: atomic write, and `chmod 0644`.

*textfile collector —— node-exporter 的一個 collector,它的輸入是**一個目錄**:讀取
`/var/lib/node_exporter/textfile_collector` 底下所有 `*.prom`,把內容原封不動貼進
`/metrics` 回應。**目錄就是介面** —— 沒有 API、沒有握手,兩個獨立的生命週期(systemd
timer 以 root 寫入;pod 以 `nobody` 讀取)。由此產生的兩個陷阱(原子寫入、`chmod 0644`)
見 `data-path.md` §1.2。*

---

## 5. The pipeline / 管線

**collector** (the Alloy sense) — the process that scrapes targets and forwards
samples onward. Distinct from a node-exporter *collector* (a plug-in module
inside an exporter); the word is overloaded and context decides.

*collector(Alloy 的那個意思)—— 負責 scrape 各 target 並把 sample 往下游轉送的行程。
與 node-exporter 裡的 *collector*(exporter 內部的一個外掛模組)不同;這個詞一詞多義,
看上下文決定。*

**relabel** — rewriting, keeping or dropping a series based on its labels,
**before** it is stored or shipped. `prometheus.relabel "kubelet_keep"` is an
**allowlist** on `__name__` that discards ~99.9% of kubelet's series. Note the
ordering that costs memory: relabelling happens *after* parsing, so the dropped
series were still scraped, still parsed into label sets, and only then thrown
away.

*relabel —— 在儲存或送出**之前**,依據 label 改寫、保留或丟棄一條 series。
`prometheus.relabel "kubelet_keep"` 是一個作用在 `__name__` 上的 **allowlist**,丟掉
kubelet 約 99.9% 的 series。注意那個花掉記憶體的順序:relabel 發生在解析**之後**,
所以被丟掉的 series 仍然被抓下來、仍然被解析成 label set,然後才被丟掉。*

**remote_write** — the push protocol that ships samples from a collector to a
remote backend. This stack has exactly one:
`prometheus.remote_write "grafanacloud"`.

*remote_write —— 把 sample 從 collector 推送到遠端 backend 的協定。這座 stack 只有
一個:`prometheus.remote_write "grafanacloud"`。*

**WAL** (write-ahead log) — the on-disk buffer holding samples that have been
scraped but not yet acknowledged by the remote endpoint. It is **bounded** and
entries are **discarded once acked** — which is precisely why an `emptyDir` is
safe here. Do not confuse it with an accumulator: a WAL buffers what has not been
sent, an accumulator holds running totals that can never be discarded.

*WAL(write-ahead log)—— 存放「已 scrape 但遠端尚未確認」的 sample 的磁碟緩衝。它是
**有界的**,而且**一經確認就丟棄** —— 所以這裡用 `emptyDir` 是安全的。不要跟
accumulator 混淆:WAL 緩衝的是還沒送出的東西,accumulator 持有的是永遠不能丟棄的累計
總量。*

**`emptyDir`** — a Kubernetes volume that is created empty when a pod is placed
on a node and deleted when that pod goes away. Disk-backed by default;
`medium: Memory` makes it tmpfs instead, which then counts against the
container's memory limit. Its lifetime is tied to the **pod**, not the
container: a container restart (OOMKill, failed liveness probe) keeps it, while
a rollout, eviction or reschedule does not, and it never follows a pod to
another node. That single property is why it fits the WAL and would not fit
Postgres. Measured 2026-08-08: Alloy's is 14 MB at `/var/lib/alloy/data`, and
the only PVC in the whole cluster is `data/postgres-data` (1Gi).

*`emptyDir` —— 一種 Kubernetes volume,在 pod 被排到節點上時建立成空目錄,pod 消失
時一起刪掉。預設由磁碟支撐;設 `medium: Memory` 則改成 tmpfs,而那會計入 container 的
memory limit。它的生命週期綁在 **pod** 而不是 container:container 重啟(OOMKill、
liveness probe 失敗)它會留著,rollout、eviction 或重新排程則不會,而且它永遠不會跟著
pod 換到另一個節點。就是這一個性質讓它適合 WAL、不適合 Postgres。2026-08-08 實測:
Alloy 的那個在 `/var/lib/alloy/data`,14 MB;整座 cluster 唯一的 PVC 是
`data/postgres-data`(1Gi)。*

**backfill** — the replay of buffered samples after a broken remote endpoint
recovers. This is why scraping and shipping are decoupled, and why a
**network-only** outage costs nothing while a **scrape** outage costs every gauge
in the window.

*backfill —— 遠端端點恢復後,把緩衝的 sample 重播出去。這就是 scrape 與 ship 解耦的
意義,也是為什麼**純網路**中斷不損失任何東西,而 **scrape** 中斷會損失該窗口內的每一條
gauge。*

**external label** — a label the collector stamps onto every series it ships, to
identify the source. Here: `cluster` (from `CLUSTER_NAME`, currently `fra-k3s`)
and `fleet = "lans-h-cc"`. Every PromQL example in these docs filters on
`cluster` for exactly this reason.

*external label —— collector 在它送出的每一條 series 上蓋的 label,用來標示來源。這裡
是 `cluster`(來自 `CLUSTER_NAME`,目前是 `fra-k3s`)和 `fleet = "lans-h-cc"`。本目錄
所有 PromQL 範例都用 `cluster` 過濾,原因就在這。*

---

## 6. Temporality / 時間性

**temporality** — the question of **who holds the accumulator**. It is the
hardest real difference between the Prometheus and OpenTelemetry data models.

*temporality —— 「**accumulator 在誰手上**」這個問題。它是 Prometheus 與 OpenTelemetry
資料模型之間最硬的一個實質差異。*

**cumulative** — each sample carries the running total since process start; the
**producer** holds the accumulator. Samples are redundant with one another, so
loss is cheap. The OTLP spec default, and the only thing exposition format can
express — therefore the only thing in this stack.

*cumulative —— 每個 sample 帶著自行程啟動以來的累計總量;accumulator 在**產生端**。
sample 彼此冗餘,所以掉了不貴。這是 OTLP 規格的預設值,也是 exposition format 唯一表達
得了的東西 —— 因此是這座 stack 裡唯一存在的形式。*

**delta** — each sample carries only the change since the last one; the
**consumer** must hold the accumulator. Samples are **not** redundant, so each
loss is permanent. Opt-in via
`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE`.

*delta —— 每個 sample 只帶著相對於上一個的變化量;accumulator 必須由**消費端**持有。
sample 之間**不**冗餘,所以每一次遺失都是永久的。要透過
`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` 明確開啟。*

**accumulator** — the running-total state itself. Knowing where it lives explains
most of this stack's design: it lives in the **kernel**, so node-exporter is
stateless, Alloy is stateless, and neither needs a PVC. Delta→cumulative
conversion would move it into the collector, keyed on the full label set —
O(active series), and fatal to horizontal scaling, because two replicas scraping
one series produce identical label sets and the backend rejects them as
duplicates.

*accumulator —— 累計狀態本身。知道它住在哪就能解釋這座 stack 大部分的設計:它住在
**kernel** 裡,所以 node-exporter 無狀態、Alloy 無狀態,兩者都不需要 PVC。做
delta→cumulative 轉換會把它搬進 collector、以完整 label 集合為 key —— O(active series),
而且對橫向擴展是致命的:兩個 replica 抓同一條 series 會產生完全相同的 label 集合,
backend 會當成重複而拒絕。*

---

## 7. Query / 查詢

**PromQL** — Prometheus's query language. Note that OpenTelemetry has **no query
language at all** — it standardises production and transport and stops before
storage. That asymmetry is why "Prometheus vs OTel" is a category error.

*PromQL —— Prometheus 的查詢語言。注意 OpenTelemetry **完全沒有查詢語言** —— 它標準化
產生與傳輸,到 storage 之前就停了。這個不對稱就是「Prometheus vs OTel」屬於 category
error 的原因。*

**instant vector / range vector** — one sample per series at a point in time, vs
every sample per series over a window (`[5m]`). Functions like `rate()` take a
range vector and return an instant vector.

*instant vector / range vector —— 每條 series 在某個時間點的一個 sample,對比每條
series 在一段窗口(`[5m]`)內的所有 sample。像 `rate()` 這類函式吃 range vector、
回傳 instant vector。*

**`rate()`** — per-second average increase of a counter over a window, with
counter resets handled. Never plot a raw counter; plot its `rate()`.

*`rate()` —— counter 在一段窗口內的每秒平均增量,並且會處理 counter 重置。永遠不要直接
畫 counter,要畫它的 `rate()`。*

**`absent()` / `absent_over_time()`** — the only way to alert on something that
**is not there**. A series that vanished matches no selector, so nothing can fire
on it; `absent()` must therefore **name the thing** it expects, spelling out the
full label set in the query. `absent_over_time(x[10m])` is the alerting form —
it does not flap on a single missed scrape.

*`absent()` / `absent_over_time()` —— 對「**不存在的東西**」發警報的唯一方法。消失的
series 匹配不到任何 selector,所以沒有東西能觸發;因此 `absent()` 必須在查詢裡**把它
期望的東西寫出來**,完整拼出 label 集合。`absent_over_time(x[10m])` 是用於告警的形式 ——
不會因為單次漏 scrape 而抖動。*

**dead man's switch** — an alert that fires when a **heartbeat stops**, rather
than when a bad condition appears. It is the structural answer to "who monitors
the monitor": a silent pipeline and a healthy pipeline look identical from the
outside, and only an expected-but-missing signal distinguishes them. This stack
does not have one — see the open items in `data-path.md`.

*dead man's switch —— 當**心跳停止**時觸發的警報,而不是當壞狀況出現時觸發。它是
「誰來監控監控系統」這個問題的結構性答案:從外面看,一條沉默的 pipeline 和一條健康的
pipeline 長得一模一樣,只有「應該出現卻沒出現的訊號」能區分兩者。這座 stack 目前沒有
—— 見 `data-path.md` 的未決事項。*

---

## 8. Not defined here / 本文未收錄

Kubernetes terms (`DaemonSet`, `hostNetwork`, `NetworkPolicy`, `ConfigMap`) are
assumed and are covered by the platform docs. Anything specific to the shape of
*this* stack — the five hops, the trust boundaries, the redaction contract — is
in `architecture.md` and `data-path.md` rather than here; a glossary that starts
explaining architecture stops being findable.

*Kubernetes 名詞(`DaemonSet`、`hostNetwork`、`NetworkPolicy`、`ConfigMap`)視為已知,
由 platform 的文件涵蓋。任何屬於**這座** stack 特定形狀的東西 —— 五段 hop、trust
boundary、redaction contract —— 放在 `architecture.md` 和 `data-path.md`,不放這裡;
一份開始解釋架構的 glossary 就不再查得動了。*
