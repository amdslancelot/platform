# Runbook — ownership handover & cutover

Incremental migration of shared infra from the app repos into this repo, on
the LIVE prod node, with zero downtime for snoopy. Each gate is independently
revertible; do them in order, verify, then move on. Principle throughout:
**apply-and-diff first, delete the old copy last.**

*把共用基礎設施從各 app repo 增量遷進本 repo,在正在運行的 prod 節點上進行,
snoopy 全程不中斷。每一關獨立可回退;照順序做、驗證、再前進。全程原則:
**先 apply+diff,最後才刪舊副本。***

## Gate 0 — the starting state (verify before touching anything)

The live node was bootstrapped by snoopy's runbook, which installed k3s with
`--disable traefik --disable servicelb` (the bot needed no ingress). Verify:
`kubectl -n kube-system get deploy traefik` → expected **NotFound** today.
Running there now: snoopy (ns `snoopy`) + shared Postgres (ns `data`).
gelp / transigen / my_website are NOT on this node yet.

*live 節點是 snoopy 的 runbook 建的,k3s 裝的時候帶了 `--disable traefik
--disable servicelb`(bot 不需要 ingress)。先驗證:`kubectl -n kube-system get
deploy traefik` → 現在預期 **NotFound**。目前跑著:snoopy + 共用 Postgres。
gelp / transigen / my_website 都還沒上這台。*

## Gate 1 — re-enable Traefik + servicelb

The fleet needs 80/443. Re-run the k3s installer without the disables — it
rewrites the systemd unit and restarts k3s; running pods (snoopy, Postgres)
survive a k3s restart (containerd keeps them):

```bash
sudo bash bootstrap/bootstrap-node.sh   # idempotent; also fine on a fresh node
kubectl -n kube-system rollout status deploy/traefik
```

Revert: re-run installer with the old `--disable` flags.

*機隊需要 80/443。重跑 k3s installer(拿掉 disable 旗標)——它重寫 systemd unit
並重啟 k3s;運行中的 pod(snoopy、Postgres)在 k3s 重啟時由 containerd 接著,
不會死。回退:帶原本的 `--disable` 旗標再跑一次 installer。*

## Gate 2 — OCI security list

Open ingress TCP **80, 443, 9000** (22 already open). See
`docs/security-list.md`. Revert: remove the rules.

*OCI security list 開 ingress TCP **80、443、9000**(22 本來就開)。*

## Gate 3 — Postgres ownership handover (no-op by construction)

The spec in `cluster/data-postgres/postgres.yaml` was copied byte-identical
from `snoopy_home/deploy/k8s/postgres.yaml`. Prove the handover changes
nothing, then make platform the applier of record:

```bash
kubectl diff -f cluster/data-postgres/postgres.yaml   # MUST show no changes
kubectl apply -f cluster/data-postgres/postgres.yaml  # no-op adoption
```

NEVER delete/recreate anything in ns `data` — the PVC holds all app data.
Deleting snoopy_home's copy of the file happens in Gate 7, not now.

*`cluster/data-postgres/postgres.yaml` 是從 snoopy_home 逐位元組複製的。先
`kubectl diff` 證明零變更,再 apply 完成「擁有權收養」。`data` namespace 裡的
東西**絕不**刪除重建——PVC 裡是所有 app 的資料。刪 snoopy_home 那份副本是
Gate 7 的事。*

## Gate 4 — TLS: cert-manager → Cloudflare DNS-01 → wildcard → Traefik default

Prereq: Cloudflare zone Active, grey-cloud A records for `@` and `*`
(`dns/records.md`), API token in hand.

```bash
bash cluster/cert-manager/install.sh                  # pinned install + next-steps
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f cluster/cert-manager/clusterissuer.yaml
kubectl apply -f cluster/namespaces.yaml
kubectl apply -f cluster/cert-manager/wildcard-certificate.yaml
kubectl -n platform get certificate lans-h-cc -w      # wait: READY True (≤ ~2 min)
kubectl apply -f cluster/traefik/tlsstore-default.yaml
kubectl apply -f cluster/traefik/www-redirect.yaml
```

Verify: `curl -sI https://anything.lans-h.cc` from outside → valid cert +
404; `curl -sI https://www.lans-h.cc/x` → `301` + `location: https://lans-h.cc/x`.

*前置:Cloudflare zone 已 Active、`@` 和 `*` 的灰雲 A 記錄設好、token 在手。
依序:裝 cert-manager → token Secret → ClusterIssuer → namespaces → wildcard
Certificate(等 READY)→ TLSStore → www redirect。驗證:對外 curl 任意子網域
是有效憑證 + 404;www 回 301 到 apex。*

## Gate 5 — webhook listener

```bash
sudo GELP_WEBHOOK_SECRET=... TRANSIGEN_WEBHOOK_SECRET=... \
     MY_WEBSITE_WEBHOOK_SECRET=... \
     bash bootstrap/install-webhook.sh
```

This renders `/etc/webhook/hooks.json` wholesale from `webhook/hooks.json` —
from now on that template is the only place hooks are defined; gelp's
setup-server.sh steps 7-9 and transigen's setup-app.sh step 4 are superseded.
The template must supply *every* secret it references, so re-running to add an
app (e.g. `deploy-my_website`, added 2026-07-26) means passing all three
secrets, not just the new one.

*這一步把 `/etc/webhook/hooks.json` 整份從 `webhook/hooks.json` 渲染出來——
從此 hooks 只定義在這份模板;gelp setup-server.sh 的 7-9 步和 transigen
setup-app.sh 的第 4 步同時作廢。*

## Gate 6 — app onboarding (each app's own repo drives its deploy)

Per app, in its own repo, now that platform provides the ground:

- **gelp** — clone to `/opt/gelp`; provision DB via
  `cluster/data-postgres/provision-db.sh` (`PROVISION_APPS="gelp"`); Ingress
  host → `gelp.lans-h.cc`; DELETE from its overlay: `clusterissuer.yaml`, the
  Ingress `tls:` patch and cert-manager annotation (wildcard default covers
  it); deploy.sh: drop the cert-manager install block (Gate 4 owns it) and the
  hooks steps (Gate 5 owns them).
- **transigen** — same shape: `/opt/transigen`; `PROVISION_APPS="transigen"`
  (its DB may already exist — the ROTATE guard makes re-running safe); host →
  `transigen.lans-h.cc`; setup-app.sh keeps only repo-clone + deploy.env +
  env.prod; its provision-db.sh and hook-append are superseded by platform.
- **GitHub webhook Payload URL** — use the DNS name, not the raw IP:
  `http://deploy.lans-h.cc:9000/hooks/deploy-gelp` (gelp) and
  `http://deploy.lans-h.cc:9000/hooks/deploy-transigen` (transigen). No new
  Cloudflare record needed — `deploy.lans-h.cc` already resolves via the
  existing `*.lans-h.cc` wildcard. Stays `http://`, not `https://`: `:9000`
  is not behind Traefik/TLS. Hook ids in `webhook/hooks.json` are
  `deploy-<app>` uniformly (gelp used to be bare `deploy`, renamed for
  consistency before any real GitHub webhook pointed at it).
- **my_website** — Ingress host `lans-h.ai` → `lans-h.cc`; drop any `www` in
  favour of the platform redirect; its k8s manifests currently land in ns
  `default` (works; `web` ns move is optional cleanup); DEPLOY.md's
  docker+k3s install section is superseded by `bootstrap/bootstrap-node.sh`
  (note: node uses podman — the build needs `podman save --format
  docker-archive`). Onboarded 2026-07-26 first on a git-poll systemd timer,
  then switched to the shared webhook listener (added a `deploy-my_website`
  hook here + `deploy/deploy.sh` in its repo, retired the poll timer) so all
  push-driven apps share one mechanism.
- **snoopy** — nothing to do. Stays zero-inbound; SSH+tag CI unchanged.

*各 app 在自己的 repo 裡上車:gelp/transigen 把 Ingress host 換成正式子網域、
刪掉自己的 clusterissuer / tls patch / cert-manager 註解(wildcard 預設憑證已
涵蓋)、deploy 腳本裡的 cert-manager 安裝與 hooks 步驟改由 platform 負責;DB
用 platform 的 provision-db.sh 開通(ROTATE guard 保證重跑安全)。GitHub
webhook 的 Payload URL 用網域名稱 `deploy.lans-h.cc:9000/hooks/deploy-<app>`
而非裸 IP,靠既有的 `*.lans-h.cc` wildcard 就能解析,不用加新 DNS 記錄;仍是
`http://` 不是 `https://`(:9000 沒走 Traefik/TLS)。hook id 統一成
`deploy-<app>`(gelp 原本是裸的 `deploy`,趁還沒接上真的 GitHub webhook 先
改掉)。my_website 把 host 從 lans-h.ai 換成 lans-h.cc,注意節點用 podman 不
是 docker(build 要 `podman save --format docker-archive`);2026-07-26 先用
git-poll 上車,之後改接共用 webhook(這裡加 `deploy-my_website` hook、repo 裡加
`deploy/deploy.sh`、退掉 poll timer),讓所有 push 觸發的 app 共用同一套機制。
snoopy 什麼都不用做。*

## Gate 7 — retire the moved copies

Only after every gate above is verified live:

- `snoopy_home`: delete `deploy/k8s/postgres.yaml`; point its runbook at this
  repo for Gates it no longer owns (Postgres, node bootstrap).
- `gelp`: delete the cert-manager/hooks/webhook-install parts of
  setup-server.sh + deploy.sh, `deploy/webhook/`, prod overlay
  `clusterissuer.yaml`.
- `transigen`: delete `deploy/provision-db.sh`, `deploy/webhook/`, the
  hook-append and DB-provision steps of setup-app.sh.
- `my_website`: replace DEPLOY.md's install sections with a pointer here.

*全部關卡驗證完、platform 確定是 live source 之後,才回頭刪各 app repo 裡被
搬走的副本,並把它們的文件指到這裡。*

## Pending (deliberate, not yet done)

- **Tag-gate flip for gelp/transigen** (`v*` → prod): change both hook rules
  in `webhook/hooks.json` from `refs/heads/main` (value match) to a regex
  match on `^refs/tags/v`, AND change each app's deploy.sh to check out the
  pushed tag instead of pulling main. Shipped together, per app. Until then
  they stay push-to-main (current live behaviour, deliberately preserved
  through the migration).
- **my_website `web` namespace** move (cosmetic).
- **Staging mirror** (minikube) of Gates 3-4; staging is also the future
  GitOps (Argo CD) lab — out of scope here.
- **DB password store**: platform keeps the roster's passwords in a local
  gitignored `secrets.env` for now; SOPS/sealed-secrets is a candidate later.

*待辦(刻意留到之後):gelp/transigen 的 tag-gate 切換(hooks 規則 + 各自
deploy.sh 改 checkout tag,兩者一起出);my_website 搬 `web` namespace(裝飾性);
staging 鏡像與 GitOps 實驗;DB 密碼改用 SOPS/sealed-secrets。*
