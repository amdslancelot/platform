# Data path — where a number comes from, and what a break costs

*資料路徑 —— 一個數字從哪裡來,以及斷掉時的代價*

This document follows a single number from the moment it exists to the moment a
visitor sees it, and then asks the only question that matters operationally:
**when a link in that chain breaks, which metrics lose data and which do not.**
The answer is not uniform — it depends on the metric's type and on *where* the
break is, and the two combine in ways that are not obvious.

*本文追蹤一個數字從誕生到訪客看見的完整路徑,然後問那個真正重要的維運問題:
**鏈條斷掉時,哪些 metric 會遺失資料、哪些不會。** 答案不是一致的 —— 它取決於
metric 的 type 以及**斷點的位置**,而這兩者的組合並不直觀。*

| Document | Answers |
|---|---|
| `../README.md` | What is monitored, and from which source |
| `architecture.md` | What shape the stack is, and how it fails |
| `runbook.md` | How to install it, command by command |
| `pending.md` | Why each choice was made; what is deferred |
| **`data-path.md`** | **Where each number comes from, and what a break costs** |

`architecture.md` describes the components. This document describes what flows
*through* them. Read that one for the shape; read this one before diagnosing a
gap in a graph.

*`architecture.md` 描述元件,本文描述**流經**元件的東西。要看形狀讀那份,
要診斷圖上的一個缺口讀這份。*

---

## 1. Where the numbers are born / 數字在哪裡誕生

### 1.1 `:9100/metrics` has four sources, not one

node-exporter does not measure anything. It is a **translator**: when something
GETs `/metrics`, it opens files and makes syscalls, converts what it finds into
the Prometheus exposition format, and writes the response. Nothing is stored
between requests.

*node-exporter 不量測任何東西。它是一台**翻譯機**:有人 GET `/metrics` 時,它才
開檔、呼叫 syscall,把讀到的東西轉成 Prometheus exposition format 寫回去。
兩次請求之間它什麼都不留。*

The four sources are declared in `../node-exporter.yaml` — the volume mounts
**are** the list:

*四個來源就寫在 `../node-exporter.yaml` 裡 —— 那幾個 volume mount **就是**清單:*

| Source | Mounted as | Produces | Who holds the running total |
|---|---|---|---|
| `/proc` | `--path.procfs=/host/proc` | CPU, memory, load, network, disk I/O | **the kernel**, since boot |
| `/sys` | `--path.sysfs=/host/sys` | device and hardware state | the kernel / driver |
| syscalls | `--path.rootfs=/host/root` | `statfs()` per mountpoint, `uname()` | the filesystem, right now |
| textfile | `--collector.textfile.directory=/host/textfile` | **our own** image + log metrics | `image-metrics.sh` / `log-size.sh` |

Concretely:

```
/proc/stat      → node_cpu_seconds_total, node_boot_time_seconds
/proc/meminfo   → node_memory_MemTotal_bytes, node_memory_MemAvailable_bytes
/proc/loadavg   → node_load1 / node_load5 / node_load15
/proc/net/dev   → node_network_receive_bytes_total
/proc/diskstats → node_disk_read_bytes_total, node_disk_io_time_seconds_total
/proc/mounts    → the mountpoint list, then statfs() on each → node_filesystem_*
uname()         → node_uname_info
```

This is why the DaemonSet needs `hostNetwork: true`, `hostPID: true` and those
three `hostPath` mounts. Without them the container sees its **own** `/proc`
namespace, and the numbers would describe node-exporter rather than the node.

*這就是那個 DaemonSet 需要 `hostNetwork: true`、`hostPID: true` 和三個 `hostPath`
的原因。沒有它們,容器看到的是**自己的** `/proc` namespace,量到的會是
node-exporter 這個 process,不是節點。*

### 1.2 The textfile collector, and its two traps

The fourth source is the odd one out and deserves its own section, because it is
the only source we write ourselves and the only one with a hand-rolled contract.

*第四個來源是異類,值得單獨一節 —— 它是唯一由我們自己寫的來源,也是唯一有一份
手工約定的來源。*

The mechanism is as plain as it sounds: node-exporter reads every `*.prom` file
in `/var/lib/node_exporter/textfile_collector/` **on every scrape** and inlines
the contents into its `/metrics` response verbatim. There is no API, no socket,
no handshake — the directory *is* the interface.

*機制就跟字面一樣直白:node-exporter **每次 scrape** 都會讀
`/var/lib/node_exporter/textfile_collector/` 底下所有 `*.prom` 檔,把內容原封不動
貼進自己的 `/metrics` 回應裡。沒有 API、沒有 socket、沒有握手 —— **那個目錄就是介面**。*

```
observability-metrics.timer          node-exporter pod
(systemd, on the host, as root)      (container, runs as `nobody`)
        │                                    │
        │  writes                     reads  │
        ▼                                    ▼
    /var/lib/node_exporter/textfile_collector/*.prom
```

Two entirely independent lifecycles. The timer does not know node-exporter
exists; node-exporter does not know who wrote the files. That decoupling is what
makes the collector useful, and it is also the root of the failure mode in §3.3.

*兩個完全獨立的生命週期。timer 不知道 node-exporter 存在,node-exporter 不知道檔案
是誰寫的。這個解耦讓它好用,也正是 §3.3 那個失效模式的根源。*

**Trap 1 — the write must be atomic.** Writing straight to `log_size.prom` with
`>` truncates it first and then fills it line by line. A scrape landing in that
window reads a half-written file. The worse outcome is not a parse error but a
file that got cut at a line boundary: **syntactically valid, silently
incomplete**. Both scripts avoid this correctly — `mktemp` in the *same*
directory, write at leisure, then `mv`:

***陷阱一 —— 寫入必須是原子的。** 直接用 `>` 寫 `log_size.prom` 會先截斷再逐行填。
scrape 落在那個窗口裡就會讀到寫到一半的檔。更糟的結果不是語法錯誤,而是剛好斷在行尾的檔:
**語法完全合法,內容靜默不完整**。兩支 script 都正確避開了 —— 在**同一個**目錄下
`mktemp`,慢慢寫,最後 `mv`:*

```bash
tmp="$(mktemp "$OUT_DIR/.log_size.XXXXXX")"   # same dir => same filesystem
{ ...generate... } > "$tmp"                   # takes as long as it takes
mv "$tmp" "$OUT_DIR/log_size.prom"            # rename(2) — atomic
```

`mv` within one filesystem is the `rename()` syscall, which is atomic: a reader
sees either the whole old file or the whole new one, never an intermediate
state. `mktemp` must therefore open in the destination directory — a temp file
on another filesystem turns `mv` into copy-then-delete and the guarantee is
gone.

*同一個 filesystem 內的 `mv` 就是 `rename()` syscall,而它是原子的:讀的人要嘛看到
完整的舊檔、要嘛看到完整的新檔,不存在中間狀態。所以 `mktemp` 必須開在目標目錄下 ——
暫存檔放在別的 filesystem 會讓 `mv` 退化成複製再刪除,保證就沒了。*

**Trap 2 — the file must be world-readable.** node-exporter runs as `nobody`
inside the container. `mktemp` creates `0600` owned by root, and `mv` preserves
the mode, so without an explicit `chmod 0644` the finished `.prom` is
unreadable. The failure mode is **a silently missing metric, not an error** —
node-exporter serves everything else and the graph simply has no line on it.
Both scripts carry the `chmod` and a comment saying why.

***陷阱二 —— 檔案必須讓所有人可讀。** node-exporter 在容器裡跑成 `nobody`。`mktemp`
建出來是 root 擁有的 `0600`,而 `mv` 會保留權限,所以沒有明確 `chmod 0644` 的話,
完成的 `.prom` 是讀不到的。失敗模式是**metric 靜默消失,不是報錯** —— node-exporter
照常提供其他一切,只是圖上少一條線。兩支 script 都有那行 `chmod` 和說明註解。*

> Anyone writing a third textfile script must repeat both. They are properties
> of the contract, not of these two scripts.
>
> *任何人要寫第三支 textfile script 都必須重複這兩件事。它們是這份約定的性質,
> 不是這兩支 script 的性質。*

### 1.3 Metric types — the type decides what a break costs

Four types matter here. The distinction looks academic until section 3, where
it turns out to be the whole answer.

*這裡有四種 type 要分。這個區分看起來很學術,直到第 3 節 —— 它就是全部的答案。*

| Type | Meaning | Example |
|---|---|---|
| **counter** | only ever increases; resets to 0 only when the producer restarts | `node_cpu_seconds_total` |
| **gauge** | goes up and down; **the value right now** | `node_memory_MemAvailable_bytes` |
| **info** | value is always `1`; the payload is entirely in the labels | `node_uname_info{nodename=…}` |
| **histogram** | one series per bucket, plus `_sum` and `_count` | (rare in node-exporter; dominant in kubelet) |

Two consequences worth stating plainly:

*兩個值得明講的後果:*

**`info` metrics leak through labels, not through values.** `node_uname_info`
carries the hostname and kernel version as labels. Anything that can reach
`:9100` reads them. That is the same hostname the public snapshot deliberately
withholds — see `architecture.md`'s redaction contract, and note that the two
surfaces have different threat models but the same underlying data.

***`info` metric 是靠 label 洩漏,不是靠數值。** `node_uname_info` 的 label 帶著
hostname 和 kernel 版本,任何連得到 `:9100` 的人都讀得到。那正是公開快照刻意
不給的 hostname —— 見 `architecture.md` 的 redaction contract。兩個出口的
threat model 不同,但底層是同一批資料。*

**Every metric our own scripts write is a `gauge`.** `log-size.sh` declares
`pod_log_dir_size_bytes` and `pod_log_total_bytes` as gauges;
`image-metrics.sh` declares `containerd_images_total`,
`containerd_images_logical_size_bytes`, `image_store_disk_bytes` and
`container_image_logical_size_bytes` as gauges. Not one counter among them.
Section 3.3 explains why that matters more than it looks.

***我們自己的 script 寫出來的 metric 全部是 `gauge`。** `log-size.sh` 宣告
`pod_log_dir_size_bytes` 與 `pod_log_total_bytes` 為 gauge;`image-metrics.sh` 的
四個也都是 gauge,一個 counter 都沒有。為什麼這比看起來嚴重,見 §3.3。*

### 1.4 The other three targets

`:9100` is one of five scrape jobs. The others have their own provenance, and
the same type logic applies to each:

*`:9100` 只是五個 scrape job 之一。其餘各有來源,同樣的 type 邏輯適用於每一個:*

| Job | Target | Where its numbers come from |
|---|---|---|
| `kubelet` | node InternalIP `:10250/metrics` | kubelet's own in-process registry |
| `cadvisor` | node InternalIP `:10250/metrics/cadvisor` | cgroup v2 files under `/sys/fs/cgroup` |
| `node-exporter` | node InternalIP `:9100` | the four sources above |
| `postgres` | `postgres-exporter…:9187` | **SQL run against Postgres at scrape time** |
| `app-pods` | any pod with `prometheus.io/scrape: "true"` | that app's own in-process registry |

Note the asymmetry in cost. Scraping snoopy reads a few variables in RAM;
scraping postgres-exporter **runs a set of queries against the shared
Postgres**; scraping kubelet makes it serialize ~46,563 series. `scrape_interval`
is therefore a load knob on the *target*, not only on Alloy — which is a second,
undocumented reason the kubelet job was moved to `5m`.

*注意成本的不對稱。抓 snoopy 是讀幾個記憶體變數;抓 postgres-exporter 是**對共用
Postgres 跑一整組查詢**;抓 kubelet 是逼它序列化約 46,563 條 series。所以
`scrape_interval` 是對**目標端**的負載旋鈕,不只是對 Alloy —— 這是 kubelet job 改成
`5m` 的第二個、原本沒寫下來的理由。*

---

## 2. The five hops / 五段路

```
  ①              ②                ③                    ④                ⑤
kernel  ──▶  /metrics  ──▶  Alloy scrape  ──▶  remote_write  ──▶  Grafana Cloud
 /proc       exposition      + relabel           over TLS            (TSDB)
 /sys          format          + WAL                                    │
 SQL                                                                    │
 .prom                                                                  ▼
                                                            public-metrics.timer
                                                              (queries it back)
                                                                        │
                                                                        ▼
                                                             ConfigMap ──▶ nginx
                                                                        ──▶ fleet.html
```

| Hop | What moves | State held here |
|---|---|---|
| ① → ② | nothing until asked | **the accumulator, in the kernel** |
| ② → ③ | one HTTP GET per scrape interval | none — exposition format is a rendering |
| ③ | parse → relabel → append to WAL | scrape targets; a staleness set; the WAL |
| ③ → ④ | batched samples, TLS, basic_auth | the WAL, until the write is acknowledged |
| ④ → ⑤ | accepted samples | **the only durable copy** |
| ⑤ → page | a fixed set of PromQL queries, every 5m | the last good ConfigMap |

Two properties of this chain are load-bearing and worth naming:

*這條鏈有兩個承重的性質:*

**Nothing between the kernel and Grafana Cloud accumulates.** node-exporter
holds no running totals; Alloy holds no running totals. Alloy's WAL is not an
accumulator — it buffers samples **not yet acknowledged** by Grafana Cloud and
discards them once they are. That is why the WAL volume is an `emptyDir` and why
the whole stack owns no PersistentVolume.

***kernel 與 Grafana Cloud 之間沒有任何一段在累加。** node-exporter 不持有累計值,
Alloy 也不持有。Alloy 的 WAL 不是 accumulator —— 它暫存**尚未被 Grafana Cloud 確認**
的樣本,確認後就丟。這就是 WAL 用 `emptyDir`、整個 stack 不持有 PersistentVolume 的
原因。*

**Scraping and shipping are decoupled.** `prometheus.scrape` writes into the
WAL; `prometheus.remote_write` reads from it and ships. They fail
independently — which is the single most important fact in section 3.

***scrape 與 ship 是解耦的。** `prometheus.scrape` 寫進 WAL,`prometheus.remote_write`
從 WAL 讀出來送。兩者會獨立失敗 —— 這是第 3 節最重要的一個事實。*

---

## 3. What a break costs / 斷線的代價

### 3.1 The core asymmetry: counters survive, gauges do not

A counter sample is **redundant with every later sample of the same series**.
Miss ten scrapes of `node_cpu_seconds_total` and the eleventh already contains
everything that happened in between; `rate()` across the gap is still
arithmetically correct. What is lost is *resolution* — a 30-second spike inside
the gap is invisible — not the total.

*一個 counter 的 sample 跟**同一條 series 之後的每一個 sample 都是冗餘的**。漏抓十次
`node_cpu_seconds_total`,第十一次抓到的值已經包含中間發生的一切;跨越缺口的
`rate()` 在算術上仍然正確。損失的是**解析度**(缺口內一個 30 秒的尖峰看不見),
不是總量。*

A gauge sample is **the only record of that instant**. Miss it and the value at
that moment is gone permanently — no later sample can reconstruct it. If memory
peaked at 90% during the outage, that fact does not exist anywhere.

*一個 gauge 的 sample 是**那個瞬間唯一的紀錄**。漏掉就永遠沒有了,之後的任何 sample
都補不回來。如果斷線期間記憶體衝到 90%,這件事不存在於任何地方。*

### 3.2 But *where* the break is decides whether a gauge dies at all

This is the part that is not obvious. Because scraping and shipping are
decoupled (§2), a network outage between the node and Grafana Cloud **does not
stop scraping**. Alloy keeps collecting into its WAL and ships the backlog on
reconnect — with the original timestamps. Gauges survive that. They do **not**
survive a break that stops the scrape itself.

*這一段是不直觀的地方。因為 scrape 與 ship 解耦(§2),節點到 Grafana Cloud 之間的
斷網**不會讓 scrape 停止**。Alloy 繼續採集寫進 WAL,恢復連線後把積壓的資料連同
原始 timestamp 補送出去。gauge 在這種斷線下活得下來。但**讓 scrape 本身停止**的
斷線,gauge 就活不下來。*

| Break | Is scraping still happening? | Counters | Gauges | textfile metrics |
|---|---|---|---|---|
| node-exporter pod down | ❌ | ✅ total intact | ❌ **permanently lost** | ❌ lost |
| Alloy down | ❌ | ✅ total intact | ❌ **permanently lost** | ❌ lost |
| node ↔ Grafana Cloud network down | ✅ | ✅ | ✅ **backfilled from WAL** | ✅ backfilled |
| Grafana Cloud rejects writes (over 10k series) | ✅ | ⚠️ partial | ⚠️ partial | ⚠️ partial |
| `public-metrics.timer` fails | ✅ | ✅ | ✅ | ✅ (public page only) |

The bottom two rows deserve a note each.

**Over-quota rejection is the worst failure in this stack** because it is
*silent and partial*. Everything keeps running; some series simply stop
arriving. There is no `up=0`, no error on the page, no gap that looks like a
gap. `architecture.md`'s failure-mode table already flags this as the one row
without graceful degradation.

***超出額度被拒是這個 stack 最糟的失效**,因為它是**靜默且部分的**。一切照常運轉,
只是某些 series 不再送達。沒有 `up=0`、頁面沒有錯誤、缺口看起來不像缺口。
`architecture.md` 的失效模式表已經把這一列標為唯一沒有優雅降級的。*

**A `public-metrics.timer` failure costs nothing but the public page.** The
producer treats a failed query as fatal on purpose — publishing a snapshot with
silently-missing fields is worse than publishing nothing — so the ConfigMap
keeps its last good content and `fleet.html` ages it in the browser against
`generated_at`. The internal dashboard is unaffected; it reads Grafana Cloud
directly.

***`public-metrics.timer` 失敗只影響公開頁面。** 產生器刻意把查詢失敗視為致命 ——
發布一份欄位靜默缺漏的快照,比什麼都不發更糟 —— 所以 ConfigMap 保留最後一份好的
內容,而 `fleet.html` 在瀏覽器端用 `generated_at` 判斷它的年齡。內部儀表板不受影響,
它直接讀 Grafana Cloud。*

### 3.3 The third case: textfile metrics fail worse than gauges

Textfile metrics have **two independent producers**, and this creates a failure
mode the other sources do not have.

*textfile metric 有**兩個獨立的產生者**,這造成了其他來源沒有的失效模式。*

```
observability-metrics.timer  ──(every 5m)──▶  *.prom files on disk
                                                      │
                                           node-exporter reads them
                                             on every scrape
```

If the **timer** stops but scraping continues, the `.prom` files stay on disk
and node-exporter keeps serving them. It has no concept of a file being too old
— it reads whatever is there. The result on a graph is **a flat line at the
last known value**, which reads as "nothing changed" rather than "no data".

*如果 **timer** 停了但 scrape 繼續,`.prom` 檔還在磁碟上,node-exporter 照樣把它們
吐出來。它沒有「這個檔太舊了」的概念 —— 有什麼讀什麼。圖上的結果是**一條停在最後
一個值的水平線**,讀起來像「沒有變化」而不是「沒有資料」。*

> A dead collector that reports a plausible number is worse than one that
> reports nothing. A gap is visible; a flat line is not.
>
> *一個已死但仍回報合理數字的採集器,比什麼都不回報的更糟。缺口看得見,水平線
> 看不見。*

**The detector for this already exists and is not being used.**
node-exporter emits `node_textfile_mtime_seconds{file="…"}` — the modification
time of each `.prom` file. The node-exporter scrape job forwards to
`remote_write` with no filter, so this series is already in Grafana Cloud. As of
this writing nothing queries it: neither the dashboard, nor the public snapshot,
nor any alert.

***偵測這件事的工具已經存在,而且沒有被使用。** node-exporter 會吐出
`node_textfile_mtime_seconds{file="…"}`,也就是每個 `.prom` 檔的修改時間。
node-exporter 那個 scrape job 是無過濾直送 `remote_write` 的,所以這條 series
已經在 Grafana Cloud 裡。撰寫本文時沒有任何東西查詢它:儀表板沒有、公開快照沒有、
告警也沒有。*

The check is one expression:

*檢查只需要一條式子:*

```promql
# How stale is each textfile? Should stay under ~600s (2x the 5m timer).
# 每個 textfile 有多舊?應該維持在 600 秒以內(timer 間隔的 2 倍)。
time() - node_textfile_mtime_seconds{cluster="fra-k3s"}
```

This is the same shape as `fleet.html`'s browser-side staleness check, and for
the same reason: **the freshness test must live in the consumer, because a dead
producer says nothing about being dead.**

*這跟 `fleet.html` 瀏覽器端的 staleness 檢查是同一個形狀,理由也相同:**新鮮度的
判斷必須放在消費端,因為死掉的產生端不會說自己死了。***

There is a **second** unused signal next to it. `node_textfile_scrape_error` is
`1` when node-exporter failed to parse any `.prom` file in the directory, `0`
otherwise. It covers the failure `mtime` cannot see: a file that is fresh but
malformed — the output of a script that broke halfway through a rewrite, or a
new script whose format is wrong. The two are complementary and neither is
queried today.

*旁邊還有**第二個**沒被使用的訊號。`node_textfile_scrape_error` 在 node-exporter
無法解析目錄裡任何一個 `.prom` 檔時為 `1`,否則為 `0`。它覆蓋的是 `mtime` 看不到的
失效:**檔案很新但格式壞掉** —— 例如某支 script 改到一半壞了,或新 script 的格式寫錯。
兩者互補,而今天兩者都沒有被查詢。*

```promql
# Both textfile health signals, together. Neither is wired to anything today.
# 兩個 textfile 健康訊號。今天兩者都沒接到任何東西上。
time() - node_textfile_mtime_seconds{cluster="fra-k3s"}   # expect < 600
node_textfile_scrape_error{cluster="fra-k3s"}             # expect 0
```

> **Not verified:** that a parse failure sets `node_textfile_scrape_error=1` and
> node-exporter still serves everything else, rather than failing the whole
> `/metrics` response. That is the current upstream behaviour as understood, but
> it has not been tested on this node. It does not change the practice either
> way — the atomic write in §1.2 prevents both outcomes.
>
> ***未驗證:**解析失敗會設 `node_textfile_scrape_error=1` 且 node-exporter 仍然
> 提供其他一切,而不是整個 `/metrics` 回應失敗。這是目前理解的 upstream 行為,
> 但沒有在這台節點上實測。無論哪一種都不影響做法 —— §1.2 的原子寫入兩種結果都防得住。*

### 3.4 Which breaks are visible, and which are not

`up` is a synthetic sample the scraper writes for every discovered target — `1`
if the target answered with a parseable body, `0` otherwise. It is not emitted
by any target; `curl localhost:9100/metrics | grep '^up '` returns nothing.

*`up` 是 scraper 為每個被發現的 target 合成寫入的樣本 —— target 回了可解析的內容
就是 `1`,否則是 `0`。它不是任何 target 吐出來的;`curl localhost:9100/metrics |
grep '^up '` 什麼都找不到。*

| Break | Signal you get |
|---|---|
| node-exporter down | `up{job="node-exporter"} = 0` — visible |
| postgres-exporter down | `up{job="postgres"} = 0` — visible, and reliably so (§3.5) |
| an annotated app pod deleted | **the series disappears**; `count(up)` shrinks — *not* `up=0` |
| **Alloy down** | **total silence** — no `up=0` anywhere |
| node ↔ Grafana Cloud down | **total silence**, indistinguishable from Alloy being down |
| `.prom` timer stopped | **nothing** — a flat line (§3.3) |

Two gaps follow from that table, both currently open:

*這張表推出兩個目前未處理的缺口:*

**Alloy has no self-scrape.** None of the five jobs scrapes Alloy's own
`/metrics`, so an Alloy failure produces silence rather than a signal —
indistinguishable from a network outage, a revoked token, or the node losing
power. Silence is the one thing this design cannot report on its own.

***Alloy 沒有 self-scrape。** 五個 job 沒有一個在抓 Alloy 自己的 `/metrics`,所以
Alloy 故障產生的是靜默而非訊號 —— 跟斷網、token 被撤銷、節點斷電完全無法區分。
靜默是這個設計唯一無法自己回報的東西。*

**`services.up < services.total` cannot detect a vanished target.** The public
page compares `sum(up)` against `count(up)`. When a target leaves service
discovery entirely, both shrink together, the ratio stays n/n, and the page
looks healthy. It detects "present but not answering", never "gone".

***`services.up < services.total` 偵測不到消失的 target。** 公開頁面比較 `sum(up)`
與 `count(up)`。target 完全離開 service discovery 時,兩者一起變小,比值仍是 n/n,
頁面看起來一切正常。它偵測的是「在但不答」,永遠不是「不見了」。*

### 3.5 Why `postgres` is the one job that always reports honestly

Four of the five jobs get their targets from `discovery.kubernetes`. The
`postgres` job does not — its target is a literal address:

*五個 job 有四個從 `discovery.kubernetes` 取得目標。`postgres` job 不是 ——
它的目標是一個寫死的位址:*

```
targets = [{ __address__ = "postgres-exporter.observability.svc.cluster.local:9187" }]
```

A static target can never leave the target list. Scale the exporter to zero and
Alloy still tries, still fails to connect, and still writes `up=0`. Every
discovery-based job can instead have its target silently removed. This was not a
deliberate choice, but it is the correct behaviour, and it is worth preserving
if that block is ever rewritten.

*static target 永遠不會離開目標清單。把 exporter scale 到 0,Alloy 照樣去連、
照樣連不上、照樣寫 `up=0`。而每一個 discovery-based 的 job 都可能被靜默移除目標。
這不是刻意的選擇,但它是正確的行為,如果哪天要改寫那個區塊,值得保留。*

---

## 4. After an outage — what to check / 斷線恢復後檢查什麼

Run these in order. Each answers a different question from section 3.

*依序執行。每一條回答 §3 的一個不同問題。*

**Did the backfill arrive, or was the data lost?** If the gap closes after a few
minutes, it was a shipping outage and the WAL replayed. If it stays a gap, the
scrape itself was down.

```promql
node_memory_MemAvailable_bytes{cluster="fra-k3s"}
```

**Are all targets back, and is the count right?** Compare against the number you
recorded when the fleet was known healthy — `count(up)` alone cannot tell you
something is missing.

```promql
count by (job) (up{cluster="fra-k3s"})
```

**Are the textfile metrics fresh, or is that a flat line?** This is the check
§3.3 says nothing currently performs.

```promql
time() - node_textfile_mtime_seconds{cluster="fra-k3s"}     # expect < 600
node_textfile_scrape_error{cluster="fra-k3s"}               # expect 0 — fresh but malformed
```

**Did we quietly cross the series ceiling while recovering?** Backfill plus
churn can spike active series above steady state.

```promql
topk(10, count by (__name__) ({cluster="fra-k3s"}))
```

On the node itself:

```bash
kubectl -n observability get pods                       # 兩個 exporter + Alloy 都在?
kubectl -n observability logs deploy/alloy --tail=50    # remote_write 有沒有還在重試
systemctl status observability-metrics.timer            # .prom 的產生者還活著嗎
systemctl status public-metrics.timer                   # 公開快照的產生者
ls -l /var/lib/node_exporter/textfile_collector/        # 檔案的 mtime 是不是新的
```

---

## 5. Not verified / 尚未驗證

Stated here rather than buried, because each is a claim that would collapse
under one follow-up question.

*寫在這裡而不是埋在正文,因為每一條都是被追問一次就會垮掉的主張。*

- **How long the WAL covers.** `prometheus.remote_write "grafanacloud"` declares
  no `wal` block and no `queue_config`, so every buffering parameter is at
  Alloy's default. The defaults have not been read off this deployment. An
  outage longer than that window loses its oldest samples, and the length of
  that window is currently unknown.
  *WAL 能撐多久:`remote_write` 沒有宣告 `wal` 或 `queue_config`,全部走 Alloy 預設值,
  而那些預設值沒有在這個部署上實際確認過。超過那個窗口的斷線會遺失最舊的樣本,
  而窗口有多長目前不知道。*

- **Whether Grafana Cloud accepts a long backfill.** Replayed samples carry
  their original timestamps. If the ingester enforces an out-of-order or
  max-age limit, a sufficiently long outage's backlog is rejected on arrival
  rather than accepted. The limit for this stack has not been checked.
  *Grafana Cloud 會不會接受長時間的補送:補送的樣本帶著原始 timestamp。如果 ingester
  有 out-of-order 或最大年齡限制,夠長的斷線其積壓會在抵達時被拒而不是被接受。
  這個 stack 的限制值沒有查過。*

- **The `5m` kubelet interval's effect on kubelet itself.** §1.4 argues the
  change also reduced kubelet's serialization work. That follows from how
  scraping works but was not measured on this node.
  *kubelet `5m` interval 對 kubelet 自身的影響:§1.4 主張這個改動也減少了 kubelet
  的序列化工作。這從 scrape 的運作方式推得出來,但沒有在這台節點上量測。*

Both of the first two are answerable without changing anything — the first by
reading Alloy's defaults for the version in use, the second from the Grafana
Cloud stack's limits page.

*前兩項都可以在不改動任何東西的情況下回答:第一項讀該版本 Alloy 的預設值,
第二項看 Grafana Cloud stack 的限制頁面。*

---

## Open items this document surfaced / 本文浮現的未決事項

Recorded here; not yet tracked in `pending.md`.

*記在這裡,尚未進 `pending.md` 追蹤。*

| # | Item | Why it matters |
|---|---|---|
| 1 | Nothing queries `node_textfile_mtime_seconds` or `node_textfile_scrape_error` | A stopped `.prom` timer shows as a flat line, not a gap; a malformed one shows as nothing at all (§3.3) |
| 2 | Alloy has no self-scrape | Its own failure is silent and indistinguishable from three other causes (§3.4) |
| 3 | `services.up < total` cannot see a vanished target | The public page reads healthy while an app's metrics are gone (§3.4) |
| 4 | WAL coverage window unknown | Determines how long an outage can last before data is lost (§5) |
