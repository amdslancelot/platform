# Platform topology — narrative & design trade-offs

*平台拓樸 — 敘事框架與設計取捨(草稿,供審閱)*

This is a **draft for review**. It defines how both topology diagrams should
*read* — the framing (a reusable platform, not a personal project) and the
trade-off note to attach to each technical choice. Once you're happy with the
angle, I apply it to both HTML versions (public/interview + internal canonical).

*這是**供審閱的草稿**。它定義兩份 topology 圖該怎麼「讀起來」——切入角度(一個可通用
共用的 platform,而非個人專案),以及每個技術選擇要附上的取捨說明。你確認角度後,我再
套用到兩份 HTML(公開/面試版 + 內部 canonical 版)。*

---

## 1. Positioning — the reframe

*定位 — 重新框架*

**Framing concept:** this is a **ground-up re-imagining of platform
infrastructure** — what I'd build if the platform were mine to design, drawing
on **10+ years of engineering**. Not "here are my hobby apps"; it's a considered
take on the platform/app contract, shown at small scale.

*框架概念:這是一次**從頭 re-imagine platform infrastructure** —— 以 **10+ 年工作
經驗**,設想「如果這個 platform 是我自己來設計,會怎麼設計」。不是「這是我的興趣小專案」,
而是對 platform/app 契約的深思熟慮版本,只是以小規模呈現。*

**Old angle (avoid):** "I run four of my apps on one box."
**New angle:** "I built a small **platform layer** that any number of apps can
stand on — one source of truth for the shared infrastructure (cluster, ingress,
TLS, database, deploy plane), with real per-app isolation and a near-zero-cost
onboarding path for the next app."

*舊角度(要避免):「我把自己四個 app 跑在一台機器上。」*
*新角度:「我做了一層小型 **platform** —— 任意數量的 app 都能站在上面:共用基礎設施
(叢集、ingress、TLS、資料庫、部署層)有單一真相來源,app 之間有真正的隔離,而且接入
下一個 app 幾乎零成本。」*

The headline claim to make everywhere: **the platform owns everything two or
more apps stand on; an app only declares its own thin slice** — a namespace, a
`Host(...)` rule, an additive DB role, one webhook hook. Adding app #5 needs
**no new cluster-wide plumbing**. That is the platform-engineering / internal
developer platform (IDP) pattern, just at small scale.

*到處都要傳達的主張:**平台擁有「兩個以上 app 共同踩著」的一切;app 只宣告自己的薄薄
一層** —— 一個 namespace、一條 `Host(...)` 規則、一個附加式 DB 角色、一個 webhook
hook。接第 5 個 app **不需要任何新的叢集層基礎設施**。這正是 platform-engineering /
內部開發者平台(IDP)的模式,只是小規模版本。*

Concrete "reusable / generic" proof points to surface:

*要凸顯的「可通用 / 可重用」具體證據:*

- **Onboarding is additive, not bespoke.** New app = namespace + `Host(...)` +
  `PROVISION_APPS=<app>` (existing roles untouched) + one hook. No bootstrap,
  no cert setup, no registry credentials.
  *接入是附加式、非客製化。新 app = namespace + `Host(...)` + `PROVISION_APPS=<app>`
  (不動既有角色)+ 一個 hook。不用 bootstrap、不用設憑證、不用 registry 帳密。*
- **The app contract is portable.** The same manifests + contract would run on a
  multi-node cluster or a managed Kubernetes with no app-side change — this
  instance being small is an implementation detail, not the design.
  *app 契約可移植。同一套 manifest + 契約放到多節點叢集或託管 Kubernetes 都不用改 app
  端 —— 這個實例很小只是實作細節,不是設計本身。*

---

## 2. Component-by-component: page copy + trade-off

*逐元件:頁面文案 + 取捨*

For each element: **Page copy (EN)** is what appears on the diagram; **Trade-off
/ 設計取捨** is the "why this, what it buys" note (this is the part you asked to
add). `[public]` / `[internal]` marks where the two versions differ.

*每個元件:**Page copy (EN)** 是圖上顯示的英文文案;**Trade-off / 設計取捨** 是「為何
這樣、換到什麼好處」的說明(這就是你要補的部分)。`[public]` / `[internal]` 標示兩版
差異處。*

### 2.1 One shared cluster

*一個共用叢集*

- **Page copy (EN):** `[public]` "shared Kubernetes cluster" ·
  `[internal]` "single-node k3s (Traefik enabled, kubeconfig 644)".
- **Trade-off / 設計取捨:** A single shared cluster is one failure domain with
  no HA — but it removes per-app cluster cost/ops entirely and *forces* clean
  multi-tenancy (namespaces + per-app DB roles) instead of letting it slide. The
  isolation model is what's reusable; the node count is swappable.
  *單一共用叢集是一個故障域、沒有 HA —— 但它完全省掉每個 app 各自建叢集的成本與維運,並
  且「逼」你把多租戶隔離(namespace + 每 app DB 角色)做乾淨,而不是敷衍過去。可重用的
  是隔離模型;節點數量是可替換的。*
- **Benefit:** the tenancy contract scales even if this instance doesn't — move
  to N nodes without touching the app contract.
  *好處:即使這個實例不擴,租戶契約本身可擴 —— 換成 N 節點也不動 app 契約。*

### 2.2 Platform repo as single source of truth

*platform repo 作為單一真相來源*

- **Page copy (EN):** "A single `platform` repo is the source of truth for
  shared infrastructure … app repos own their own build + deploy — only what two
  or more apps stand on lives here."
- **Trade-off / 設計取捨:** The original problem was shared infra *squatting* in
  whichever app repo needed it first (Postgres in one app, cert-manager buried
  in another app's deploy script) → duplication + unclear ownership. A central
  repo adds one coordination point, but draws a hard platform/app boundary.
  *原本的問題是共用基礎設施「寄居」在最先需要它的那個 app repo(Postgres 在某 app、
  cert-manager 埋在另一個 app 的部署腳本裡)→ 重複 + 歸屬不清。中央 repo 多了一個協調
  點,但劃出明確的 platform/app 邊界。*
- **Benefit:** apps stay thin, bootstrap isn't duplicated, ownership is
  unambiguous — the precondition for self-service onboarding.
  *好處:app 保持精薄、bootstrap 不重複、歸屬清楚 —— 這是自助接入的前提。*

### 2.3 No image registry — build on node, import into containerd

*無 image registry —— 在節點 build、import 進 containerd*

- **Page copy (EN):** "podman build on the node → import into the cluster's
  containerd → `imagePullPolicy: Never` with `localhost/<app>` names".
- **Trade-off / 設計取捨:** No registry means no cross-machine image
  history/promotion and build load sits on the node; but it removes an entire
  piece of infra to run, secure, and pay for, plus any pull credentials.
  `localhost/<app>` + `Never` guarantees the exact locally-built image runs and
  never silently pulls `docker.io/library/<app>`.
  *沒有 registry 代表沒有跨機器的 image 歷史/晉級,build 負載也落在節點上;但省掉一整
  塊要維運、要保護、要付費的基礎設施,以及 pull 憑證。`localhost/<app>` + `Never`
  保證跑的是本地 build 的那個 image,不會偷偷去 pull `docker.io/library/<app>`。*
- **Benefit:** simplest possible supply chain for a small fleet; swap in a
  registry (GHCR) later with no app-contract change.
  *好處:小機隊最簡單的供應鏈;日後要換 registry(GHCR)也不動 app 契約。*

### 2.4 Wildcard cert as Traefik's default cert

*wildcard 憑證作為 Traefik 預設憑證*

- **Page copy (EN):** "wildcard `*.lans-h.cc` = default cert · `Host(...)`
  routing · no per-app TLS block".
- **Trade-off / 設計取捨:** One wildcard is a single cert (bigger blast radius if
  it leaks, and no per-app cert policy) — but apps declare **zero** TLS config,
  and every new subdomain gets valid TLS automatically.
  *一張 wildcard 是單一憑證(外洩的影響範圍較大,也無法做每 app 的憑證政策)—— 但 app
  完全不用寫 TLS 設定,而且每個新子網域自動就有有效 TLS。*
- **Benefit:** TLS becomes a platform concern, not an app concern; per-app
  boilerplate drops to a single `Host(...)` rule.
  *好處:TLS 變成平台的事、不是 app 的事;每 app 的樣板降到只剩一條 `Host(...)`。*

### 2.5 Shared Postgres, per-app least-privilege roles, db-per-app

*共用 Postgres、每 app 最小權限角色、db-per-app*

- **Page copy (EN):** `[public]` "reachable only inside the cluster; each app
  holds a least-privilege role scoped to its own database" · `[internal]` adds
  "`PUBLIC` connect revoked · no TLS (traffic never leaves the node)".
- **Trade-off / 設計取捨:** A shared server is a shared resource/failure domain —
  but a per-app `<app>_rw` role scoped to its own database (with `PUBLIC` connect
  revoked) gives real tenant isolation without paying for N database servers.
  Provisioning is additive (`PROVISION_APPS`) so it never touches another app's
  role. `[internal]` TLS is intentionally off because DB traffic never leaves the
  trusted node — don't read that as a gap.
  *共用伺服器是共用資源/故障域 —— 但每 app 一個 `<app>_rw` 角色、範圍限自己的 database
  (且撤銷 `PUBLIC` connect),就能在不付 N 台資料庫伺服器的成本下得到真正的租戶隔離。
  Provisioning 是附加式(`PROVISION_APPS`),不會動到別的 app 的角色。`[internal]` TLS
  刻意關閉,因為 DB 流量不出信任的節點 —— 不要當成缺口解讀。*
- **Benefit:** strong isolation at low cost; additive, non-destructive
  onboarding of the next app's DB.
  *好處:低成本的強隔離;接下一個 app 的 DB 是附加、非破壞式的。*

### 2.6 Deploy plane — signed webhook, per-app trigger, two orthogonal gates

*部署層 —— 簽章 webhook、每 app 觸發、兩條正交的 gate*

- **Page copy (EN):** the triggers strip + "test-gate / release-gate" axes;
  `[public]` "signed deploy webhook" (no port/HMAC header shown), `[internal]`
  shows `:9000` + `X-Hub-Signature-256`.
- **Trade-off / 設計取捨:** Heterogeneous triggers (Actions-SSH / CI→webhook /
  native webhook) look inconsistent — but each app keeps the trigger that fits it
  while sharing ONE deploy mechanism (a signed webhook → per-app
  `deploy.sh`: fetch → build → import → rollout). The key idea is separating
  **trigger** (how a deploy is kicked off) from **gate** (test-gate = build must
  pass; release-gate = `v*` tag only) — two orthogonal axes you mix per app.
  *異質的觸發(Actions-SSH / CI→webhook / 原生 webhook)看起來不一致 —— 但每個 app 保留
  最適合自己的觸發方式,同時共用同一套部署機制(簽章 webhook → 各 app 的 `deploy.sh`:
  fetch → build → import → rollout)。關鍵是把 **trigger**(部署怎麼被啟動)和 **gate**
  (test-gate = build 必須過;release-gate = 只有 `v*` tag)分開 —— 兩條正交軸,每 app
  自由組合。*
- **Benefit:** one shared, auditable deploy path; security is the HMAC secret
  (not TLS); gating policy is per-app and independent of the trigger.
  *好處:一條共用、可稽核的部署路徑;安全靠 HMAC secret(非 TLS);gate 政策每 app 獨立、
  與觸發方式解耦。*

### 2.7 Push-to-deploy now, GitOps (Argo CD) later — staging is the lab

*現在 push-to-deploy、之後 GitOps(Argo CD)—— staging 當實驗場*

- **Page copy (EN):** the STAGING box + "Future: GitOps lab — Argo CD,
  pull-reconcile, self-heal, replaces push-to-deploy".
- **Trade-off / 設計取捨:** Push-to-deploy is imperative and can drift; GitOps
  (pull-reconcile) self-heals and resists drift but adds a controller + a
  registry + operational complexity. Keeping prod lean and proven *now*, while
  proving GitOps in a local staging mirror (where `reset` makes mistakes free),
  is a deliberate sequencing — not an absence of the idea.
  *push-to-deploy 是命令式、會漂移;GitOps(pull-reconcile)會自我修復、抗漂移,但多了
  一個 controller + registry + 維運複雜度。現在讓 prod 保持精簡且已驗證,同時在本地
  staging 鏡像裡驗證 GitOps(在那裡「reset」讓犯錯零成本)—— 這是刻意的排序,不是沒想到。*
- **Benefit:** you can talk to push-vs-pull, self-heal / anti-drift, and a
  credible migration path — with staging mirroring prod so the promotion is real.
  *好處:你能談 push vs pull、self-heal / anti-drift,以及可信的遷移路徑 —— 而且 staging
  鏡像 prod,晉級是真的。*

### 2.8 Namespace-per-app isolation

*每 app 一個 namespace 的隔離*

- **Page copy (EN):** the `ns: <app>` labels on each workload box.
- **Trade-off / 設計取捨:** Minimal downside; a namespace per app gives clean
  blast-radius boundaries and an RBAC surface, and *is* the onboarding contract
  ("your app gets a namespace").
  *幾乎沒有壞處;每 app 一個 namespace 帶來乾淨的影響範圍邊界與 RBAC 面,而且它本身就是
  接入契約(「你的 app 會拿到一個 namespace」)。*

---

## 3. What changes in each version

*每一版會怎麼改*

- **Public / interview** (`my_website/public/topology.html`): apply the
  reframed headline + footer, and add a short trade-off caption under the
  relevant boxes (kept terse for the diagram). Stays redacted (no IP / port /
  HMAC header / DB-no-TLS).
  *公開/面試版:套用重寫後的標題 + footer,並在相關框下加一句精簡的取捨字幕(圖上保持
  簡短)。維持遮蔽(無 IP / 埠 / HMAC header / DB 無 TLS)。*
- **Internal canonical** (`platform/docs/topology.html`): same reframe, keeps
  the precise `k3s` / `:9000` / `X-Hub-Signature-256` / no-TLS specifics, and can
  carry the fuller trade-off text since it's not published.
  *內部 canonical 版:同樣重寫框架,保留精確的 `k3s` / `:9000` / `X-Hub-Signature-256`
  / 無 TLS 細節,而且因為不公開,可以承載更完整的取捨文字。*

**Open question for you / 待你決定:** on the *diagram* itself, how much
trade-off text do you want inline? Options: (a) keep the diagram clean and put
trade-offs only in the legend cards; (b) one short "why" line under each infra
box; (c) a dedicated "Design trade-offs" card block below the legend. My
suggestion: **(c)** for the public version (a compact "Why it's built this way"
card grid) + **(a/b)** minimal inline — keeps the picture readable while the
trade-offs are what an interviewer actually reads.

*待你決定:在**圖上**你想要多少取捨文字?(a) 圖保持乾淨,取捨只放在 legend 卡片;
(b) 每個 infra 框下一句「why」;(c) legend 下方另開一組「Design trade-offs」卡片。我的
建議:公開版用 **(c)**(一組精簡的「Why it's built this way」卡片)+ **(a/b)** 少量
inline —— 讓圖好讀,而取捨是面試官真正會讀的部分。*
