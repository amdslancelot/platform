# Security Posture Audit — Remediation Plan (Phase B)

*資安態勢稽核 — 修復計畫(Phase B)*

**Date / 日期:** 2026-07-28
**Companion to / 對應文件:** `docs/security-posture-audit.md` (the ranked findings)
**Scope / 範圍:** Phase B of the A–D remediation plan — the zero-to-low-downtime
hardening. Phases C and D are out of scope here.

*本文是 A–D 修復計畫裡的 Phase B —— 零到低中斷的加固。C 與 D 不在本文範圍。*

Everything below was measured against the live node on 2026-07-28 by read-only
inspection. **No change has been applied yet.** Where this document contradicts
`security-posture-audit.md`, this one is newer — the corrections are recorded in
§5.

*以下全部是 2026-07-28 對線上節點做唯讀檢查量測到的結果。**目前尚未套用任何變更。**
本文與稽核報告牴觸之處以本文為準,更正記錄在第 5 節。*

---

## 0. Status at a glance

*狀態總覽*

| # | Item / 項目 | Owner / 歸屬 | Downtime / 中斷 | Status |
|---|---|---|---|---|
| B-1 | Disable `rpcbind` | platform (node) | none | ✅ **done 2026-07-28** |
| B-2 | PSA labels, `warn`+`audit` only | platform repo | none | ✅ **done 2026-07-28** |
| B-3 | NetworkPolicy per namespace | platform repo | none if correct | ✅ **done 2026-07-28** |
| B-4 | `postgres` resource limits | platform repo | **~30s DB restart** | ❌ deferred — needs a window *待開維護窗口* |
| B-5 | `securityContext` — gelp, transigen | **gelp / transigen repos** | none (surge rollout) | ❌ not started |
| B-6 | `lans-h-site` → non-root nginx | **my_website repo** | apex site rollout | ❌ not started |
| B-7 | `postgres` → non-root | platform repo | **maintenance window** | ❌ not started |
| B-8 | kubeconfig `0600` + scoped RBAC | platform (node) | breaks all deploys if rushed | ❌ not started |

**B-1 through B-4 are entirely platform-owned and reversible.** B-5 onward reach
into sibling app repos or carry real outage risk.

***B-1 到 B-4 完全屬於 platform 且可回滾。** B-5 之後會動到 sibling app repo,或帶有
實質停機風險。*

---

## 1. Concepts required before executing

*執行前必須先理解的概念*

This section exists because three of the four Phase B items fail badly if
executed without understanding the mechanism. It is also the part most likely to
be examined in an interview.

*這一節存在的理由是:Phase B 四項裡有三項,在不理解機制的情況下執行會出大問題。
這一節同時也是面試最可能被追問的部分。*

### 1.1 What Pod Security Admission actually is

*Pod Security Admission 到底是什麼*

PSA is a **validating admission controller built into the API server**, GA since
Kubernetes 1.25, replacing the removed PodSecurityPolicy. Nothing needs to be
installed; it is simply not enabled by default.

*PSA 是**內建在 API server 裡的驗證型准入控制器**,Kubernetes 1.25 起 GA,用來取代
已被移除的 PodSecurityPolicy。不需要安裝任何東西,只是預設不啟用。*

It is turned on by labelling a namespace:

*啟用方式是在 namespace 上貼標籤:*

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/<mode>: <level>   # 模式:等級
```

**Three levels / 三種等級**

| Level | What it blocks / 擋什麼 |
|---|---|
| `privileged` | nothing — equivalent to off *什麼都不擋,等於沒開* |
| `baseline` | known escalation paths: `privileged`, `hostNetwork`, `hostPID`, `hostIPC`, `hostPath`, `hostPort`, unsafe sysctls *已知的提權途徑* |
| `restricted` | baseline **plus** a demand that you positively declare safe values *baseline 之上,再要求你主動宣告安全值* |

**Three modes / 三種模式**

| Mode | Behaviour / 行為 |
|---|---|
| `enforce` | rejects pod creation *拒絕建立 pod* |
| `warn` | allows, returns a warning the client prints *放行,回傳警告,`kubectl` 會直接印出來* |
| `audit` | allows, records the violation in the API-server audit log *放行,寫進 audit log* |

All three can coexist at different levels — the standard progressive path:

*三種可以同時存在且設不同等級 —— 標準的漸進路線:*

```yaml
pod-security.kubernetes.io/enforce: baseline    # 底線:守住不准提權
pod-security.kubernetes.io/warn: restricted     # 目標:看看離 restricted 還差多少
```

**Three properties that are routinely misunderstood / 三個常被誤解的性質**

1. It evaluates **only at pod create/update**. Labelling a namespace `enforce`
   does **not** kill running pods.
   *只在 pod 建立/更新時評估。貼上 `enforce` 標籤不會殺掉正在跑的 pod。*
2. It **validates, it does not mutate**. It will never add `runAsNonRoot: true`
   for you.
   *只驗證,不修改。它不會幫你自動補上欄位。*
3. Its scope is the **namespace**, not the cluster and not the pod.
   *作用範圍是 namespace,不是叢集全域也不是單一 pod。*

**Its ceiling / 它的天花板** — PSA governs pod-spec security fields only. It
cannot express network isolation (that is NetworkPolicy), image provenance, or
any custom rule such as "every Deployment must declare resource limits". Those
require a policy engine — Kyverno or OPA Gatekeeper.

*PSA 只管 pod spec 的安全欄位。它無法表達網路隔離(那是 NetworkPolicy 的事)、映像檔
來源可信度,或任何自訂規則(例如「所有 Deployment 必須有 resource limits」)。那些需要
Kyverno 或 OPA Gatekeeper 這類 policy engine。*

> 🎯 **Interview / 面試考點** — the JD names "admission control" as a hard
> requirement. The correct framing is that **PSA is the built-in floor, not the
> ceiling**. Saying "I used PSA to hold the pod-level baseline, but it doesn't
> cover image provenance or custom rules — that needs a policy engine" carries
> considerably more weight than "I configured PSA".
>
> *JD 把 "admission control" 列為硬性要求。正確的定位是 **PSA 是內建的地板,不是
> 天花板**。說「我用 PSA 守住 pod-level 的基本盤,但它不涵蓋映像檔來源和自訂規則,
> 那需要 policy engine」比單純說「我設過 PSA」有份量得多。*

### 1.2 PSA is not SELinux — where the analogy breaks

*PSA 不是 SELinux —— 類比斷在哪裡*

The node runs SELinux in `enforcing` mode with the `targeted` policy, and
containerd is confined to `container_runtime_t`. Both layers are active
simultaneously, so the comparison is a natural one to draw.

*本節點的 SELinux 是 `enforcing`、`targeted` policy,containerd 被侷限在
`container_runtime_t` 域。兩層同時作用,所以會拿來類比很自然。*

```sh
getenforce                                       # → Enforcing
ps -eZ | grep container_runtime_t                # → containerd 在 container_runtime_t 域
```

**Genuine similarities / 真的相似之處**

1. Both are external mandatory policy layers the application cannot exempt itself from.
   *都是外加的強制策略層,應用程式無法自行豁免。*
2. Both have an observe-before-enforce mode — SELinux `permissive` maps onto PSA
   `warn`/`audit`, and the operational discipline is identical: run permissive,
   collect denials, fix, then enforce.
   *都有「先觀察再強制」的模式 —— SELinux 的 `permissive` 對應 PSA 的 `warn`/`audit`,
   維運紀律完全一樣:先跑觀察模式、收集拒絕紀錄、修掉、最後才切 enforcing。*
3. Both are deny-by-default at their strict level.
   *嚴格等級都是 deny-by-default。*

**Where it breaks / 斷裂之處**

| | PSA | SELinux |
|---|---|---|
| When it checks | once, at pod create/update *建立時一次* | every access, for the process's life *每次存取,持續* |
| What it inspects | field declarations in YAML *YAML 裡的欄位宣告* | actual syscalls, files, ports *實際的 syscall / 檔案 / port* |
| Where it runs | API server, pure userspace *API server,純使用者空間* | kernel LSM hooks *核心的 LSM hook* |
| Customisable | no — three fixed levels *不行,只有三個固定等級* | yes — full policy language *可以,完整 policy 語言* |

**PSA is the ticket inspector at the door; SELinux is the guard who follows you
around the building.** Once PSA has admitted the pod it never looks again.

***PSA 是門口的驗票員,SELinux 是全程跟著你的警衛。** PSA 放行之後就再也不看了。*

**The deepest difference: PSA can be satisfied by a declaration.**

***最本質的差別:PSA 可以被「宣告」滿足。***

SELinux cannot be lied to — it checks the operation. PSA checks the manifest. A
pod that declares `runAsNonRoot: true` passes PSA **without PSA ever inspecting
the image**. The real check happens later, in the kubelet, which resolves the
image's `USER` at container start and fails the pod with
`CreateContainerConfigError` if it resolves to root. `seccompProfile:
RuntimeDefault` follows the same pattern — PSA confirms you *asked for* seccomp;
the container runtime and kernel are what actually apply the filter.

*SELinux 騙不了 —— 它檢查的是操作本身。PSA 檢查的是 manifest。一個宣告了
`runAsNonRoot: true` 的 pod 就能通過 PSA,**而 PSA 從來沒有去看 image**。真正的檢查
發生在後面的 kubelet:容器啟動時它會解析 image 的 `USER`,若解析出 root 就讓 pod 以
`CreateContainerConfigError` 失敗。`seccompProfile: RuntimeDefault` 也是同樣模式 ——
PSA 只確認你**有沒有要求** seccomp,真正掛上 filter 的是 container runtime 與核心。*

The correct mental model:

*正確的心智模型:*

> **PSA enforces nothing. It checks whether you asked for enforcement.** The
> enforcement itself is delegated to the kubelet, the container runtime, and the
> kernel's seccomp / SELinux / capabilities.
>
> ***PSA 本身不執行任何保護。它只檢查「你有沒有申請保護」。** 真正執行的是 kubelet、
> container runtime,以及核心裡的 seccomp / SELinux / capabilities。*

The full stack a container must cross on this node:

*在這台機器上,一個容器要做壞事得同時穿過:*

```
PSA           → manifest 有沒有要求特權          (建立時,一次)
kubelet       → 執行身分是否符合宣告              (啟動時)
capabilities  → 行程能不能執行特權操作            (核心,持續)
seccomp       → 哪些 syscall 被允許               (核心,持續)
SELinux       → container_t 能碰哪些標籤的檔案與 port (核心,持續)
```

PSA is the outermost, earliest and weakest layer — but it is the only one that
can reject "someone is deploying a pod that mounts `hostPath: /`" **before it
exists**, which is precisely the case the lower layers arrive too late to save.

*PSA 是最外面、最早、也最弱的一層 —— 但它是唯一能在事情發生**之前**、用 YAML 就擋掉
「有人要部署一個掛 `hostPath: /` 的 pod」的一層,而那正是下面幾層來不及救的情況。*

> 🎯 **Interview / 面試考點** — this is a strong answer because it demonstrates
> mapping a Kubernetes control onto a Linux one *and* knowing where the mapping
> fails. Stopping at "PSA is like SELinux" reads shallow; continuing to "but PSA
> is an admission-time declaration check, not runtime access control — the real
> enforcement is delegated to the kubelet and the kernel" reads senior.
>
> *這題答得好會很有份量,因為它同時展示了「把 K8s 控制對應到 Linux 控制」以及「知道
> 對應在哪裡失效」。停在「PSA 很像 SELinux」顯得淺;講到「但 PSA 是 admission-time 的
> 宣告檢查,不是 runtime 的存取控制,真正的執行委派給 kubelet 和核心」就是另一個層次。*

### 1.3 Five workloads, four identical violations

*五個 workload,四項完全相同的違規*

A throwaway namespace labelled `enforce=restricted` was created, each live pod
spec was server-side dry-run into it, and the namespace was deleted. Nothing
running was touched.

*開了一個丟棄用的 namespace 標上 `enforce=restricted`,把每個線上 pod spec 用
server-side dry-run 丟進去,測完刪掉。線上服務沒有被碰到。*

```sh
kubectl create ns psa-probe                                        # 建立探測用 namespace
kubectl label ns psa-probe pod-security.kubernetes.io/enforce=restricted
# 逐一把 Deployment 的 pod template 抽出來 dry-run
kubectl create -f - --dry-run=server < <pod-spec>
kubectl delete ns psa-probe                                        # 測完立刻刪除
```

**The five first-party workloads / 五個自有 workload**
(third-party charts — cert-manager, Traefik, CoreDNS — were excluded; they ship
hardened already)

*(第三方 chart 排除,它們出廠就加固過了)*

| Namespace / Workload | Actual uid / 實際 uid |
|---|---|
| `gelp/gelp` | 1000 |
| `transigen/transigen` | 1000 |
| `snoopy/snoopy` | 0 |
| `web/lans-h-site` | 0 |
| `data/postgres` | 0 |

**The four violations, identical across all five / 四項違規,五個一字不差**

| # | PSA verdict / 判定 | Field to add / 要補的欄位 |
|---|---|---|
| 1 | `allowPrivilegeEscalation != false` | container: `allowPrivilegeEscalation: false` |
| 2 | `unrestricted capabilities` | container: `capabilities.drop: ["ALL"]` |
| 3 | `runAsNonRoot != true` | pod or container: `runAsNonRoot: true` |
| 4 | `seccompProfile` | `seccompProfile.type: RuntimeDefault` |

**Why they are identical is not a coincidence — it is structural.**

***為什麼完全相同不是巧合,而是結構性的。***

First, all five manifests declare **nothing**. Audit finding #3's evidence table
showed every field empty. The PSA message describes not what the workloads *do*
but what their manifests *fail to declare* — identical absence produces an
identical list.

*第一,五份 manifest **什麼都沒宣告**。稽核報告第 3 項的證據表裡每個欄位都是空的。
PSA 的訊息描述的不是這些 workload 做了什麼,而是它們的 manifest 少宣告了什麼 ——
相同的缺席產生相同的清單。*

Second, `restricted` checks far more than four things, but its checks divide into
two kinds:

*第二,`restricted` 檢查的遠不只四項,但它的檢查分成性質完全不同的兩類:*

- **Prohibitive — "must not do X"**: `privileged`, `hostNetwork`, `hostPID`,
  `hostIPC`, `hostPath`, `hostPort`, unsafe sysctls, `/proc` mount type, volume
  type allowlist. **Field absent = pass.** None of the five requests any of it
  (postgres uses a PVC, which is on the `restricted` volume allowlist), so this
  entire class passes.
  *禁止型 ——「不可以做 X」。**欄位沒寫 = 通過**。五個都沒要求這些,所以整類全過。*
- **Prescriptive — "must explicitly set X to a safe value"**: the four above.
  **Field absent = fail.**
  *規定型 ——「必須明確設成安全值」,就是上面那四項。**欄位沒寫 = 失敗**。*

`restricted`'s prescriptive checks number **exactly four**. Five manifests that
declare nothing therefore pass every prohibitive check and fail every
prescriptive one — four, no more and no fewer. The message is assembled by one
evaluator concatenating failures in a fixed order, so identical failure sets
produce byte-identical strings.

*`restricted` 的規定型檢查**總共就是四項**。五份什麼都沒宣告的 manifest 必然是禁止型
全過、規定型全倒,不多不少四項。訊息是同一個 evaluator 依固定順序把失敗項目串起來的
字串,失敗集合相同就會逐字元相同。*

**The apparent paradox / 表面上的矛盾** — gelp runs as uid 1000 and postgres runs
as uid 0, yet both receive the identical `runAsNonRoot != true`. That message
does not say "you are root"; it says "**you have not declared that you are not
root**". It describes nothing about runtime behaviour, so this output must not be
used to rank which workload is more dangerous.

*gelp 以 uid 1000 跑、postgres 以 uid 0 跑,兩者卻拿到完全相同的
`runAsNonRoot != true`。那句話講的不是「你是 root」,而是「**你沒有宣告你不是 root**」。
它完全沒有描述 runtime 行為,所以不能拿這份輸出來判斷哪個 workload 比較危險。*

This is why the fix has two very different characters: for gelp and transigen it
is **writing an existing fact into the manifest, zero behavioural change**; for
snoopy, lans-h-site and postgres it genuinely changes the execution identity.

*所以修法的性質完全不同:對 gelp/transigen 只是**把既成事實寫進 manifest,零行為
改變**;對 snoopy、lans-h-site、postgres 才是真的改變執行身分。*

**Probe fidelity / 實驗保真度** — the dry-run spec was modified in three places
to be schedulable into a temporary namespace: `nodeName` removed,
`nodeSelector`/`affinity`/`tolerations` removed, and postgres's PVC swapped for
an `emptyDir`. None of the three affects the four findings (PSA does not read
scheduling fields; PVC and `emptyDir` are both on the `restricted` volume
allowlist), but the tested spec was not byte-identical to the live one.

*為了能丟進臨時 namespace,dry-run 的 spec 有三處微調:拿掉 `nodeName`、拿掉
`nodeSelector`/`affinity`/`tolerations`、postgres 的 PVC 換成 `emptyDir`。三處都不影響
上述四項判定(PSA 不看排程欄位;PVC 與 `emptyDir` 同在 `restricted` 的 volume 白名單
內),但嚴格說測的不是與線上位元組完全相同的 spec。*

### 1.4 Why `enforce` must not be applied yet — delayed detonation

*為什麼現在還不能上 `enforce` —— 延遲引爆*

Since all five workloads fail `restricted`, applying `enforce` immediately would
block every future pod creation. The danger is not that it fails loudly — **it is
that it fails silently, later**.

*既然五個 workload 全部違反 `restricted`,直接上 `enforce` 會擋掉未來所有 pod 建立。
危險之處不在於它大聲失敗 —— **而在於它安靜地、稍後才失敗**。*

`enforce` evaluates only at pod create/update, so nothing that is currently
running is affected. After applying it the cluster looks entirely healthy. Then:

*`enforce` 只在 pod 建立/更新時評估,所以正在跑的東西完全不受影響。套用之後叢集看起來
一切正常。然後:*

- the next deploy → rejected *下一次部署 → 被擋*
- a node reboot, a pod eviction, any rollout → **the pod never comes back**
  *節點重開機、pod 被驅逐、任何 rollout → **pod 再也起不來***

A failure mode that detonates on the next reboot is worse than one that fails
immediately, because nobody discovers it at the time of the change. This is
exactly why the audit prescribes `warn`/`audit` first.

*一個在下次重開機才引爆的失敗模式,比立刻失敗更糟,因為沒有人會在變更當下發現。
這正是稽核報告寫「先用 warn/audit 觀察」的原因。*

> 🎯 **Interview / 面試考點** — "how would you roll out a restrictive admission
> policy to a running cluster without breaking it?" is a natural follow-up to any
> Kubernetes hardening claim. The answer is the staged one: `warn` first, collect
> what breaks, fix the manifests, then `enforce` — and the reason is that
> admission control fails *at the next pod creation*, not at apply time.
>
> *「你要怎麼在不弄壞叢集的前提下,把一個限制性的 admission policy 推到線上?」是任何
> K8s 加固主張的自然追問。答案就是分階段:先 `warn`、收集會壞的東西、修 manifest、
> 才上 `enforce` —— 理由是 admission control 是在**下一次 pod 建立**時失敗,不是在
> apply 當下。*

### 1.5 NetworkPolicy mechanics — the three traps

*NetworkPolicy 機制 —— 三個陷阱*

k3s is running with **no `--disable` flags**, so kube-router's NetworkPolicy
controller is active. Policies take effect the instant they are applied.

*k3s 沒有帶任何 `--disable` 參數,所以 kube-router 的 NetworkPolicy controller 是啟用
的。政策一 apply 就立刻生效。*

**Trap 1 — it is an allow-list, and selecting a pod flips that direction to
default-deny.** Adding a single egress rule does not "add an allowance"; it turns
off all egress for that pod except what the rule permits.

***陷阱 1 —— 它是 allow-list,而且一旦選中某個 pod 的某個方向,那個方向就變成
default-deny。*** *加一條 egress 規則不是「多開一個允許」,而是把該 pod 的所有對外流量
關掉,只留你寫的那幾條。*

**Trap 2 — forgetting DNS breaks everything.** Without an explicit allowance to
`kube-dns:53`, an app cannot even resolve `postgres.data.svc`. This is the single
most common way to take a cluster down with a NetworkPolicy.

***陷阱 2 —— 忘記放行 DNS 會全毀。*** *沒有明確放行 `kube-dns:53`,app 連
`postgres.data.svc` 都解析不出來。這是用 NetworkPolicy 弄垮叢集最常見的方式。*

**Trap 3 — `ipBlock` operates on IP addresses, so the node's own subnet must be
excluded explicitly.** This is the error in the first draft of these rules; see
§5.2.

***陷阱 3 —— `ipBlock` 是以 IP 位址運作的,所以節點自己的子網必須明確排除。***
*這是這組規則初稿裡的錯誤,見 5.2 節。*

---

## 2. Phase B-1 to B-4 — platform-owned, execute first

*Phase B-1 到 B-4 —— platform 自有,優先執行*

### B-1. Disable `rpcbind`

*關閉 `rpcbind`*

**Goal / 目標** — remove an externally-listening port that nothing uses. Nothing
on this node uses NFS or any RPC service; `0.0.0.0:111` is pure attack surface,
and historically a source of UDP amplification abuse and CVEs.

*移除一個沒有任何東西在用的對外監聽埠。這台機器沒有用到 NFS 或 RPC,`0.0.0.0:111`
是純粹多出來的攻擊面,歷史上也是 UDP 放大攻擊與 CVE 的來源。*

```sh
sudo systemctl disable --now rpcbind.socket rpcbind   # socket 與服務一起停,只停服務會被 socket 再喚醒
```

**Expect / 預期** — `ss -tlnp | grep :111` returns nothing.

*`ss -tlnp | grep :111` 沒有任何輸出。*

**Risk / 風險** — none. **Rollback / 回滾** — `sudo systemctl enable --now rpcbind.socket`.

*零風險。回滾用 `systemctl enable --now`。*

### B-2. PSA labels — `warn` + `audit` only

*PSA 標籤 —— 只上 `warn` + `audit`*

**Goal / 目標** — gain visibility into pod-security violations without blocking
anything, per §1.4.

*在不擋任何東西的前提下取得 pod 安全違規的能見度,理由見 1.4 節。*

Edit `cluster/namespaces.yaml` — for `snoopy`, `gelp`, `transigen`, `web`:

*編輯 `cluster/namespaces.yaml`,對四個 app namespace:*

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/warn: restricted      # 建立不合規 pod 時印警告,但放行
    pod-security.kubernetes.io/audit: restricted     # 同時記進 audit log
```

`data` (postgres legitimately needs more) gets `baseline` instead.

*`data`(postgres 確實需要較多權限)改用 `baseline`。*

```sh
kubectl apply -f cluster/namespaces.yaml                          # 套用標籤
kubectl get ns -o custom-columns=NS:.metadata.name,WARN:'.metadata.labels.pod-security\.kubernetes\.io/warn'
```

**Expect / 預期** — the four app namespaces show `restricted`; running pods are
untouched; the next deploy prints the four warnings from §1.3.

*四個 app namespace 顯示 `restricted`;正在跑的 pod 不受影響;下一次部署會印出 1.3 節
那四條警告。*

**Honest caveat / 要誠實講的一點** — `audit=restricted` writes to the API-server
audit log, and **audit logging is not yet enabled** (that is Phase C, finding
#6). Until then the `audit` label is inert. It is still worth setting so it
activates automatically when Phase C lands.

*`audit=restricted` 是寫進 API server 的 audit log,而 **audit log 目前還沒開**(那是
Phase C 第 6 項)。在那之前 `audit` 這個標籤是空轉的。仍然建議一起標上,這樣 Phase C
一做它就自動生效。*

**Risk / 風險** — none. **Rollback / 回滾** —
`kubectl label ns <ns> pod-security.kubernetes.io/warn-`.

### B-3. NetworkPolicy

*NetworkPolicy*

**Goal / 目標** — turn "isolated by credentials" into "isolated by credentials
**and** reachability". The pod network is currently flat: gelp's pod can open TCP
to postgres, to snoopy, to transigen, to the kubelet on `:10250` and to the API
server on `:6443`. The per-app database isolation is real but it is the *only*
layer.

*把「靠憑證隔離」升級成「靠憑證**加上**可達性隔離」。目前 pod 網路是完全扁平的:gelp
的 pod 可以直接對 postgres、snoopy、transigen、kubelet 的 `:10250`、API server 的
`:6443` 開 TCP。每個 app 的資料庫隔離是真的,但它是**唯一**一層。*

**Measured CIDRs / 量測到的網段** — these are what the rules must be written
against:

*規則必須依這些網段來寫:*

| Network | CIDR |
|---|---|
| Pod network *(cni0 / flannel)* | `10.42.0.0/16` (node slice `10.42.0.0/24`) |
| Service network | `10.43.0.0/16` (kube-dns `10.43.0.10`, API `10.43.0.1`) |
| **Node / VCN subnet** *(enp0s6)* | **`10.0.0.0/24`** (node `10.0.0.240`) |

Per app namespace, four policies. Using gelp as the worked example:

*每個 app namespace 四條政策,以 gelp 為例:*

```yaml
# 1) 預設全關:選中 namespace 內所有 pod,兩個方向都轉為 default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# 2) 只放行 Traefik 進來打 app 的 3000 埠
  ingress:
  - from:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: kube-system}
    ports: [{protocol: TCP, port: 3000}]
---
# 3) 放行 DNS —— 缺這條 app 連 service 名稱都解析不出來,全部會壞
  egress:
  - to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: kube-system}
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
---
# 4) 放行到 postgres 的 5432,且只到 data namespace
  - to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: data}
    ports: [{protocol: TCP, port: 5432}]
---
# 5) 放行對外網際網路,但排除所有叢集內部與節點網段
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.42.0.0/16      # pod 網段
          - 10.43.0.0/16      # service 網段
          - 10.0.0.0/24       # 節點所在的 VCN 子網 —— 少了這條就擋不住直接打 node IP
```

Rule 5 is required because all three stateful apps need outbound internet:
snoopy reaches Discord, Gemini and Google Calendar; gelp reaches Google Places
and Drive; transigen reaches YouTube and Spotify. The `except` list is what turns
"outbound allowed" into "outbound allowed, lateral movement denied".

*第 5 條是必要的,因為三個 app 都需要對外:snoopy 連 Discord / Gemini / Google
Calendar,gelp 連 Google Places / Drive,transigen 連 YouTube / Spotify。`except`
清單才是把「可以對外」變成「可以對外、但橫向移動被擋」的關鍵。*

**Per-app differences / 各 app 的差異**

| App | Ingress | Egress |
|---|---|---|
| `snoopy` | **none needed** — no Service, no Ingress; it is a Discord bot with outbound only *完全不需要* | DNS + postgres + internet |
| `web/lans-h-site` | Traefik → `:80` | DNS only — static site, no DB, no outbound *只要 DNS* |
| `gelp`, `transigen` | Traefik → `:3000` | DNS + postgres + internet |
| `data` | only from `gelp`/`transigen`/`snoopy` on `:5432` *只接受這三個 namespace 的 5432* | DNS only |

**Execution order / 執行順序** — one namespace at a time, verify, then proceed.
`web` first (simplest), then `snoopy` (easiest to verify — say something in
Discord and see if it replies), then `gelp` and `transigen` (log in through a
browser), then `data` last.

*一次一個 namespace,驗證過再進下一個。先 `web`(最單純),再 `snoopy`(最好驗 —— 去
Discord 說一句話看它回不回),接著 `gelp` 與 `transigen`(用瀏覽器實際登入一次),
`data` 最後。*

**Risk / 風險** — real. A wrong policy drops packets silently with no error
message. **Rollback / 回滾** — `kubectl delete netpol -n <ns> --all`, effective
immediately.

*真實風險。寫錯會靜默丟包,不會有錯誤訊息。回滾是
`kubectl delete netpol -n <ns> --all`,立即生效。*

**Observability impact / 對可觀測性的影響: none.** Verified:

*已驗證不受影響:*

- `metrics-server` scrapes the **kubelet** (`--kubelet-preferred-address-types=InternalIP`,
  `--kubelet-use-node-status-port`), not app pods; `kubectl top pod` data comes
  from cAdvisor and never traverses the app pod network. It also lives in
  `kube-system`, which these policies do not touch.
  *`metrics-server` 打的是 **kubelet**,不是 app pod;`kubectl top pod` 的資料來自
  cAdvisor,完全不經過 app pod 網路。而且它在 `kube-system`,政策不碰。*
- The OCI `unified-monitoring-agent` is a **host systemd service** (confirmed
  active), on the host network. NetworkPolicy governs pod networking only.
  *OCI `unified-monitoring-agent` 是**主機上的 systemd 服務**(確認 active),跑在主機
  網路。NetworkPolicy 只管 pod 網路。*
- The only pods annotated `prometheus.io/scrape=true` are cert-manager and
  Traefik, both outside the policied namespaces — and **no Prometheus is deployed**.
  *唯二帶 `prometheus.io/scrape=true` 的是 cert-manager 和 Traefik,都不在要套政策的
  namespace 裡 —— 而且**叢集裡根本沒有部署 Prometheus**。*

**One thing to confirm before applying / 套用前唯一要確認的** — whether any app
has a legitimate reason to reach the node itself or another host on
`10.0.0.0/24`. Current inspection says no (they reach postgres and external APIs
only), but the `except` list is the kind of rule that silently breaks things when
written too wide and silently leaves holes when written too narrow.

*三個 app 有沒有任何合法理由需要連到節點本身或 `10.0.0.0/24` 上的其他機器。目前檢查的
結果是沒有(只連 postgres 與外部 API),但 `except` 這條規則寫太寬會靜默擋掉正常流量、
寫太窄就靜默留洞。*

> 🎯 **Interview / 面試考點** — this is the single most quotable item in Phase B,
> because it maps directly onto the JD's **multi-tenant security architecture**
> requirement. The sentence that lands is: *"the per-app database roles were real
> isolation, but they were the only layer — a compromised app could still reach a
> peer's data plane and try credentials against it. NetworkPolicy is what turns
> isolation-by-credential into isolation-by-credential-and-reachability."*
>
> *這是 Phase B 裡最值得引用的一項,因為它直接對上 JD 的**多租戶安全架構**要求。最有
> 力的一句話是:「每個 app 的資料庫 role 是真的隔離,但它是唯一一層 —— 被攻陷的 app
> 仍然能連到別人的資料平面去試憑證。NetworkPolicy 才把『靠憑證隔離』變成『靠憑證加上
> 可達性隔離』。」*

### B-4. `postgres` resource limits

*`postgres` 的 resource limits*

**Goal / 目標** — postgres currently declares no requests or limits, which places
it in the `BestEffort` QoS class. Under node memory pressure **it is the first
thing the OOM killer selects** — and it is the shared database for three apps.
It also has no ceiling, so it could in principle consume the whole node.

*postgres 目前沒有任何 requests/limits,QoS 分類是 `BestEffort`。節點記憶體吃緊時
**它會是 OOM killer 第一個挑上的**,而它是三個 app 共用的資料庫。反過來它也沒有上限,
理論上能吃光整台機器。*

**Measured / 量測值** — postgres currently uses **10m CPU / 39Mi memory**. For
context, the workloads that *do* declare limits: gelp and transigen request
`100m/256Mi` with limits `1/1Gi`; snoopy requests `100m/128Mi` with limits
`200m/256Mi`. Missing limits entirely: **postgres, lans-h-site, Traefik,
cert-manager** — matching audit finding #10.

*postgres 目前用 **10m CPU / 39Mi 記憶體**。對照組:gelp 與 transigen requests
`100m/256Mi`、limits `1/1Gi`;snoopy requests `100m/128Mi`、limits `200m/256Mi`。
完全沒有 limits 的是 **postgres、lans-h-site、Traefik、cert-manager**,與稽核報告
第 10 項一致。*

In `cluster/data-postgres/postgres.yaml`:

```yaml
resources:
  requests: {cpu: 100m, memory: 256Mi}   # 保證額度,QoS 由 BestEffort 升為 Burstable
  limits:   {cpu: 1000m, memory: 1Gi}    # 上限,防止吃光 12GB 節點
```

**⚠️ This item is NOT zero-downtime.** Changing a Deployment's `resources`
triggers a rollout; with one replica and a PVC the postgres pod is recreated, so
the three dependent apps lose the database for roughly 30 seconds. **It needs a
short maintenance window** — unlike B-1 to B-3.

*⚠️ **這一項不是零中斷。** 改 Deployment 的 `resources` 會觸發滾動更新;單一 replica
加上 PVC,postgres pod 會重建,三個依賴它的 app 會有約 30 秒連不上資料庫。**它需要一個
短的維護窗口** —— 這點和 B-1 到 B-3 不同。*

**Expect / 預期** — new pod Ready, `kubectl describe pod` shows QoS class
`Burstable`, and a query from any app succeeds.

*新 pod Ready,`kubectl describe pod` 顯示 QoS class 為 `Burstable`,從任一 app 打一次
DB 成功。*

---

## 3. Phase B-5 to B-8 — app-repo-owned or higher risk

*Phase B-5 到 B-8 —— 屬於 app repo 或風險較高*

### B-5. `securityContext` for gelp and transigen

*gelp 與 transigen 的 `securityContext`*

**Goal / 目標** — close the four violations from §1.3 on the two workloads where
doing so is **purely declarative**: both already run as uid 1000, so this changes
no runtime behaviour.

*把 1.3 節那四項違規補起來,而且是在兩個**純宣告式**的 workload 上 —— 兩者本來就以
uid 1000 執行,所以完全不改變 runtime 行為。*

```yaml
spec:
  template:
    spec:
      automountServiceAccountToken: false     # 兩個 app 都不呼叫 K8s API,不需要 token 掛進來
      securityContext:                        # pod 層
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile: {type: RuntimeDefault}
      containers:
      - securityContext:                      # container 層
          allowPrivilegeEscalation: false
          capabilities: {drop: [ALL]}
```

**Deliberately omitted: `readOnlyRootFilesystem`.** Next.js standalone writes to
`/app/.next/cache` at runtime; enabling it without mounting an `emptyDir` there
causes a CrashLoop. Worth doing, but as a separate change.

***刻意不加 `readOnlyRootFilesystem`。*** *Next.js standalone 執行期會寫
`/app/.next/cache`,沒有先掛 `emptyDir` 就開會 CrashLoop。值得做,但要獨立一次改動。*

**Risk / 風險** — low. The rollout strategy is `maxSurge 25%` / `maxUnavailable
25%`, which at one replica starts the new pod before retiring the old one, so a
failing pod leaves the old one serving.

*低。滾動策略是 `maxSurge 25%` / `maxUnavailable 25%`,單一 replica 時會先起新 pod 再收
舊 pod,新 pod 起不來的話舊的還在服務。*

**The real caution is process, not technology / 真正要小心的是流程不是技術** —
these live in sibling repos (`gelp/deploy/k8s/base/app-deployment.yaml`,
`transigen/deploy/k8s/base/app-deployment.yaml`) and both deploy via push to main
→ Actions `next build` → HMAC curl to `:9000`. **Pushing is deploying**; there is
no intermediate confirmation step.

*這兩份在 sibling repo 裡,而且部署方式是 push main → Actions `next build` → HMAC curl
打 `:9000`。**push 出去就是上線**,沒有中間確認點。*

**Rollback / 回滾** — `kubectl rollout undo deploy/gelp -n gelp`.

### B-6. `lans-h-site` → non-root nginx

*`lans-h-site` 改為非 root nginx*

**Problem / 問題** — it is Alpine nginx binding `:80` directly. **A non-root
process cannot bind a port below 1024**, so setting `runAsNonRoot: true` alone
guarantees the pod will not start.

*它是 Alpine nginx 直接綁 `:80`。**非 root 不能綁 1024 以下的埠**,所以只設
`runAsNonRoot: true` 一定起不來。*

**Fix / 修法** — switch to `nginxinc/nginx-unprivileged` (runs as uid 101,
listens on 8080), and change `nginx.conf`'s `listen`, the Deployment's
`containerPort`, and the Service's `targetPort` together.

*改用 `nginxinc/nginx-unprivileged`(以 uid 101 執行、監聽 8080),同步改 `nginx.conf`
的 `listen`、Deployment 的 `containerPort`、Service 的 `targetPort`。*

**Risk / 風險** — this is the **apex domain `lans-h.cc`**; a mistake takes the
front page down, and my_website deploys on push.

*這是 **apex 網域 `lans-h.cc`**,做壞了首頁直接掛,而且 my_website 是 push 即上線。*

### B-7. `postgres` → non-root

*`postgres` 改為非 root*

**Problem / 問題** — the PVC data directory is owned `0:0` with mode `777`. The
official postgres image starts as root and drops to uid 999 via gosu for the
actual server process. Making the **container** start non-root requires
`runAsUser: 999` plus `fsGroup: 999`, **and the existing data directory must be
chowned first** or postgres will not start.

*PVC 上的資料目錄是 `0:0`、mode `777`。官方 postgres image 是先以 root 啟動,再用 gosu
降到 uid 999 跑實際的 server 行程。要讓**容器本身**以非 root 啟動,得設 `runAsUser: 999`
加 `fsGroup: 999`,而且**既有資料目錄必須先 chown**,否則 postgres 起不來。*

**Risk / 風險** — the highest in Phase B. It is the shared database for three
apps; a mistake means restoring from backup. Requires a backup first and a real
maintenance window.

*Phase B 裡最高。三個 app 共用的資料庫,做壞了要從備份還原。必須先備份、開維護窗口。*

### B-8. kubeconfig `0600` + scoped RBAC

*kubeconfig 改 `0600` 加受限 RBAC*

**Problem / 問題** — `/etc/rancher/k3s/k3s.yaml` is mode 644 and contains
**cluster-admin credentials**. Any local user, and any process running as any
user on the node, reads it and becomes cluster-admin. It is the step that turns a
foothold in one container into control of the whole cluster.

*`/etc/rancher/k3s/k3s.yaml` 是 644,裡面是 **cluster-admin 憑證**。節點上任何本機
使用者、任何行程都能讀走它變成 cluster-admin。它是把「某個容器裡的立足點」升級成
「整個叢集控制權」的那一步。*

**But it is deliberate / 但它是刻意的** — `bootstrap-node.sh` states that `opc`
must run bare `kubectl` without sudo, and `gelp/deploy/deploy.sh`,
`my_website/deploy/deploy.sh` and snoopy's Actions-over-SSH **all depend on it**.

*`bootstrap-node.sh` 寫明要讓 `opc` 免 sudo 跑 `kubectl`,而
`gelp/deploy/deploy.sh`、`my_website/deploy/deploy.sh`、snoopy 的 Actions-SSH
**全都依賴這件事**。*

**Order matters and must not be inverted / 順序不能顛倒**

1. Create a ServiceAccount and Role granting only what deploys actually need:
   `get`/`patch` on the app Deployments, `create` on Secrets in its own
   namespace, `get` on pods and logs.
   *建 ServiceAccount 與 Role,只給部署真正需要的動詞。*
2. Generate a kubeconfig from that SA and place it at `~opc/.kube/config` —
   kubectl reads that path by default, so **none of the four deploy scripts need
   editing**.
   *用該 SA 產一份 kubeconfig 放到 `~opc/.kube/config` —— kubectl 預設就讀這裡,所以
   四個部署腳本一行都不用改。*
3. **Run all four app deploys end to end against the scoped kubeconfig** to prove
   the RBAC is not under-scoped.
   ***用這份受限 kubeconfig 實際跑過四個 app 的完整部署**,確認 RBAC 沒給太少。*
4. Only then: `sudo chmod 600 /etc/rancher/k3s/k3s.yaml`.
   *全部通過之後,才 chmod 600。*

**Risk / 風險** — everything before step 4 is freely reversible. After step 4, a
single missing RBAC verb takes all four deploy paths offline simultaneously.
**Step 3 cannot be skipped.**

*第 4 步之前都可以隨時退回;第 4 步之後只要少給一個動詞,四個 app 的部署管道會同時
停擺。**第 3 步不能跳。***

---

## 4. Live facts measured on 2026-07-28

*2026-07-28 量測到的線上事實*

Recorded so the plan can be re-checked without re-running the inspection.

*記錄下來,之後可以不必重跑檢查就核對計畫。*

| Fact | Value |
|---|---|
| k3s version | `v1.36.2+k3s1` |
| k3s `--disable` flags | **none** → Traefik, servicelb and kube-router netpol all active |
| SELinux | `Enforcing`, `targeted`, containerd in `container_runtime_t`, no recent AVC denials |
| Node IP / subnet | `10.0.0.240` on `enp0s6`, `10.0.0.0/24` |
| Pod / Service CIDR | `10.42.0.0/16` / `10.43.0.0/16` |
| `rpcbind` | **active**, listening `0.0.0.0:111` and `[::]:111` |
| PSA labels | none on any of the 11 namespaces |
| NetworkPolicies | none anywhere |
| App uids | gelp 1000, transigen 1000, snoopy 0, lans-h-site 0, postgres 0 |
| postgres data dir | `drwxrwxrwx 0 0` on the PVC |
| lans-h-site base | Alpine nginx, binds `:80` |
| snoopy | no Service, no Ingress — outbound only |
| Apps using postgres | gelp, transigen, snoopy (all three carry `DATABASE_URL`) |
| Missing resource limits | postgres, lans-h-site, Traefik, cert-manager |
| Live usage | snoopy 107Mi, transigen 76Mi, gelp 60Mi, postgres 39Mi |

**App manifest ownership / app manifest 歸屬**

| App | Path on node | Owning repo |
|---|---|---|
| gelp | `/opt/gelp/deploy/k8s/base/app-deployment.yaml` | `gelp` |
| transigen | `/opt/transigen/deploy/k8s/base/app-deployment.yaml` | `transigen` |
| my_website | `/opt/my_website/k8s/deployment.yaml` | `my_website` |
| snoopy | `/opt/snoopy_home/deploy/k8s/base/deployment.yaml` | `snoopy_home` |
| postgres | `cluster/data-postgres/postgres.yaml` | **platform** |

---

## 5. Corrections to the audit and to the first draft of this plan

*對稽核報告與本計畫初稿的更正*

### 5.1 The audit implied platform owns the app manifests. It does not.

*稽核報告暗示 platform 擁有 app 的 manifest。並沒有。*

Finding #3's fix reads "add to every first-party pod spec…" as though it were one
change in this repo. Four of the five pod specs live in **sibling app repos**
(see §4). Only postgres is platform's. The item is therefore four repo changes
and four redeploys, not one platform commit — which is why it is split out as
B-5/B-6 here rather than being part of the platform-owned batch.

*第 3 項的修法寫成「在每個自有 pod spec 加上……」,好像是本 repo 的一次改動。五份 pod
spec 有四份在 **sibling app repo** 裡,只有 postgres 屬於 platform。所以這一項實際上是
四個 repo 的改動加四次重新部署,不是一次 platform commit —— 這也是本文把它拆成
B-5/B-6、而不放進 platform 自有那批的原因。*

### 5.2 The first NetworkPolicy draft left the node subnet reachable.

*NetworkPolicy 初稿讓節點子網仍然可達。*

The first version of rule 5 excluded only the pod and service CIDRs:

*第 5 條的初版只排除了 pod 與 service 網段:*

```yaml
except: [10.42.0.0/16, 10.43.0.0/16]     # ← 不完整
```

The node is `10.0.0.240/24`, which is in **neither**. Under that rule an app pod
could still reach `10.0.0.240:10250` (kubelet) and `10.0.0.240:6443` (the API
server's node port) — **exactly what audit finding #4 sets out to block**. The
API server's Service IP `10.43.0.1` was covered, but bypassing the Service and
addressing the node directly was not. The corrected list in B-3 adds
`10.0.0.0/24`.

*節點是 `10.0.0.240/24`,**兩個網段都不含**。照那條規則,app pod 仍然能連
`10.0.0.240:10250`(kubelet)與 `10.0.0.240:6443`(API server 的節點端口)——
**而這正是稽核報告第 4 項要擋的東西**。API server 的 Service IP `10.43.0.1` 有被擋到,
但繞過 Service 直接打節點 IP 沒有。B-3 的更正版加上了 `10.0.0.0/24`。*

> 🎯 **Interview / 面試考點** — worth telling as-is. Finding your own control gap
> before it ships, and being able to say *why* the first version was wrong
> (`ipBlock` filters on IP, and the node lives outside both cluster CIDRs), is a
> better signal than presenting a clean plan that was never wrong.
>
> *這件事值得照實講。在上線前發現自己控制措施的缺口、而且說得出初版**為什麼**錯
> (`ipBlock` 是以 IP 過濾,而節點在兩個叢集網段之外),比端出一份從來沒錯過的乾淨
> 計畫更有說服力。*

### 5.3 The kubelet probe source is the CNI gateway, not the node address.

*kubelet 探針的來源是 CNI 閘道,不是節點位址。*

The ingress rules were first written to admit `10.0.0.240/32` on the assumption
that kubelet probes arrive from the node's own address. The live pod logs show
otherwise:

*入向規則最初寫成放行 `10.0.0.240/32`,前提是 kubelet 探針從節點自己的位址發出。
線上 pod 日誌顯示並非如此:*

```
INFO aiohttp.access: 10.42.0.1 [...] "GET /health HTTP/1.1" 200 "kube-probe/1.36"
```

Probes arrive from **`10.42.0.1`**, the `cni0` bridge gateway. Both addresses are
now admitted. Note that probes kept working throughout — on this CNI,
host-originated traffic appears not to traverse the ingress enforcement path, so
this rule is defence-in-depth rather than load-bearing today. It becomes
load-bearing the moment that path changes, which is reason enough to have it
correct.

*探針來自 **`10.42.0.1`**,也就是 `cni0` 橋接閘道。現在兩個位址都放行。要注意的是探針
全程都正常 —— 在這個 CNI 上,host-originated 流量似乎不經過 ingress 強制路徑,所以這條
規則目前是縱深防禦而非承重規則。但路徑一改變它就是承重的,這就足以構成把它寫對的
理由。*

---

## 5A. Verification evidence — 2026-07-28

*驗證證據 — 2026-07-28*

**The control experiment.** Before `gelp` was policied and after `snoopy` was,
the same three targets were probed from each:

***對照實驗。** 在 `gelp` 尚未套政策、而 `snoopy` 已套之後,從兩者分別探測同樣三個目標:*

| Target | from `gelp` (no policy) | from `snoopy` (policied) |
|---|---|---|
| `10.0.0.240:10250` kubelet | **REACHABLE** | blocked |
| `10.0.0.240:6443` API server | **REACHABLE** | blocked |
| `10.43.0.1:443` API service | **REACHABLE** | blocked |

This is the empirical proof of audit finding #4 — the flat pod network was not a
theoretical concern; any app pod really could reach the kubelet and the API
server. After policying, from `gelp`:

*這是稽核報告第 4 項的實證 —— 扁平的 pod 網路不是理論顧慮,任何 app pod 真的連得到
kubelet 與 API server。套用政策後,從 `gelp` 測:*

| Target | Result |
|---|---|
| `postgres.data.svc:5432` | REACHABLE ✅ *應通* |
| `www.googleapis.com:443` | REACHABLE ✅ *應通* |
| `10.0.0.240:10250` kubelet | blocked ✅ |
| `10.0.0.240:6443` API server | blocked ✅ |
| **`10.42.0.15:8080` snoopy's pod** | **blocked ✅** *跨 app 橫向移動被阻斷* |

**PSA warn, demonstrated.** A server-side dry-run of gelp's own pod spec into its
now-labelled namespace:

***PSA warn 的實證。** 把 gelp 自己的 pod spec 用 server-side dry-run 丟進已標記的
namespace:*

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false …
pod/warn-check created (server dry run)          # ← 警告了,但仍然放行
```

The warning fires and the pod is still admitted — which is the entire point of
`warn` over `enforce`.

*警告出現,pod 仍然被接受 —— 這正是選 `warn` 而不選 `enforce` 的全部意義。*

**Service continuity / 服務連續性** — throughout B-1 to B-3: `lans-h.cc` 200,
`gelp.lans-h.cc` 302 (auth redirect, expected), `transigen.lans-h.cc` 200; all
five pods `1/1 Running` with no new restarts; all three apps still reach
Postgres.

*B-1 到 B-3 全程:三個站台回應正常,五個 pod 全部 `1/1 Running` 且無新增重啟,
三個 app 都仍連得到 Postgres。*

---

## 6. Interview question bank

*面試題庫*

Marked items above collected in one place, with what the answer must contain.

*把上面標記的考點集中起來,並列出答案必須包含什麼。*

| Likely question / 可能的問題 | The answer must contain / 答案必須包含 |
|---|---|
| "You mention Kubernetes hardening — what did you actually do?" | The audit came first, findings ranked with evidence; Phase B is in progress. **Never claim it is finished.** *先有稽核、發現排序並附證據;Phase B 進行中。**絕不能說已完成。*** |
| "How would you roll out a restrictive admission policy without breaking a live cluster?" | `warn` → collect → fix manifests → `enforce`; because admission control fails at the *next pod creation*, not at apply time (§1.4). *因為 admission control 是在下一次 pod 建立時失敗,不是 apply 當下。* |
| "What is Pod Security Admission?" | Built-in validating admission controller, namespace labels, 3 levels × 3 modes, **validates but does not mutate**, and its ceiling — no network, no image provenance, no custom rules (§1.1). |
| "Isn't that basically SELinux?" | Similar in discipline, different in kind: admission-time declaration check vs runtime kernel enforcement; **PSA enforces nothing, it checks that you asked for enforcement** (§1.2). |
| "Your pod already runs as non-root — why did the policy reject it?" | PSA reads the manifest, not the image; the kubelet is what resolves `USER` at start (§1.3). This is the question that separates people who ran the tool from people who understand it. *這題能分辨「用過工具」和「理解工具」的人。* |
| "How do you isolate tenants on shared infrastructure?" | Two layers, and say so in that order: per-app database + LOGIN-only least-privilege role + `REVOKE CONNECT … FROM PUBLIC`, verified by the provisioning script — **then** NetworkPolicy for reachability (§B-3). |
| "Talk me through a control you got wrong." | The `ipBlock except` gap (§5.2). |
| "What would you do next / what is still open?" | Phase C — secrets encryption at rest (staging has it, production does not), API-server audit logging, host firewall for 6443/10250. Phase D — Trivy, gitleaks, Dependabot, and the 61 pending errata. |

> ⚠️ **Standing honesty guardrail / 誠實護欄** — until B-1 through B-4 are
> actually applied, the truthful phrasing is *"I audited it and I'm working
> through the remediation"*. Describing unfinished work honestly is safe;
> describing it as finished is what fails under follow-up.
>
> *在 B-1 到 B-4 真的套用之前,誠實的講法是「我稽核了,而且正在執行修復」。未完成的
> 工作誠實講完全沒問題,講成已完成才會在追問下出事。*
