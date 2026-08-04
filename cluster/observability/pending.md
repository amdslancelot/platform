# Observability — pending fixes and open decisions

*可觀測性 —— 待修項與未定決策*

Recorded 2026-07-29, extended 2026-08-02 and 2026-08-04. Five independent things
live here: **§1 had to be fixed before this stack could be applied at all**
(done), **§2 is a design choice that can stay open** — the stack works without
deciding it — **§3 is a machine nobody had counted**, which turns out to answer a
different question than §2 was asking, **§4 is what breaks if any of this ever
runs somewhere other than louis2** (one bug found and fixed, one landmine handed
to Phase B/C), and **§5 is a product limit that only bites if you want the
dashboards on your own site**.

*記錄於 2026-07-29,2026-08-02、2026-08-04 增補。這裡有五件互不相干的事:**§1 是 stack
上節點之前必須先修的**(已完成),**§2 是可以先擱著的設計選擇**(不決定它 stack 也能
上),**§3 是一台先前沒被算進來的機器** —— 結果它回答的是跟 §2 不同的問題,**§4 是「這些
東西如果跑在 louis2 以外的地方會壞掉什麼」**(找出並修掉一個 bug,另交還一個地雷給
Phase B/C),而 **§5 是一個只有在你想把 dashboard 放到自己網站時才會踩到的產品限制**。*

Branch state: `observability-stack`, rebased onto `main` (`f704340`) on
2026-08-02, **§1 resolved**, still not pushed and still not applied to the node.

*分支狀態:`observability-stack`,2026-08-02 已 rebase 到 `main`(`f704340`),
**§1 已處理完畢**,仍未 push、仍未套用到節點。*

---

## 1. Pre-flight fixes — required before applying ✅ DONE 2026-08-02

*套用前必修項 —— 已完成*

All of these exist because this branch was authored **before** the Phase B-1..B-4
security hardening landed on `main` (`a9d739e` NetworkPolicy, `f919ae6` postgres
limits). Rebase onto `main` first, then fix these.

*這些問題全部來自:本分支的撰寫時間**早於** Phase B-1..B-4 的加固進 `main`
(`a9d739e` NetworkPolicy、`f919ae6` postgres limits)。先 rebase 到 `main`,再修
以下各項。*

| # | Status | What was done |
|---|---|---|
| 1.1 | ✅ fixed | `cluster/networkpolicies/data.yaml` — added an `observability` namespaceSelector; runbook Step 2 now re-applies it before deploying the exporter |
| 1.2 | ⏸ deferred **by design** | Not a pre-emptive fix. The policy line is documented in runbook Step 4b and applied **per app, when that app opts in** |
| 1.3 | ✅ fixed | `namespace.yaml` — explicit `pod-security.kubernetes.io/enforce: privileged` + the reason, and why `warn/audit: restricted` is deliberately absent |
| 1.4 | ✅ fixed | runbook closing section B rewritten to point at `main`'s existing **daily** prune timer; section A kept and marked STILL OPEN with the k3s-restart caveat |
| 1.5 | ✅ fixed | runbook Step 5 disk query → `mountpoint=~"/\|/var/lib/rancher\|/var/lib/containers"` |

The subsections below are kept verbatim as the reasoning record — read them for
*why*, not for *what is left to do*. The only one still live is **1.2**, and it is
live on purpose.

*以下小節原文保留,作為推理紀錄 —— 讀它們是為了了解**為什麼**,不是為了找**還要做
什麼**。唯一仍未處理的是 **1.2**,而那是刻意的。*

One item escapes this branch entirely: **1.3's secondary note — node-exporter
binds `0.0.0.0:9100` under `hostNetwork`. Phase C's host firewall must account for
9100.** Not internet-reachable today (the OCI security list opens only 80/443/9000),
so it does not block this stack, but it must not be forgotten when Phase C lands.

*有一項超出本分支範圍:**1.3 的附帶事項 —— node-exporter 在 `hostNetwork` 下綁
`0.0.0.0:9100`,Phase C 的 host firewall 必須把 9100 算進去。**今天對外不可達
(OCI security list 只開 80/443/9000),所以不擋這個 stack,但 Phase C 時不能漏掉。*

### 1.1 `postgres-exporter` is blocked by the `data` NetworkPolicy

*`postgres-exporter` 會被 `data` 的 NetworkPolicy 擋掉*

`cluster/networkpolicies/data.yaml`'s `allow-ingress-apps` admits only the
`snoopy`, `gelp` and `transigen` namespaces plus `ipBlock 10.0.0.240/32`. The
exporter runs in `observability` with a pod IP in `10.42.0.0/16`, so it matches no
rule and its 5432 connection is **silently dropped** — runbook Step 2's
verification will just hang.

*`data.yaml` 的 `allow-ingress-apps` 只放行 `snoopy`、`gelp`、`transigen` 三個
namespace 加 `ipBlock 10.0.0.240/32`。exporter 在 `observability`、pod IP 屬
`10.42.0.0/16`,不匹配任何規則,5432 **靜默丟包** —— runbook Step 2 的驗證會直接卡住。*

**Fix / 修法** — add an `observability` `namespaceSelector` to that policy's
`from:` list. Platform owns the file, so this is a one-line change here.

*在該政策的 `from:` 加一條 `observability` 的 `namespaceSelector`。這個檔案屬
platform,改一行即可。*

### 1.2 Alloy's `app-pods` scrape is blocked by the app NetworkPolicies

*Alloy 的 `app-pods` scrape 會被 app 的 NetworkPolicy 擋掉*

`alloy/alloy.yaml` sets no `hostNetwork`, so its scrapes originate from a pod IP.
Every app policy's `allow-ingress` admits only `kube-system`, `10.42.0.1/32` (the
cni0 gateway) and `10.0.0.240/32`, on the app port alone. snoopy — the only app
that currently exports its own metrics, on `:8080` — therefore rejects Alloy.

*`alloy/alloy.yaml` 沒設 `hostNetwork`,scrape 來源是 pod IP。每個 app 政策的
`allow-ingress` 只放行 `kube-system`、`10.42.0.1/32`(cni0 閘道)與
`10.0.0.240/32`,且僅該 app 的埠。snoopy(目前唯一自己吐指標的 app,在 `:8080`)
因此會拒絕 Alloy。*

The failure is **indistinguishable from a missing annotation**: runbook Step 4b
would show `up{job="app-pods"} == 0` and look like the annotation never took.

*這個失敗**跟「annotation 沒生效」長得一模一樣**:Step 4b 會看到
`up{job="app-pods"} == 0`,像是 annotation 沒吃到。*

**Fix / 修法** — add an `observability` `namespaceSelector` on the metrics port to
each app policy that opts in. Do it per app, at the time that app opts in — not
pre-emptively for all four.

*對「有加入」的 app,在其政策上針對 metrics 埠加一條 `observability` 的
`namespaceSelector`。哪個 app 加入才改哪個,不要四個一次先開好。*

### 1.3 `node-exporter` runs against the direction Phase B just took

*`node-exporter` 與 Phase B 剛確立的方向相反*

`node-exporter.yaml` is `hostNetwork: true` + `hostPID: true` + `hostPath: /` —
precisely the three things PSA `restricted` forbids. `namespace.yaml` carries **no
PSA labels at all**, so nothing blocks it today, but leaving that implicit means
the fleet reads as "four app namespaces tightened, then a DaemonSet added that
mounts `/` and shares host PID".

*`node-exporter.yaml` 是 `hostNetwork: true` + `hostPID: true` + `hostPath: /`,
正是 PSA `restricted` 明文禁止的三項。`namespace.yaml` **完全沒有 PSA 標籤**,所以
今天不會被擋;但把它留成隱含的,整體看起來就是「把四個 app namespace 收緊之後,又加
了一個掛載 `/`、共享 host PID 的 DaemonSet」。*

**Fix / 修法** — label the namespace `pod-security.kubernetes.io/enforce:
privileged` **explicitly**, with the reason in a comment: a host-metrics exporter
cannot do its job without host namespaces, and it is the one workload for which
that is true. An explicit exemption is defensible; an unlabelled namespace is an
oversight.

*把 namespace **明確**標上 `pod-security.kubernetes.io/enforce: privileged`,並在註解
寫明理由:host 指標 exporter 沒有 host namespace 就無法工作,而它是唯一符合這個描述
的 workload。明寫的豁免站得住腳;沒標籤的 namespace 是疏漏。*

Secondary: the manifest passes no `--web.listen-address`, so under `hostNetwork`
it binds `0.0.0.0:9100`. Not internet-reachable (the OCI security list opens only
80/443/9000), but **Phase C's host firewall must account for 9100**.

*附帶一項:manifest 沒給 `--web.listen-address`,`hostNetwork` 下會綁
`0.0.0.0:9100`。對外不可達(OCI security list 只開 80/443/9000),但 **Phase C 的
host firewall 要把 9100 一起算進去**。*

### 1.4 Stale — image prune is already done on `main`

*已過時 —— image prune 在 `main` 上已經做完*

`runbook.md`'s closing section B says "Optional: make it a weekly systemd timer".
`main` already has `node/prune-images.{sh,service,timer}` + `install-prune-timer.sh`,
running **daily**, with `PODMAN_KEEP` retention for the podman store
(`14751be`, `decb70c`, `ed47632`, `63e1036`). Rewrite that section to point at
the existing timer.

*`runbook.md` 結尾 B 節寫「選配:做成 weekly timer」。`main` 上已經有
`node/prune-images.{sh,service,timer}` 加 `install-prune-timer.sh`,**每日**執行,
podman store 另有 `PODMAN_KEEP` 保留策略。該節應改為指向既有的 timer。*

Section A (containerd log rotation) is **still genuinely open** — nothing on
`main` sets `container-log-max-size` / `container-log-max-files`. Keep it, and
note it needs a k3s restart.

*A 節(containerd log 輪替)**確實還沒做** —— `main` 上沒有任何地方設
`container-log-max-size` / `container-log-max-files`。保留該節,並註明它需要重啟 k3s。*

### 1.5 Stale — the disk alert watches one filesystem, but there are now three

*已過時 —— 磁碟告警只看一個檔案系統,但現在有三個*

`runbook.md` Step 5 suggests `node_filesystem_avail_bytes{mountpoint="/"}`. The
storage work on `main` (`1d65acb`, `a6b580b`) split `/var/lib/rancher` and
`/var/lib/containers` onto their own volumes, so a full `/var/lib/containers`
would **not show up in `/` at all** — which is the exact failure that work was
done to make visible.

*Step 5 建議用 `node_filesystem_avail_bytes{mountpoint="/"}`。`main` 上的 storage
改動已把 `/var/lib/rancher` 與 `/var/lib/containers` 拆成獨立卷,所以
`/var/lib/containers` 塞爆**在 `/` 的指標上完全看不出來** —— 而那正是當初做那次改動
想讓它可見的失敗模式。*

**Fix / 修法** — `mountpoint=~"/|/var/lib/rancher|/var/lib/containers"`. The two
store paths in `scripts/image-metrics.sh` are still correct; the split kept the
same paths, they are just separate mounts now.

*改成 `mountpoint=~"/|/var/lib/rancher|/var/lib/containers"`。
`scripts/image-metrics.sh` 裡那兩個 store 路徑仍然正確 —— 拆卷後路徑沒變,只是各自成
了獨立掛載點。*

---

## 2. Open decision — where the metrics backend lives

*未定決策 —— 指標後端放在哪*

The stack as written remote_writes to **Grafana Cloud free tier**. The
alternative is a **self-hosted Prometheus + Grafana on the second OCI account**
(`lansoulot`, us-sanjose-1). This section records what was measured so the
decision can be made later without re-investigating.

*目前的 stack 是 remote_write 到 **Grafana Cloud 免費層**。替代方案是在**第二個 OCI
帳號**(`lansoulot`,us-sanjose-1)**自架 Prometheus + Grafana**。本節記錄已量測到的
事實,之後可以不必重查就下決定。*

### 2.1 What is actually running in the `lansoulot` tenancy — measured 2026-07-29

*`lansoulot` tenancy 的真實狀態 —— 2026-07-29 實測*

Verified with `oci --profile lansoulot`, **not** from Terraform. The two disagree,
and Terraform is wrong.

*用 `oci --profile lansoulot` 查證,**不是**看 Terraform。兩者不一致,而且 Terraform
是錯的那邊。*

| Fact | Value |
|---|---|
| Instance | `lh-i1`, **RUNNING** since 2025-08-26 |
| Shape | **`VM.Standard.E2.1.Micro` — 1 OCPU / 1.0 GB RAM**, x86 (AMD E2) |
| OS | Oracle Linux **8.10** (`Oracle-Linux-8.10-2025.07.31-0`) |
| Boot volume | 47 GB, 10 VPU/GB |
| Address | public `192.9.247.165`, private `10.0.0.129` |
| Compartment | **tenancy root** — *not* the compartment in `terraform.tfvars` |
| A1 (Ampere) instances | **none — the Always Free 4 OCPU / 24 GB ARM allowance is entirely unused** |
| Block volumes | none |

**Terraform in `lansoulot/` has never created an instance.** Its state
(serial 14, last written 2026-07-14) contains a VCN, public subnet
(`10.0.1.0/24`), internet gateway, route table and security list — and **no
`oci_core_instance`**, although the module defines one with no `count`. Nothing
uses that network. `lh-i1` predates the stack and sits outside it, on a different
subnet, in a different compartment.

***`lansoulot/` 的 Terraform 從來沒建過 instance。** state(serial 14,最後寫入
2026-07-14)裡有 VCN、public subnet(`10.0.1.0/24`)、IGW、route table、security
list —— **沒有 `oci_core_instance`**,儘管 module 定義了一個且沒有 `count`。那組網路
沒有任何東西在用。`lh-i1` 早於這個 stack、在它之外,不同 subnet、不同 compartment。*

Two traps worth writing down, because both cost time once already:

*兩個值得寫下來的坑,都已經各花過一次時間:*

- `terraform.tfvars` says `VM.Standard.A1.Flex`, **1 OCPU / 6 GB**. That is an
  *intent that was never applied* — tfvars was edited (07-15 23:42) after the last
  apply (07-14 18:29). Sizing judgements must use the measured 1 GB, not this.
  *`terraform.tfvars` 寫的是 `A1.Flex` 1 OCPU / 6 GB,那是**從未 apply 的意圖** ——
  tfvars 的修改時間晚於最後一次 apply。評估容量要用實測的 1 GB,不是這個值。*
- The tenancy contains a **child compartment literally named `root`**, whose OCID
  is the one in `terraform.tfvars`. It is empty. `lh-i1` is in the *real* tenancy
  root. `oci compute instance list` against the tfvars compartment returns
  nothing, which reads as "no instances" and is not.
  *tenancy 裡有一個**名字就叫 `root` 的子 compartment**,其 OCID 正是
  `terraform.tfvars` 裡那個,而且是空的。`lh-i1` 在**真正的** tenancy root。對 tfvars
  的 compartment 查 instance 會得到空結果,看起來像「沒有機器」,但不是。*

### 2.2 Does the backend fit on `lh-i1`? No.

*後端塞得進 `lh-i1` 嗎?不行。*

Sizing estimates below are **rules of thumb, not measurements on this fleet**.
Series count: cAdvisor 3–8k + kubelet 2–3k + node-exporter ~800 + postgres-exporter
~300 → **8–15k active series**.

*以下是**經驗估算,不是對本機隊的實測**。series 數:cAdvisor 3–8k + kubelet 2–3k +
node-exporter 約 800 + postgres-exporter 約 300 → **8–15k active series**。*

| Component | Estimate |
|---|---|
| Prometheus RSS | 400–800 MB (≈2–4 KB per active series, plus overhead) |
| Grafana RSS | 150–250 MB |
| Oracle Linux 8 itself | 300–400 MB |
| **Total** | **1.2–1.5 GB** |
| TSDB disk | 15k series @ 30s ≈ 500 samples/s, ~1.5–2 bytes/sample → ~85 MB/day → 30 d ≈ 2.5 GB |

**1.2–1.5 GB does not fit in 1.0 GB.** It would be OOM-killed under query load.
A lighter substitution — VictoriaMetrics `vmsingle` instead of Prometheus — lands
around 600–800 MB total: technically inside 1 GB, with **no headroom**, where one
wide `rate()` range query risks the OOM killer. A monitoring backend that dies
under load is worse than none, because it fails exactly when it is being read.

***1.2–1.5 GB 塞不進 1.0 GB**,查詢負載一來就會被 OOM killer 收掉。換更輕的組合
(VictoriaMetrics `vmsingle` 取代 Prometheus)約 600–800 MB:技術上進得去 1 GB,但
**零餘裕**,一條寬範圍 `rate()` 就可能引爆 OOM。監控後端在負載下自己死掉比沒有更糟,
因為它恰好死在有人要看它的時候。*

x86-vs-ARM is not a constraint (Prometheus, Grafana and VictoriaMetrics all ship
amd64 builds). The constraint is purely the 1 GB.

*x86 與 ARM 不是限制(三者都有 amd64 build),限制純粹是 1 GB。*

Also unresolved: **what `lh-i1` is currently doing is unknown.** It has been
running since 2025-08-26. Do not plan to repurpose it without checking.

*另有未解項:**`lh-i1` 目前在跑什麼未知**,它從 2025-08-26 就一直在跑。沒確認前不要
計畫拿它來改用途。*

### 2.3 The unused ARM allowance is the real option

*沒動用的 ARM 配額才是真正的選項*

> **Corrected 2026-08-02 — the allowance in this section was stale.** Oracle
> **halved the Always Free A1 allowance on 2026-06-15** without announcing it
> (the docs were silently updated): 4 OCPU / 24 GB → **2 OCPU / 12 GB**, i.e.
> 3,000 → 1,500 OCPU-hours and 18,000 → 9,000 GB-hours per month. The paragraph
> below originally said 4 / 24 was available; it is **2 / 12**. That happens to
> land on exactly the size this section recommends, so the recommendation itself
> survives — but there is now **no spare headroom above it**, and `lansoulot`
> would be at 100% of its A1 bucket.
>
> *2026-08-02 更正 —— 本節原本的配額數字已過時。Oracle 於 **2026-06-15 無預警把
> Always Free A1 配額砍半**(只默默改了文件):4 OCPU / 24 GB → **2 OCPU / 12 GB**,
> 即每月 3,000 → 1,500 OCPU-hr、18,000 → 9,000 GB-hr。下面原文寫「4 / 24 可用」,
> 實際是 **2 / 12**。剛好等於本節建議的規格,所以建議本身仍然成立 —— 但**之上不再
> 有餘裕**,`lansoulot` 會用滿它 100% 的 A1 額度。*

The `lansoulot` tenancy has **no A1 instance**, so its full Always Free Ampere
allowance — **2 OCPU / 12 GB** (see the correction above) — is available. Running
`terraform apply` in `lansoulot/` creates one; bumping
`shape_ocpus`/`shape_memory_gbs` to **2 / 12** costs nothing and removes the
single-core risk (on 1 core, TSDB compaction plus a wide range query saturates it
for seconds — dashboards get sluggish, nothing dies).

*`lansoulot` tenancy **一台 A1 都沒有**,所以整份 Always Free Ampere 配額
(**2 OCPU / 12 GB**,見上方更正)可用。在 `lansoulot/` 跑 `terraform apply` 就能建
一台;把 `shape_ocpus`/`shape_memory_gbs` 提到 **2 / 12** 不花錢,並消掉單核風險
(單核上 TSDB compaction 疊一條寬範圍查詢會被吃滿數秒 —— dashboard 卡頓,但不會掛)。*

Three things to expect / 三個要預期的事:

- A1 free-tier capacity in `us-sanjose-1` is frequently exhausted
  (`Out of host capacity`). Expect retries, or another AD.
  *`us-sanjose-1` 的 A1 free tier 經常沒容量,要預期重試或換 AD。*
- `apply` puts the instance in the **child compartment** and the stack's own
  `10.0.1.0/24` VCN — a different network from `lh-i1`.
  *`apply` 會把 instance 建在**子 compartment** 與 stack 自己的 `10.0.1.0/24` VCN,
  跟 `lh-i1` 不同網段。*
- The module's security list opens **only 22/tcp from `0.0.0.0/0`**, egress all.
  A remote-write receiver needs 443 added — and SSH should be narrowed while
  there.
  *module 的 security list **只開 22/tcp 給 `0.0.0.0/0`**,egress 全開。
  remote-write receiver 要加 443,順手把 SSH 收窄。*

### 2.4 If self-hosted: push, never pull

*若自架:一定是 push,不能是 pull*

The two nodes are in **different tenancies and different regions** (louis2 in
`louis4oci`/eu-frankfurt-1; this one in `lansoulot`/us-sanjose-1). No VCN
peering — traffic crosses the public internet, ~150 ms RTT.

*兩台在**不同 tenancy、不同 region**(louis2 在 `louis4oci`/eu-frankfurt-1,這台在
`lansoulot`/us-sanjose-1)。沒有 VCN peering,流量走公網,RTT 約 150 ms。*

A Prometheus on the second box **scraping** louis2 would require exposing kubelet
`:10250`, node-exporter `:9100` and postgres-exporter `:9187` to the internet —
which directly undoes audit finding #8 and the entire B-3 NetworkPolicy pass.

*讓第二台的 Prometheus **scrape** louis2,就得把 kubelet `:10250`、node-exporter
`:9100`、postgres-exporter `:9187` 曝到公網 —— 這會直接推翻稽核 finding #8 與整個
B-3 NetworkPolicy。*

Instead keep Alloy on louis2 and repoint `remote_write` from Grafana Cloud to the
second box: one outbound TLS connection, **zero new inbound ports on louis2**, and
Alloy's WAL absorbs the latency and any outage. Egress is ~1 KB/s ≈ 2.5 GB/month
against 10 TB/month free — negligible.

*正確做法是 Alloy 留在 louis2,把 `remote_write` 從 Grafana Cloud 改指向第二台:一條
對外 TLS 連線、**louis2 零新增 inbound 埠**,而 Alloy 的 WAL 會吸收延遲與斷線。
egress 約 1 KB/s ≈ 2.5 GB/月,對比免費 10 TB/月可忽略。*

Note what **cannot** move regardless: node-exporter reads louis2's `/proc` and
`/sys`; per-app CPU/RAM comes from louis2's kubelet/cAdvisor; postgres-exporter
must reach Postgres in-cluster. The ~200 MB on louis2 stays either way. A second
box replaces **Grafana Cloud's storage and query layer only**, not the collectors.

*另外要註明**無論如何都搬不走的**:node-exporter 讀的是 louis2 的 `/proc`、`/sys`;
per-app CPU/RAM 來自 louis2 的 kubelet/cAdvisor;postgres-exporter 必須在叢集內連
Postgres。louis2 上那約 200 MB 兩種方案都留著。第二台取代的只有 **Grafana Cloud 的
儲存與查詢層**,不是採集器。*

### 2.5 What self-hosting costs that Grafana Cloud gives free

*自架要自己補、而 Grafana Cloud 免費給的東西*

A DNS name for the second box (a new A record to the San Jose IP — **the louis2
wildcard cert cannot be reused**, a different host needs its own Let's Encrypt),
TLS termination, basic-auth on the remote-write receiver, and that box's own
patching and backups. And: **nothing monitors the monitor.** This is the honest
downside; Grafana Cloud needs none of it.

*第二台自己的 DNS 名稱(新 A record 指到 San Jose IP —— **louis2 的 wildcard 憑證不能
沿用**,不同主機要自己的 Let's Encrypt)、TLS 終結、remote-write 端點的 basic-auth,
以及那台自己的 patch 與備份。還有:**沒有人監控監控者。** 這是自架最誠實的缺點,
Grafana Cloud 完全不需要這些。*

### 2.6 Decision criterion

*決策判準*

The argument **for** self-hosting is not cost and not resources — it is that the
estimated **8–15k active series already reaches Grafana Cloud's free-tier 10k
ceiling**, so `README.md`'s "10k is enough for this fleet" is optimistic, and the
free tier's 14-day retention is short for capacity trends.

*自架的理由不是成本也不是資源,而是估算的 **8–15k active series 已經頂到 Grafana
Cloud 免費層 10k 的天花板**,所以 `README.md` 寫「10k 對這個機隊夠用」偏樂觀;而且免
費層 14 天保留期對看容量趨勢偏短。*

The cheapest path to deciding: **ship the Grafana Cloud version first, read the
actual active-series count off it, then decide.** That converts the one number
this decision hinges on from an estimate into a measurement, and costs nothing —
switching backend later is a change to one `remote_write` block.

*最省的決策路徑:**先把 Grafana Cloud 版上線,從它讀出真實的 active series 數,再
決定。** 這樣就把整個決策所依賴的那一個數字從估算變成實測,而且不花成本 —— 之後換後
端只是改一個 `remote_write` 區塊。*

---

## 3. The two free Frankfurt micros — measured 2026-08-02

*Frankfurt 那兩顆免費 micro —— 2026-08-02 實測*

§2 compared exactly two homes for the backend: Grafana Cloud, and a box in the
**second tenancy** (`lansoulot`, us-sanjose-1). It missed a third machine that is
already paid for. This section records it, and — importantly — concludes that it
**does not** settle §2. It answers a different question that §2 never asked.

*§2 只比較了兩個去處:Grafana Cloud,以及**第二個 tenancy**(`lansoulot`,
us-sanjose-1)的機器。它漏掉了第三台早就付過錢的機器。本節記錄它,而且 —— 重點是 ——
結論是它**解決不了** §2,它回答的是 §2 從未問過的另一個問題。*

### 3.1 What is available / 有什麼可用

Verified with `oci --profile louis4oci`, in **louis2's own tenancy** — not the
second account:

*用 `oci --profile louis4oci` 在 **louis2 自己的 tenancy** 查證,不是第二個帳號:*

| Fact | Value |
|---|---|
| `standard-e2-micro-core-count` | **2 in `hJzo:EU-FRANKFURT-1-AD-1`**, 0 in AD-2 and AD-3 |
| E2 instances currently running | **none — both free cores are unused** |
| Shape if launched | `VM.Standard.E2.1.Micro` — 1 OCPU / **1.0 GB**, x86_64 (AMD), 0.48 Gbps |
| Compute cost | **$0 — Always Free, and a _separate_ allowance from the A1 bucket** |
| Idle reclamation | **does not apply** — that only reclaims Always Free instances in free-tier-only tenancies; this one is PAYG |
| Placement vs louis2 | micros in **AD-1**, louis2 in **AD-3**, same region, same VCN reachable on private IP |

Two consequences worth stating explicitly. First, **this does not touch the A1
free bucket** — the 1,500 OCPU-hours that louis2 alone already consumes at ~99%
are untouched by an E2 micro, so nothing here interacts with the scale-out cost
arithmetic in `docs/scale-out-topology.html`. Second, **AD-1 vs AD-3 is a
feature, not a wrinkle**: a watchdog in a different availability domain from the
thing it watches is a better watchdog, and intra-region VCN traffic is not
metered.

*兩個要明講的推論。第一,**這不動用 A1 免費額度** —— louis2 一台就已經吃掉約 99% 的
1,500 OCPU-hr,E2 micro 完全不碰它,所以本節與 `docs/scale-out-topology.html` 裡的擴充
成本算式互不相干。第二,**AD-1 對 AD-3 是優點不是麻煩**:監控者跟被監控者在不同
availability domain 才是好的監控,而且同 region 的 VCN 流量不計費。*

### 3.2 The architecture wall — it can only run what you do not build

*架構這道牆 —— 它只能跑「你不用自己 build 的東西」*

The micro is **x86_64**; louis2 is **arm64**. The whole deploy pipeline builds
with `podman build` on louis2 and imports into containerd, so **every image this
platform produces is arm64 and cannot run on the micro.** Conversely, third-party
software pulled from docker.io as a multi-arch image has no problem at all.

*micro 是 **x86_64**,louis2 是 **arm64**。整條部署管線都在 louis2 上 `podman build`
再匯入 containerd,所以**這個平台產出的每一個 image 都是 arm64,在 micro 上一個都跑不
起來**。反過來說,從 docker.io 拉的第三方多架構 image 完全沒問題。*

That single fact is the filter: **the micro is only ever a host for upstream
software.** Note this is *not* the constraint §2.2 hit — that one was purely RAM,
because Prometheus/Grafana/VictoriaMetrics all ship amd64 builds. Here both walls
apply at once.

*這一條就是篩子:**micro 永遠只能當上游軟體的宿主**。注意這**不是** §2.2 撞到的那道
牆 —— 那道純粹是 RAM,因為 Prometheus/Grafana/VictoriaMetrics 都有 amd64 build。這裡
是兩道牆同時成立。*

### 3.3 It is not a metrics backend — §2.2's arithmetic applies verbatim

*它不是指標後端 —— §2.2 的算式原封不動適用*

1.0 GB here is the same 1.0 GB as `lh-i1`. §2.2's conclusion stands unchanged:
Prometheus + Grafana is 1.2–1.5 GB and does not fit; `vmsingle` lands at
600–800 MB, which is inside 1 GB with **zero headroom**, where one wide `rate()`
range query risks the OOM killer. **§2 is not resolved by this section.**

*這裡的 1.0 GB 跟 `lh-i1` 的 1.0 GB 是同一回事。§2.2 的結論完全不變:
Prometheus + Grafana 是 1.2–1.5 GB,塞不下;`vmsingle` 約 600–800 MB,技術上進得去
1 GB 但**零餘裕**,一條寬範圍 `rate()` 就可能引爆 OOM。**§2 不會被本節解決。***

What *does* fit is a workload two orders of magnitude smaller. The fleet's
estimated **8–15k active series** is what breaks 1 GB; blackbox-probing six
public endpoints at 60s produces roughly **90 series**. Different problem, and
therefore a different answer.

*塞得下的是小兩個數量級的工作負載。壓垮 1 GB 的是機隊估算的 **8–15k active
series**;用 blackbox 以 60 秒探測六個公開端點大約產生 **90 條 series**。不同的問題,
所以有不同的答案。*

| Component (all upstream amd64 images) | RSS |
|---|---|
| Oracle Linux 9 + `oracle-cloud-agent` | 300–400 MB |
| `blackbox_exporter` | 15–25 MB |
| `alertmanager` | 30–50 MB |
| `vmsingle` — probe series only, 7 d retention | 80–120 MB |
| **Total** | **~450–600 MB** |

That leaves 400+ MB of headroom on a 1 GB box, and a 2 GB swapfile on the
already-paid boot volume covers the tail. Add Grafana (150–250 MB) and the
headroom is gone — **use VMUI instead**, which is built into `vmsingle`, speaks
PromQL, and costs nothing extra.

*在 1 GB 的機器上還剩 400+ MB 餘裕,再於已經付過錢的開機碟上開 2 GB swapfile 就能吸收
尾巴。加上 Grafana(150–250 MB)餘裕就沒了 —— **改用 VMUI**,它內建於 `vmsingle`、
會講 PromQL、不額外花錢。*

### 3.4 Role A — off-node backup target. Unconditional, and overdue.

*角色 A —— 異機備份落地點。無條件該做,而且早該做了。*

**Measured 2026-08-02: this fleet has no Postgres backup of any kind.**
`systemctl list-timers` on louis2 lists only `prune-images.timer` plus OS timers;
there is no user crontab; and the only backup anywhere in the repo is the
**one-off, manual** OCI boot-volume backup in `docs/runbook-storage.md` — a
document which itself states that restoring it is *the only recovery path there
is*.

***2026-08-02 實測:這個機隊沒有任何形式的 Postgres 備份。** louis2 上
`systemctl list-timers` 只有 `prune-images.timer` 與 OS 自帶的 timer;沒有 user
crontab;整個 repo 裡唯一的備份是 `docs/runbook-storage.md` 裡那次**一次性、手動**的
OCI 開機卷備份 —— 而那份文件自己就寫著,還原它是**僅有的復原路徑**。*

The data this protects is small enough that the cost argument disappears
entirely. Live sizes, same measurement:

*它要保護的資料小到成本論點完全消失。同一次實測的實際大小:*

| Database | Size |
|---|---|
| `gelp` | 18 MB |
| `transigen` | 8.6 MB |
| `snoopy_home` | 7.9 MB |
| `postgres` | 7.5 MB |
| **Total** | **~42 MB** |

A compressed `pg_dumpall` of that is single-digit MB. The micro's 47 GB boot
volume holds **years** of daily dumps without ever approaching full, and the PVC
it is protecting is a 1Gi `local-path` volume — i.e. a directory on louis2's own
disk, with no replication of any kind behind it.

*壓縮後的 `pg_dumpall` 是個位數 MB。micro 那顆 47 GB 開機碟可以放**好幾年**的每日
dump 都還離滿很遠;而它保護的 PVC 是 1Gi 的 `local-path` 卷 —— 也就是 louis2 自己磁碟
上的一個目錄,背後沒有任何複本。*

**Direction: push from louis2, exactly as §2.4 requires.** louis2 runs the dump
and ships it out; the micro never reaches into louis2. Two design points that are
easy to get backwards:

***方向:從 louis2 推出去,與 §2.4 的規則一致。** louis2 自己做 dump 再送出去,micro
永遠不主動連進 louis2。兩個很容易做反的設計點:*

- **Never let the backup box hold a key into prod.** A pull design gives a
  compromised backup host a shell on louis2. Push inverts that: the micro's
  security list admits 22/tcp **from louis2's private IP only**, and the
  `authorized_keys` entry is a forced command (`restrict,command="…"`), not a
  general login.
  ***絕不讓備份機持有進入 prod 的金鑰。** pull 設計等於讓被攻陷的備份主機拿到
  louis2 的 shell。push 把方向反過來:micro 的 security list **只放行 louis2 私有 IP**
  的 22/tcp,而 `authorized_keys` 用 forced command(`restrict,command="…"`),不是一般
  登入。*
- **Append-only, or it is not a backup.** If louis2 can delete what it wrote, one
  compromise takes the history with it. `restic`/`borg` in append-only mode is
  the standard answer; a plain `scp` into a writable directory is not.
  ***要 append-only,否則那不算備份。** 如果 louis2 能刪掉自己寫過的東西,一次入侵就
  連歷史一起帶走。`restic`/`borg` 的 append-only 模式是標準答案;`scp` 進一個可寫目錄
  不是。*

This role is **independent of the §2 decision** — it is worth doing whether the
metrics backend ends up on Grafana Cloud, in San Jose, or nowhere.

*這個角色**與 §2 的決策無關** —— 不論指標後端最後落在 Grafana Cloud、San Jose 還是
哪裡都不去,它都值得做。*

### 3.5 Role B — external watchdog. Conditional on §2.

*角色 B —— 外部看門狗。取決於 §2。*

A blackbox prober tests something no in-cluster collector can: **DNS → Cloudflare
→ Traefik → certificate → app, end to end, from outside the failure domain.**
Whether that is worth building depends entirely on how §2 resolves:

*blackbox 探測驗證的是叢集內採集器做不到的事:**DNS → Cloudflare → Traefik → 憑證 →
app,端到端,而且是從故障域外面看**。值不值得做完全取決於 §2 怎麼收:*

- **If Grafana Cloud wins §2 — largely redundant, do not build it.** The free
  tier includes Synthetic Monitoring and alerting, and an `absent()`/staleness
  alert on `remote_write` already detects "louis2 stopped talking". The micro's
  marginal contribution is a second opinion, which is not worth a second box to
  operate.
  ***如果 §2 收在 Grafana Cloud —— 大致重複,不要做。** 免費層已含 Synthetic
  Monitoring 與告警,而且對 `remote_write` 設 `absent()`/staleness 告警本來就能偵測
  「louis2 不說話了」。micro 只多提供一份第二意見,不值得多養一台機器。*
- **If self-hosting wins §2 — build it, because it answers §2.5's own objection.**
  §2.5 records the honest downside of self-hosting as "**nothing monitors the
  monitor**". This is what monitors the monitor, and it sits in a third failure
  domain: a different AD from louis2, and a different region from a San Jose
  backend.
  ***如果 §2 收在自架 —— 要做,因為它正好回答了 §2.5 自己提出的反對意見。** §2.5 誠實
  地把自架的缺點記為「**沒有人監控監控者**」。這台就是監控監控者的東西,而且落在第三個
  故障域:與 louis2 不同 AD,與 San Jose 的後端不同 region。*

Either way, **Alertmanager belongs here rather than on louis2**, for the same
reason: an alert path that dies with the thing it reports on is not an alert
path.

*無論哪一種,**Alertmanager 都該放這裡而不是 louis2**,理由相同:跟被通報對象一起死掉
的通報路徑,不算通報路徑。*

### 3.6 What it must not become / 不能拿它做什麼

- **Not a k3s agent.** kubelet + containerd + flannel is ~300 MB — a third of the
  box — bought in exchange for schedulability it has no use for. It should run
  **podman + Quadlet**, which is the same conclusion the counterpoint section of
  `docs/scale-out-topology.html` reaches for single-node workloads.
  ***不要加進 k3s 當 agent。** kubelet + containerd + flannel 約 300 MB,佔掉整台的
  三分之一,換到的只有它根本用不到的「可被排程」。它應該跑 **podman + Quadlet** ——
  這跟 `docs/scale-out-topology.html` 那節 counterpoint 對單節點負載的結論一致。*
- **Not Postgres, primary or replica.** `PGDATA` is architecture-specific, so
  this is a `pg_dump`/restore, not a file copy; 1 GB is below what the current
  instance is already tuned for; and every app query becomes a cross-node network
  hop instead of in-cluster.
  ***不要放 Postgres,主庫或副本都不行。** `PGDATA` 與架構相關,所以那是
  `pg_dump`/還原而不是搬檔;1 GB 低於現有實例已經調好的用量;而且每一筆查詢都會從叢集
  內變成跨機網路往返。*
- **Not the `:9000` webhook listener.** Its entire job is to run `podman build`
  and `kubectl rollout` **on louis2**. Moving it adds an SSH hop and a key for
  zero benefit.
  ***不要搬 `:9000` webhook。** 它的工作就是在 **louis2 上**跑 `podman build` 與
  `kubectl rollout`。搬走只是多一跳 SSH 加一把金鑰,毫無好處。*
- **Not any of the four apps.** Their images are arm64; and `next build` needs
  ~2 GB, so the micro could not even build a replacement.
  ***四個 app 一個都不要搬。** image 是 arm64;而 `next build` 需要約 2 GB,micro 連
  重建一份都建不動。*

### 3.7 Cost — compute $0, disk $1.20–2.00/month

*成本 —— compute $0,磁碟每月 $1.20–2.00*

Compute is free and does not consume the A1 bucket (§3.1). **The disk is not
free**, and no amount of stopping the instance changes that — block storage bills
whether the instance runs or not.

*compute 免費且不吃 A1 額度(§3.1)。**磁碟不免費**,而且停機完全無濟於事 —— block
storage 不管開機關機都照算。*

47 GB is the floor: the OL9 image is 46.6 GB, measured identically on
`capacity-probe-20260801` and on `lh-i1`. The Always Free 200 GB is **fully
consumed by louis2's own 200 GB boot volume**, so a new volume bills from the
first byte — confirmed live on 2026-08-02 by the probe's own invoice lines
(`Block Volume - Storage` + `Block Volume - Performance Units`, ≈ $0.043/day for
47 GB at VPU 10).

*47 GB 是地板:OL9 image 本身 46.6 GB,在 `capacity-probe-20260801` 與 `lh-i1` 上量到
的數字相同。Always Free 的 200 GB **已被 louis2 自己的 200 GB 開機碟吃滿**,所以新碟從
第一個 byte 就全額計費 —— 2026-08-02 由探針自己的帳單行實證(`Block Volume - Storage`
加 `Block Volume - Performance Units`,47 GB VPU 10 約 $0.043/日)。*

| VPU tier | $/GB-month | 47 GB |
|---|---|---|
| 10 — Balanced (the default) | $0.0425 | **$2.00** |
| 0 — Lower Cost | $0.0255 | **$1.20** |

**Choose VPU 0.** Its 2 IOPS/GB baseline is ample for ~90 probe series and a
nightly single-digit-MB dump. It would be the wrong choice for a database or an
etcd member; it is the right one here, and it saves $9.60/year.

***選 VPU 0。** 它每 GB 2 IOPS 的基準對約 90 條 probe series 與每晚個位數 MB 的 dump
綽綽有餘。資料庫或 etcd 成員選它是錯的,這裡選它是對的,一年省 $9.60。*

**Footnote on the stranded allowance / 關於被鎖住的那份額度。** louis2 uses
**19 GB of its 200 GB** boot volume (measured: `/` 12 GB of 30 GB,
`/var/lib/rancher` 6.6 GB of 80 GB, and ~90 GB never partitioned at all).
Rebuilding louis2 on a 100 GB volume would return 100 GB of free allowance and
make the micro's disk cost $0. That is a full node migration to save $1.20/month,
so it is **not a recommendation** — it is recorded so that *if* louis2 is ever
rebuilt for some other reason, the smaller boot volume is not forgotten.

*louis2 的 200 GB 開機碟只用了 **19 GB**(實測:`/` 是 30 GB 用 12 GB、
`/var/lib/rancher` 是 80 GB 用 6.6 GB,另有約 90 GB 從未建立分割區)。把 louis2 重建成
100 GB 開機碟可以還回 100 GB 免費額度,micro 的碟就變成 $0。那是為了每月 $1.20 做一次
完整節點遷移,所以**不是建議** —— 記在這裡只是為了:萬一 louis2 哪天因為別的理由重建,
別忘了順手把開機碟改小。*

### 3.8 Recommendation / 建議

**Do Role A now; defer Role B until §2 is decided.** Role A closes a gap that
exists today (no backup at all), costs $1.20/month, has no dependency on any open
question, and needs one E2 micro. Role B is cheap to add to the same box later —
it is two more containers — and should wait for §2 precisely because its value is
the inverse of Grafana Cloud's.

***先做角色 A;角色 B 等 §2 決定後再說。** 角色 A 補的是今天就存在的缺口(完全沒有備
份),每月 $1.20,不相依於任何未決問題,只需要一顆 E2 micro。角色 B 之後往同一台機器上
加很便宜 —— 就是多兩個 container —— 而且它該等 §2,正因為它的價值與 Grafana Cloud 的
價值恰好互為反面。*

The second free micro core stays unused for now. Its plausible future use is a
bastion so louis2's `22/tcp` can be closed to the internet (Phase C), but that
costs another $1.20/month and adds a failure mode on the operator's own access
path — decide it with Phase C, not here.

*第二顆免費 micro 核心暫時不用。它可能的未來用途是當 bastion,讓 louis2 的 `22/tcp`
可以對網際網路關閉(Phase C),但那要再花每月 $1.20,而且在操作者自己的存取路徑上多一
個故障點 —— 那個跟 Phase C 一起決定,不在這裡決定。*

---

## 4. Portability — what happens if this moves to another instance

*可移植性 —— 如果這些東西搬到另一台 instance 會怎樣*

Asked 2026-08-02: *could the observability pods/containers end up on a different
OCI instance?* Answering it surfaced one real bug (4.2) and one landmine that
belongs to Phase B rather than to this stack (4.4). Both are recorded here.

*2026-08-02 提出的問題:observability 的 pod/container 有沒有可能跑到另一台 OCI
instance 上?回答這個問題翻出了一個真的 bug(4.2),以及一個屬於 Phase B 而非本
stack 的地雷(4.4)。兩個都記在這裡。*

### 4.1 Two different questions, one word / 同一個詞,兩個問題

"Moving to another instance" means two incompatible things, and the answers are
opposite:

*「搬到另一台 instance」有兩種互不相容的意思,答案完全相反:*

| | **A. Another node in THIS k3s cluster** | **B. A separate instance / cluster** |
|---|---|---|
| How | new node runs `k3s agent`, joins louis2 | own k3s (or none), own tenancy/region |
| Scheduler moves pods there | **yes, automatically** | never — different cluster |
| What this section is mostly about | 4.2, 4.3, 4.4 | 4.5 |

*A 是「加一個節點進**同一個** k3s 叢集」,排程器會自動把 pod 放過去;B 是「另一個獨立
的 instance/叢集」,兩邊的排程器互不相干,pod 不會「移動」過去,只會是「再裝一份」。*

### 4.2 The bug scenario A would have caused / 情境 A 原本會造成的 bug

**Alloy was a DaemonSet. It must not be.** Every scrape in `alloy.yaml` gets its
targets from the API server — `discovery.kubernetes "nodes"` returns *all* nodes,
`discovery.kubernetes "pods"` returns *all* pods. One Alloy per node therefore
means each node's Alloy scrapes **every** node's kubelet/cAdvisor/node-exporter,
the single postgres-exporter, and every annotated app pod.

*原本 Alloy 是 DaemonSet,**不該是**。`alloy.yaml` 裡每個 scrape 的目標都是向 API
server 查詢得來的**全叢集**清單,所以每個節點一份 Alloy,就等於每一份都去抓「所有」節
點與「所有」pod。*

On one node this is invisible. On two nodes every series is produced twice with
identical labels: duplicate-sample rejections at `remote_write`, and a doubled
active-series count against the 10k free-tier ceiling — i.e. the failure would
show up as *"the free tier is suddenly not enough"*, which is exactly the number
§2.6 says to trust when choosing the backend. It would have corrupted the
measurement the whole backend decision rests on.

*單節點時完全看不出來;兩個節點時,每條 series 會用相同標籤被送出兩次 ——
`remote_write` 判為重複樣本,active series 直接翻倍撞上 10k 免費上限。也就是說,故障
會表現為「免費層突然不夠用」,而那正是 §2.6 說要拿來決定 backend 的那個數字。等於會污
染整個 backend 決策所依賴的量測。*

**Fixed 2026-08-02** — Alloy is now a `Deployment` with `replicas: 1` and
`strategy: Recreate`. It holds no host state, so one cluster-wide collector is
both correct and freely reschedulable onto any node.

***2026-08-02 已修正** —— Alloy 改為 `replicas: 1` 的 `Deployment`,`strategy:
Recreate`。它不持有任何 host 狀態,所以單一採集器既正確,也可以自由被排到任何節點。*

node-exporter stays a DaemonSet, correctly: it reads the `/proc` of the node it
runs on, so it must be **on** every node and cannot be a singleton. That is the
dividing line — *does this workload read the machine it sits on?*

*node-exporter 維持 DaemonSet 是對的:它讀的是自己所在節點的 `/proc`,必須**在**每個
節點上,不能是單例。這就是分界線 —— **這個 workload 讀不讀它所在的那台機器?***

### 4.3 What is already portable / 已經可移植的部分

- **No PersistentVolumeClaims anywhere in this stack.** The TSDB lives in Grafana
  Cloud; Alloy's WAL is an `emptyDir` holding only unsent samples. Rescheduling
  costs at most that buffer — there is no volume to migrate and no local-path PVC
  pinning a pod to a node.
- **postgres-exporter reaches Postgres by Service DNS**
  (`postgres.data.svc.cluster.local`), not by node IP, and the policy that admits
  it (§1.1) is a `namespaceSelector`, not an `ipBlock`. Pod identity, not
  location — so it works from any node without edits.
- **Grafana Cloud is reached by outbound HTTPS only.** No inbound port, no DNS
  record, no certificate. This is the same push-not-pull property §2.4 argued
  for, and it is what makes any of this movable at all.

*本 stack 沒有任何 PVC(TSDB 在 Grafana Cloud,Alloy 的 WAL 是只存未送出樣本的
`emptyDir`),所以沒有卷要搬、也沒有 local-path PVC 把 pod 釘在某個節點上;
postgres-exporter 走 Service DNS 而非節點 IP,放行它的政策用的是
`namespaceSelector` 而非 `ipBlock` —— 認的是身分不是位置,換節點免修改;Grafana
Cloud 只靠對外 HTTPS 連線,不需要任何對內埠、DNS 記錄或憑證。*

### 4.4 What is NOT portable — and one of them is not ours

*不可移植的部分 —— 其中一項不屬於本 stack*

**(a) The host systemd timer.** `scripts/install-metrics-timer.sh` installs to
`/usr/local/sbin` on **one** machine and writes `.prom` files into that machine's
`/var/lib/node_exporter/textfile_collector`. A second node would run
node-exporter (DaemonSet) but have an empty textfile directory — so
`image_store_disk_bytes` and `pod_log_total_bytes` would exist for louis2 and
silently not exist for the new node. Runbook Step 4 must be re-run **per node**.
Its paths also assume k3s + a podman build store, which only holds for nodes that
actually build images.

*host 的 systemd timer 只裝在**一台**機器上。第二個節點會有 node-exporter(DaemonSet)
但 textfile 目錄是空的 —— 那兩個自訂指標對 louis2 存在、對新節點靜默地不存在。Step 4
必須**每個節點各跑一次**;而且它的路徑假設該節點有 k3s 與 podman build store,只有真
的在上面 build image 的節點才成立。*

**(b) The `ipBlock` rules in `cluster/networkpolicies/*.yaml` — Phase B's, not
ours.** Four policies hardcode `10.0.0.240/32` (louis2's node IP) and three also
hardcode `10.42.0.1/32` (node 0's cni0 gateway). A second node has a different
node IP and its own pod-CIDR gateway (`10.42.1.1`), so **kubelet probes issued
from that node to pods scheduled on it would be dropped**: readiness never turns
true, the rollout never completes, and the app looks broken for a reason that has
nothing to do with the app. This is pre-existing and lands the moment a node is
added — flagged here because scenario A is what exposes it, but the fix belongs
with the Phase B/C work, not with observability.

*四個政策寫死了 `10.0.0.240/32`(louis2 的節點 IP),其中三個還寫死了 `10.42.0.1/32`
(節點 0 的 cni0 閘道)。第二個節點的節點 IP 不同、pod CIDR 閘道也是自己的
(`10.42.1.1`),所以**由該節點發出、打向其上 pod 的 kubelet 探針會被丟掉**:readiness
永遠不會成立、rollout 永遠不會完成,而 app 看起來壞掉的原因跟 app 本身無關。這是既有
問題,只要加節點就會發生 —— 記在這裡是因為情境 A 會把它翻出來,但修它屬於 Phase B/C,
不屬於 observability。*

### 4.5 Scenario B — a separate instance / 獨立的另一台

Collectors cannot leave what they measure. node-exporter must sit on the node
whose `/proc` it reads; cAdvisor/kubelet series come from that node's kubelet;
postgres-exporter must reach Postgres on 5432. So for a genuinely separate
instance there is nothing to "move" — you install a **second copy** of the same
manifests in that cluster, pointing at the same Grafana Cloud stack.

*採集器不能離開它所量測的對象:node-exporter 必須在它要讀 `/proc` 的那台節點上、
cAdvisor/kubelet 的資料來自該節點的 kubelet、postgres-exporter 必須連得到 5432 的
Postgres。所以對一台真正獨立的機器而言,沒有東西可以「搬」—— 是在那個叢集裡**再裝一
份**相同的 manifest,指向同一個 Grafana Cloud stack。*

For that to work the two copies must be distinguishable, which is why
`external_labels` was changed from a hardcoded `cluster = "louis2"` to
`cluster = sys.env("CLUSTER_NAME")` (`CLUSTER_NAME: fra-k3s` in the Deployment
env). Without it, a second cluster's series would carry the same `cluster` label
and merge into the first's — two machines' metrics averaged into one meaningless
line. Change that one env value per cluster and nothing else.

*要讓兩份共存,必須能區分它們 —— 這就是 `external_labels` 從寫死的
`cluster = "louis2"` 改成 `cluster = sys.env("CLUSTER_NAME")`(Deployment env 裡設
`CLUSTER_NAME: fra-k3s`)的原因。否則第二個叢集的 series 會帶著相同的 `cluster`
標籤,跟第一個混在一起 —— 兩台機器的指標被平均成一條沒有意義的線。每個叢集只要改那
一個環境變數,其他都不動。*

The value is a **location**, not a machine name: `fra` = `eu-frankfurt-1`. A
cluster outlives any one node, so naming it after its first member (`louis2-k3s`)
would read wrong the moment a second node joined — which is precisely scenario A,
the one this stack is now built to survive. The `lansoulot` tenancy's
`us-sanjose-1` would be `sjc-k3s`. The second axis, `fleet = "lans-h-cc"`, is the
constant one and already carries ownership; `cluster` is the axis that varies, so
it is the one that has to discriminate.

*這個值是**位置**,不是機器名:`fra` = `eu-frankfurt-1`。cluster 的壽命長於任何單一
節點,所以拿第一個成員命名(`louis2-k3s`)在第二個節點加入的那一刻就會讀起來不對 ——
而那正是情境 A,這個 stack 現在就是為了撐過它才改的。`lansoulot` tenancy 的
`us-sanjose-1` 會是 `sjc-k3s`。另一個軸 `fleet = "lans-h-cc"` 是恆定的、已經承載了歸屬,
`cluster` 才是會變的那個軸,所以由它負責區分。*

**This is the one value that is expensive to change later.** It is stamped onto
every series; renaming after data exists splits the history in two and queries
stop joining across the rename. Decided 2026-08-04, before Step 3 — the token and
access-policy names, by contrast, are cosmetic and can be rotated at any time
(mint a new policy, swap the Secret, delete the old one).

***這是唯一「事後改很貴」的值。**它會被烙進每一條 series;有資料之後改名會把歷史切成
兩段,查詢無法跨越改名接起來。2026-08-04 於 Step 3 之前定案 —— 相對地,token 與 access
policy 的名稱只是外觀,隨時可以輪替(建新 policy、換掉 Secret、刪舊的)。*

Note this is a **different question from §2**. §2 asks where the metrics *backend*
lives; §4.5 asks where the *collectors* run. §2.4's conclusion (push, never pull)
is what keeps them independent: the backend can move without any collector
changing, because no collector is ever connected *to*.

*注意這跟 §2 是**不同的問題**。§2 問的是指標**後端**放哪裡;§4.5 問的是**採集器**跑在
哪裡。§2.4 的結論(只推不拉)正是讓兩者互相獨立的原因:後端可以搬家而採集器一行都不
用改,因為從來沒有人「連進」採集器。*

---

## 5. Embedding dashboards in `lans-h.cc` — Grafana Cloud will not do it

*把 dashboard 嵌進 `lans-h.cc` —— Grafana Cloud 做不到*

Raised 2026-08-04. Nothing here blocks applying the stack; it only decides what
happens *after* there are dashboards worth showing.

*2026-08-04 提出。這一節不擋 stack 上線,它決定的是「有值得展示的 dashboard 之後」要
怎麼做。*

### 5.1 The limit, stated exactly / 限制的確切內容

Grafana's own documentation: *"Panel embedding and anonymous access permissions
are not available in Grafana Cloud, even for panels in externally shared
dashboards."* Both are **Grafana OSS / Enterprise** features. So on the free tier
there is no `<iframe>` route at all — not for a panel, not for a whole dashboard.

*Grafana 官方文件:*"Panel embedding and anonymous access permissions are not
available in Grafana Cloud, even for panels in externally shared dashboards."*
兩者都是 **Grafana OSS / Enterprise** 的功能。所以免費層根本沒有 `<iframe>` 這條路 ——
單一 panel 不行,整個 dashboard 也不行。*

What Cloud *does* give:

*Cloud 確實有的:*

| Mechanism | What it is | Usable on `lans-h.cc`? |
|---|---|---|
| **Externally shared dashboard** (ex-"public dashboard") | a login-free public URL | a **link** out to `*.grafana.net`, not an embed |
| **Snapshot** | a frozen point-in-time copy | same — a link, and the data never updates |
| **PNG / PDF export** | a rendered image | yes, if something fetches it on a schedule |

Two further limits worth knowing before choosing the shared-dashboard route:
**template variables are not supported** (so any dashboard using `$namespace`
must be rebuilt with values hardcoded), and **query caching and rate limiting are
Enterprise features** — a public URL that a crawler finds is a public URL that
spends your free-tier query budget.

*選 shared-dashboard 這條路之前還要知道兩件事:**不支援 template variables**(任何用到
`$namespace` 的 dashboard 都得重做一份把值寫死),以及 **query caching 與 rate limiting
是 Enterprise 功能** —— 公開 URL 被爬蟲找到,就是有人在花你免費層的查詢額度。*

### 5.2 The route that does work — Grafana OSS as a UI layer only

*可行的那條路 —— Grafana OSS 只當 UI 層*

Run Grafana OSS on the cluster (~150 MB class, an order of magnitude lighter than
Prometheus) with its datasource pointing back at **Grafana Cloud's** Prometheus.
`allow_embedding` and `auth.anonymous` are then your own config file, so
`<iframe>` works.

*在叢集上跑一份 Grafana OSS(約 150 MB 級距,比 Prometheus 輕一個量級),datasource 指
回 **Grafana Cloud** 的 Prometheus。`allow_embedding` 和 `auth.anonymous` 就變成你自己
的設定檔,`<iframe>` 因此可用。*

**This does not violate the offload principle** (`README.md`: "a monitor must
never compete for the resources it is monitoring"). The heavy half — TSDB
storage, query execution, 14-day retention — stays rented. What lands on `louis2`
is only "turn a query result into a picture". The split is storage-and-query
remote, rendering local, and that is a defensible line rather than a slide back
toward self-hosting.

***這不違反 offload 原則**(`README.md`:「監控系統絕不該跟它監控的對象搶資源」)。
重的那半 —— TSDB 儲存、查詢執行、14 天保留 —— 仍然是租的,落在 `louis2` 上的只有「把
查詢結果畫成圖」。分界是「儲存與查詢在遠端、渲染在本地」,這是一條站得住腳的線,不是
偷偷滑回自架。*

Cost: one more Deployment, one more Ingress, one config file, and a
**`metrics:read`** access policy — which the Alloy token deliberately is not (see
runbook §0c). Two separate policies, never one with both scopes.

*代價:多一個 Deployment、一個 Ingress、一份設定檔,以及一組 **`metrics:read`** access
policy —— Alloy 那支是刻意沒有讀取權限的(見 runbook §0c)。兩組獨立 policy,絕不要
一組勾兩個 scope。*

The cheaper alternative, if interaction is not needed: a systemd timer that hits
Grafana's render API and drops PNGs into `my_website`'s static tree. `my_website`
is a static nginx site with no backend, so this needs nothing new running — the
`observability-metrics.timer` pattern already exists. Static, delayed, not
clickable.

*不需要互動的話有更省事的做法:一個 systemd timer 打 Grafana 的 render API,把 PNG 丟進
`my_website` 的靜態目錄。`my_website` 是沒有後端的 nginx 靜態站,這條不需要新增任何常駐
的東西 —— `observability-metrics.timer` 的模式已經在了。缺點是靜態、有延遲、不能點。*

### 5.3 The part that must be settled first — what a public dashboard leaks

*必須先解決的部分 —— 公開 dashboard 會洩漏什麼*

This repo already keeps **two copies of `topology.html`**: the full internal one
here, and a security-redacted one in `my_website/public`. Publishing a dashboard
built from these metrics walks straight through that redaction. It exposes
namespace names (which *are* the app names), `pg_database_size_bytes{datname=…}`
per app, pod names, container log paths, and the node's remaining memory and
disk. That is a ready-made reconnaissance surface, and it contradicts a
decision this repo has already made deliberately.

*這個 repo 已經維持**兩份 `topology.html`**:這裡是完整的內部版,`my_website/public` 是
做過 security redaction 的公開版。把這些指標做成的 dashboard 發布出去,等於直接穿過那道
redaction。它會露出 namespace 名(那**就是** app 名)、每個 app 的
`pg_database_size_bytes{datname=…}`、pod 名稱、container log 路徑,以及節點剩餘的記憶體
與磁碟。那是現成的偵察面,而且牴觸這個 repo 已經刻意做過的決定。*

So the rule is: **build a separate dashboard for public consumption**, containing
only deliberately chosen panels (uptime, request rate, one or two aggregate
curves) — never expose the internal one. Note that the shared-dashboard route
forces a rebuild anyway (§5.1, no template variables), so the security
requirement and the product limit point at the same action.

*所以規則是:**另外做一份給公開看的 dashboard**,只放刻意挑過的 panel(uptime、request
rate、一兩條聚合曲線)—— 絕不要把內部那份開放出去。順帶一提,shared-dashboard 這條路
本來就強迫你重做一份(§5.1,不支援 template variables),所以安全需求和產品限制指向
同一個動作。*

### 5.4 Decision / 決定

**Deferred, not rejected.** Apply the stack first, let it collect for a few days,
then decide once there are real dashboards to judge. The only thing brought
forward is runbook §0c's optional read-only policy — recorded there now because
Step 0 has not been run yet, and adding a second access policy while you are
already in that UI costs nothing, whereas coming back later means a second pass.

***延後,不是否決。**先把 stack 上線、收幾天資料,等有真正的 dashboard 可以評估再決定。
唯一提前處理的是 runbook §0c 那組選配的唯讀 policy —— 現在記進去,是因為 Step 0 還沒
跑,人已經在那個 UI 裡時多建一組 access policy 不花成本,之後再回頭就是多跑一趟。*

---

## Unrelated hygiene / 無關的小事

`~/.oci/lansoulot@gmail.com-*.pem` has permissions the OCI CLI warns about on
every call. `chmod 600` it.

*`~/.oci/lansoulot@gmail.com-*.pem` 權限過寬,OCI CLI 每次呼叫都會警告。`chmod 600`。*
