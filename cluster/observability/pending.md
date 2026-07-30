# Observability — pending fixes and open decisions

*可觀測性 —— 待修項與未定決策*

Recorded 2026-07-29. Two independent things live here: **§1 must be fixed before
this stack is applied to the node at all**, and **§2 is a design choice that can
stay open** — the stack works without deciding it.

*記錄於 2026-07-29。這裡有兩件互不相干的事:**§1 是這個 stack 上節點之前必須先修
的**,**§2 是可以先擱著的設計選擇** —— 不決定它 stack 也能上。*

Branch state: `observability-stack`, 2 commits, based on `883e07f`, **13 commits
behind `main`**, not pushed, not applied to the node.

*分支狀態:`observability-stack`,2 個 commit,基底 `883e07f`,**落後 `main` 13 個
commit**,未 push,未套用到節點。*

---

## 1. Pre-flight fixes — required before applying

*套用前必修項*

All of these exist because this branch was authored **before** the Phase B-1..B-4
security hardening landed on `main` (`a9d739e` NetworkPolicy, `f919ae6` postgres
limits). Rebase onto `main` first, then fix these.

*這些問題全部來自:本分支的撰寫時間**早於** Phase B-1..B-4 的加固進 `main`
(`a9d739e` NetworkPolicy、`f919ae6` postgres limits)。先 rebase 到 `main`,再修
以下各項。*

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

The `lansoulot` tenancy has **no A1 instance**, so its full Always Free Ampere
allowance — **4 OCPU / 24 GB** — is available. Running `terraform apply` in
`lansoulot/` creates one; bumping `shape_ocpus`/`shape_memory_gbs` to **2 / 12**
costs nothing and removes the single-core risk (on 1 core, TSDB compaction plus a
wide range query saturates it for seconds — dashboards get sluggish, nothing
dies).

*`lansoulot` tenancy **一台 A1 都沒有**,所以整份 Always Free Ampere 配額
(**4 OCPU / 24 GB**)可用。在 `lansoulot/` 跑 `terraform apply` 就能建一台;把
`shape_ocpus`/`shape_memory_gbs` 提到 **2 / 12** 不花錢,並消掉單核風險(單核上
TSDB compaction 疊一條寬範圍查詢會被吃滿數秒 —— dashboard 卡頓,但不會掛)。*

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

## Unrelated hygiene / 無關的小事

`~/.oci/lansoulot@gmail.com-*.pem` has permissions the OCI CLI warns about on
every call. `chmod 600` it.

*`~/.oci/lansoulot@gmail.com-*.pem` 權限過寬,OCI CLI 每次呼叫都會警告。`chmod 600`。*
