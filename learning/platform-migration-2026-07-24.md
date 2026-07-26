# Platform migration log — shared k3s node cutover

Command-led runbook of executing `docs/runbook.md` on the prod node (`louis2`,
OCI A1.Flex, 92.5.135.46). Each task states its **goal**, gives the commands with
an inline `#` note on every line, and states the **expected result**; problems are
recorded as **問題 → 解法** right before the fix.

*在 prod 節點執行 `docs/runbook.md` 的指令實錄。每個任務先講**目標**,指令每行都有
`#` 註解說明功能,後面接**預期結果**;遇到問題就在修復前記「問題 → 解法」。*

## Status board / 進度看板

| Gate | 內容 | 狀態 | 完成 (GMT) |
|---|---|---|---|
| 0 | 起點驗證(節點只有 snoopy + Postgres,無 Traefik) | ✅ | 2026-07-24 |
| 1 | 重新啟用 Traefik + servicelb | ✅ | 2026-07-24 |
| 2 | OCI security list 開 80/443/9000 | ✅ | 2026-07-24 |
| 3 | Postgres no-op 擁有權交接 | ✅ | 2026-07-24 |
| 4 | TLS 全鏈(cert-manager → Cloudflare DNS-01 → wildcard → Traefik 預設憑證) | ✅ | 2026-07-24 |
| 5 | webhook listener (:9000) | ✅ | 2026-07-25 |
| 6 | app 上車(gelp ✅ / transigen ✅ / my_website 🟡) | 🟡 | gelp+transigen done |
| 7 | 清理各 app repo 舊副本 | ⬜ | — |

## Outstanding / 未結事項

| ☐ | 項目 |
|---|---|
| ☐ | Cloudflare API token 曾在對話明文出現 → 全部完成後 **Roll** 新值 + 更新 `cloudflare-api-token` Secret |
| ☐ | 清掉 Cloudflare 殘留的 `_acme-challenge` TXT 記錄(純衛生) |
| ☐ | Gate 6 my_website 收尾(apply manifests → timer → 首次 build → 驗證) |
| ☐ | Gate 7:退休各 app 的舊 `setup-server.sh` / `setup-app.sh` 等節點級腳本 |
| ☐ | tag-gate flip:gelp/transigen 由 push-to-main 改為 `v*` tag(對齊 snoopy) |
| ☐ | 可選加固:`shred -u /opt/<app>/.env.prod` |

---

## Day 1 (2026-07-24) — Gates 0–4

### Gate 0+1 — bootstrap-node.sh(重新啟用 Traefik/servicelb)

**目標 / Goal:** the node was installed with `--disable traefik --disable servicelb`
(snoopy era); re-run the installer without those flags so it can serve 80/443,
without disturbing the running snoopy/postgres pods.
*節點當初裝了 `--disable traefik/servicelb`,重跑 installer 拿掉旗標讓它能服務
80/443,且不動到執行中的 snoopy/postgres。*

```bash
sudo bash bootstrap/bootstrap-node.sh   # 升級套件 + 重跑 k3s installer(unit 重寫、去掉 disable 旗標)+ 重啟 k3s
```

**問題 1 / Problem:** the script queried `rollout status` right after the node was
Ready, but k3s deploys Traefik asynchronously via helm-controller (~30–90s later)
→ `deployments.apps "traefik" not found`. *腳本在節點 Ready 後立刻查 rollout,但
Traefik 是非同步部署,NotFound 是競態非失敗。*
**解法 / Fix:** wait-loop for the Deployment to exist before the rollout check
(commit `769b3f6`). *先等 Deployment 存在再查。*

**問題 2 / Problem:** `opc` running kubectl → permission denied (`Unable to read
.../k3s.yaml`); the script had carried over `chmod 600` from gelp's root-centric
setup, clashing with this node's `--write-kubeconfig-mode 644`. *腳本盲搬 gelp 的
`chmod 600`,與本節點刻意的 644 衝突。*
**解法 / Fix:** restore 644 on the node + delete the chmod line from the script
(commit `c942415`). *節點復原 644,腳本刪掉該行。*

```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml   # 復原 installer 設的 644,讓 opc / CI 能直接跑 kubectl
```

**工作 / Verify — confirm Traefik is back and existing pods untouched:**

```bash
grep -c "disable" /etc/systemd/system/k3s.service          # 期望 0:確認 disable 旗標已消失
kubectl -n kube-system get jobs                            # helm-install-traefik 應為 Complete
kubectl -n kube-system get deploy traefik                  # 應為 1/1 Available
kubectl -n kube-system get svc traefik                     # 應是 LoadBalancer,綁 80/443
kubectl -n kube-system get pods | grep -E "traefik|svclb"  # traefik + svclb 都 Running
kubectl -n snoopy get pods                                 # snoopy 仍 Running(AGE 29h,沒被重啟)
kubectl -n data get pods                                   # postgres 仍 Running(AGE 31h)
```

**預期 / Expect:** disable 計數為 0、Traefik Deployment 1/1、snoopy/postgres 的 AGE
不歸零(證明 k3s 重啟沒重建它們)。*一切 green 即 Gate 0+1 完成。*

### Gate 2 — OCI security list(在雲端 console 開 80/443)

**目標 / Goal:** open ingress TCP 80/443 in the OCI security list so the internet
can reach Traefik, and prove the whole path end-to-end.
*在 OCI security list 開 80/443,讓外網能到 Traefik,並驗證整條路。*

```bash
curl -sk https://92.5.135.46 -o /dev/null -w "%{http_code}\n"   # 從 Mac 打節點 public IP,-k 因為此刻還是自簽佔位憑證
```

**預期 / Expect:** `404`. That means internet → security list → svclb → Traefik is
fully wired (404 = reached Traefik, just no route yet). *拿到 404 代表全線通(打到
Traefik 了,只是還沒有路由規則)。*

### Gate 3 — Postgres no-op 擁有權交接

**目標 / Goal:** make the `platform` repo the applier-of-record for the shared
Postgres, proving it's a byte-for-byte no-op so zero data risk. *讓 platform repo
成為共用 Postgres 的唯一管理來源,先證明是零變動 no-op、資料零風險。*

```bash
kubectl diff -f cluster/data-postgres/postgres.yaml && echo "NO-OP CONFIRMED"   # diff 零輸出=platform 版本與線上完全一致
kubectl apply -f cluster/data-postgres/postgres.yaml                            # 正式接管(預期四項全 unchanged)
```

**預期 / Expect:** `NO-OP CONFIRMED` (empty diff), then apply reports all resources
`unchanged`. *diff 空、apply 全 unchanged,交接完成、資料沒動。*

### Gate 4 — TLS 全鏈(cert-manager → Cloudflare DNS-01 → wildcard)

**目標 / Goal:** issue one `*.lans-h.cc` (+apex) wildcard cert via cert-manager +
Cloudflare DNS-01, set it as Traefik's default cert so every host gets HTTPS
automatically. *用 cert-manager + Cloudflare DNS-01 簽一張 `*.lans-h.cc` wildcard,
設為 Traefik 預設憑證,所有 host 自動有 HTTPS。*

```bash
bash cluster/cert-manager/install.sh   # 裝 cert-manager v1.15.3(3 個 deployment 應全 Available)
```

**問題 3 / Problem:** cert stuck READY False; log `6003/6111: Invalid format for
Authorization header`. The stored secret literally held the placeholder string
`<你的token>` (the create-secret command was run without substituting the real
token). *secret 存的是佔位符本身,當初沒換成真值。*
**解法 / Fix:** always verify the token against Cloudflare BEFORE storing it.
*token 一律先驗證再入庫。*

```bash
kubectl -n cert-manager get secret cloudflare-api-token \
  -o jsonpath='{.data.api-token}' | base64 -d | wc -c        # 檢查長度:應為 40,結果是 25 → 存錯了
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify    # 對 Cloudflare 驗證 token,期望 "success":true
# 驗證通過後重建 secret + rollout restart cert-manager
```

**問題 4 / Problem:** token fixed, but cert still False; log `DELETE
/zones//dns_records/... 7003` (empty zone id). A `rollout restart` done
mid-challenge (during fix #3) wiped cert-manager's in-memory zone cache. *修問題 3
時在 challenge 進行中重啟,洗掉 zone 快取,TXT 清理帶空 zone id 無限重試。*
**解法 / Fix:** delete the CertificateRequest so a clean order runs end-to-end.
Lesson: never `rollout restart` cert-manager mid-challenge. *刪 CertificateRequest
整輪重來;切勿在 challenge 中重啟 cert-manager。*

```bash
kubectl -n platform delete certificaterequest lans-h-cc-1   # 砍掉半途的請求,cert-manager 會自動開一張全新的 order
kubectl -n platform get certificate lans-h-cc               # 等它變 READY True
```

**工作 / Apply the last two pieces + acceptance test (from the Mac, no `-k`):**

```bash
kubectl apply -f cluster/traefik/tlsstore-default.yaml   # 把 wildcard 設為 Traefik 預設憑證
kubectl apply -f cluster/traefik/www-redirect.yaml       # www→apex 的 301 middleware

curl -sI https://test.lans-h.cc | head -1                # 任意子網域:期望 HTTP/2 404 且憑證有效(不用 -k)
curl -sI https://www.lans-h.cc/abc                       # 期望 301 → location: https://lans-h.cc/abc
curl -sI https://lans-h.cc | head -1                     # apex:期望 HTTP/2 404(有效憑證)
```

**預期 / Expect:** all three `curl` succeed **without `-k`** (valid cert), www 301s
to apex, unrouted names give a clean 404. Renewal is automatic. *三個 curl 不用 -k
就成功=憑證有效;www 301 回 apex;續簽全自動。Gate 4 完成。*

---

## Day 2 (2026-07-25) — Gate 5: webhook listener

**目標 / Goal:** install the adnanh/webhook listener on `:9000` so a GitHub push
can trigger a deploy; verify it's up locally and from the internet. Secrets are
passed only as one-shot sudo env vars, `unset` right after — never to history/disk.
*裝 webhook listener 在 :9000,讓 GitHub push 能觸發部署;本機+外網驗證。secret 只
在單一指令的 sudo 環境內短暫存在,結束立刻 unset。*

```bash
sudo GELP_WEBHOOK_SECRET="$GELP_WH" TRANSIGEN_WEBHOOK_SECRET="$TRAN_WH" \
  bash bootstrap/install-webhook.sh          # 裝 webhook 2.8.3 + 渲染 hooks.json + 起 systemd 服務,listener on :9000

systemctl status webhook                     # 應為 active (running), enabled
curl -s http://localhost:9000/hooks/deploy   # 本機打:應回 "Hook rules were not satisfied."
```

**工作 / External check (from the Mac):**

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://92.5.135.46:9000/hooks/deploy   # 外網可達性:期望 HTTP 200
curl -s http://92.5.135.46:9000/hooks/deploy                                          # 期望 "Hook rules were not satisfied."
```

**預期 / Expect:** "Hook rules were not satisfied" (no valid HMAC) proves the
listener is up **and evaluating rules**, not merely reachable. *這是沒帶正確 HMAC
的正確回應,證明規則有在跑判斷,不只是打得通。*

### Follow-up / 後續 — hook-id 一致性 + app repo 清理

**目標 / Goal:** gelp's hook id was bare `deploy` (only-app leftover) vs transigen's
`deploy-transigen` — make them consistent before any real webhook points at them.
*把 gelp 的裸 `deploy` 改成 `deploy-gelp`,與 `deploy-transigen` 一致,趁真 webhook
還沒接上先改。*

```bash
# Mac: 在 webhook/hooks.json 把 id 改成 deploy-gelp(commit a0463d3),然後節點重跑 installer:
sudo GELP_WEBHOOK_SECRET="$GELP_WH" TRANSIGEN_WEBHOOK_SECRET="$TRAN_WH" \
  bash bootstrap/install-webhook.sh
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy-gelp        # 期望 200(新路徑)
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy             # 期望 404(舊路徑已移除)
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy-transigen   # 期望 200(不受影響)
```

**預期 / Expect:** new path 200, old path 404, transigen path unaffected. Also
cleaned gelp+transigen `deploy.sh`/overlays (dropped per-app cert-manager +
ClusterIssuer + `tls:` patch; host hardcoded) since the platform wildcard now
covers every Ingress. GitHub Payload URL convention:
`http://deploy.lans-h.cc:9000/hooks/deploy-<app>` (DNS name resolved by the
wildcard; adnanh/webhook routes by path only, so ids must be globally unique).
*新路徑通、舊的 404;順便清掉兩 app 自帶的 TLS 設定(平台 wildcard 已涵蓋)。*

### transigen branch-hygiene 插曲

**問題 / Problem:** the deploy-fix commit accidentally landed on the local-only
`webaudio-playback` feature branch instead of `main`. *deploy fix 誤落在本機 feature
branch。*
**解法 / Fix:** cherry-pick the fix onto main; soft-reset the feature branch and
restore only the 3 deploy files, leaving its audio WIP untouched (branch never
pushed → safe). *cherry-pick 回 main;feature branch soft-reset 後只 restore 那 3 個
deploy 檔,audio WIP 沒動;branch 沒推過遠端,改寫安全。*

```bash
git checkout main && git cherry-pick c60619a9         # 把 deploy fix 搬到 main(→ c3319b68)
git checkout webaudio-playback && git reset --soft HEAD~1   # feature branch 退回 commit 前(改動留在工作區)
git restore --source=HEAD --staged --worktree -- \
  deploy/deploy.sh deploy/env.prod.example deploy/k8s/overlays/prod/kustomization.yaml   # 只還原這 3 個 deploy 檔
```

---

## Day 3 (2026-07-25) — Gate 6 gelp (LIVE)

**目標 / Goal:** put gelp live at `https://gelp.lans-h.cc` on the platform node —
clone, provision its DB, deploy, seed data. This shape (clone → provision → deploy)
is reused for every app. **Use a plain `git clone`, NOT `setup-server.sh`** (that
from-zero node builder would collide with what platform owns — it's Gate-7 fodder).
*讓 gelp 上線;上車套路(clone→provision→deploy)之後每個 app 重用。一律 plain clone,
不用會跟 platform 打架的 setup-server.sh。*

### 1. Clone as root(需要 per-app deploy key)

**目標 / Goal:** get the repo into `/opt/gelp`. The poll/webhook deploy runs as
**root**, which has no GitHub key — so root needs a per-app read-only deploy key.
*把 repo clone 到 /opt/gelp;部署以 root 身分跑、root 沒 GitHub key,故用 per-app
唯讀 deploy key。*

**問題 / Problem:** `sudo git clone` → `Permission denied (publickey)` (root has no
key). *root 沒 key。*

```bash
sudo git clone --branch main git@github.com:amdslancelot/gelp.git /opt/gelp
# → git@github.com: Permission denied (publickey).
```

**解法 / Fix:** generate a read-only deploy key for root, clone with it, then pin
it so future webhook-triggered `git pull`s use it too.

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/gelp_deploy_key -N "" -C "louis2-gelp-deploy"   # 產 root 專屬金鑰;-C 只是標籤
sudo cat /root/.ssh/gelp_deploy_key.pub          # 印出公鑰 → 貼到 gelp repo 的 Deploy keys(唯讀)
sudo GIT_SSH_COMMAND="ssh -i /root/.ssh/gelp_deploy_key -o IdentitiesOnly=yes" \
  git clone --branch main git@github.com:amdslancelot/gelp.git /opt/gelp   # 用這把 key clone
sudo git -C /opt/gelp config core.sshCommand \
  "ssh -i /root/.ssh/gelp_deploy_key -o IdentitiesOnly=yes"                 # 把 key 釘進 repo,之後 fetch/pull 自動用它
```

**預期 / Expect:** `/opt/gelp` cloned at main's tip. *clone 成功。*

### 2. Provision the DB

**目標 / Goal:** create the `gelp_rw` role + `gelp` database in the shared Postgres,
with the password matching `.env.prod`. *在共用 Postgres 建 `gelp_rw` 角色 + `gelp`
資料庫,密碼與 `.env.prod` 一致。*

**問題 / Problem:** the prod `gelp_rw` role already existed → the password was NOT
applied (`exists: role 'gelp_rw' — password untouched`). *角色已存在,密碼沒被套用。*
**解法 / Fix:** re-run with `ROTATE=1` (safe — nothing used the prod role yet). Use
a hex password to sidestep `DATABASE_URL` percent-encoding. *`ROTATE=1` 重跑;密碼用
hex 避開 URL 編碼坑。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="gelp" GELP_DB_PASSWORD="$GELP_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh          # 首跑:回報 "password untouched"(角色已存在)

kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="gelp" ROTATE=1 GELP_DB_PASSWORD="$GELP_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh          # 加 ROTATE=1 重跑:回報 "rotated"
```

**預期 / Expect:** first run says `untouched`, the `ROTATE=1` run says `rotated`.
*密碼已改成 .env.prod 的值。*

### 3. First manual deploy — 冒出 3 個 gelp 專屬 deploy.sh bug

**目標 / Goal:** run `deploy.sh` by hand once to validate the whole path
(build → import → rollout) before trusting the webhook. gelp's script predated
fixes transigen already had, so it surfaced 3 bugs. *手動跑一次 deploy.sh 驗證整條
路,再信任 webhook;gelp 腳本較舊,踩出 3 個 bug。*

```bash
cd /opt/gelp && sudo bash deploy/deploy.sh   # build 映像 → import 進 containerd → kubectl rollout
```

**問題 5 / Bug 1 — sudo secure_path:** `deploy.sh: line 61: k3s: command not found`.
`sudo` swaps PATH for `secure_path`, which on OL9 excludes `/usr/local/bin` (where
k3s lives). *sudo 的 secure_path 不含 /usr/local/bin。*
**解法 / Fix:** `export PATH="/usr/local/bin:$PATH"` atop deploy.sh (commit
`f002c33`); for interactive use, the full path `sudo /usr/local/bin/k3s`.

**問題 6 / Bug 2 — image name → ImagePull:** pod stuck "trying and failing to pull
image". podman builds `localhost/gelp:latest`, but the bare `gelp:latest` in the
pod spec normalizes to `docker.io/library/gelp:latest` → registry pull → fail.
*裸名被正規化成 docker.io,找不到就去 registry 拉。*
**解法 / Fix:** name the prod image `localhost/gelp` via the overlay `images:
newName` (commit `396fe8a`) — honest, and containerd never pulls a `localhost` host.

```bash
kubectl -n gelp logs deploy/gelp   # 診斷:應看到 "waiting to start: trying and failing to pull image"
# 兩個 fix 都在 Mac 改好、git push → webhook 自動 redeploy
```

**工作 / Verify — bug 1 也會咬互動指令,改用全路徑:**

```bash
sudo k3s ctr images ls | grep gelp                  # → sudo: k3s: command not found(同一個 secure_path 坑)
sudo /usr/local/bin/k3s ctr images ls | grep gelp   # 用全路徑:應列出 localhost/gelp(+ 殘留的 docker.io/library/gelp)
kubectl -n gelp get pods                            # 應為 gelp-... 1/1 Running
curl -sI https://gelp.lans-h.cc | grep -i location  # 應為 location: https://gelp.lans-h.cc/login(未登入導向)
sudo /usr/local/bin/k3s ctr images rm docker.io/library/gelp:latest   # 清掉 debug 過程留下的中間映像
```

**預期 / Expect:** pod `1/1 Running`, curl 302→`/login`, only `localhost/gelp` left
in containerd. *pod 正常、導向登入頁、映像乾淨。*

### 4. Data seed — Takeout 重傳(不是 pg_dump)

**目標 / Goal:** get gelp's real data into prod. **Decision:** the TODO's `pg_dump`
from a `gelp-pgdata` volume was moot (volume gone; app never really on prod), so
instead re-upload the Google Takeout zip via the app's own `/import`, which
auto-scopes to the logged-in user — zero DB surgery. *把真實資料灌進 prod;改用 app
的 /import 重傳 Takeout,自動歸給登入者,不動 DB。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d gelp -c "select id, email, google_sub from users;"   # 先確認 prod user(登入後才會有這列)
# → ee55ef4e-...  lansoulot@gmail.com

# ... 在 https://gelp.lans-h.cc/import(已登入)上傳 Takeout zip ...

kubectl -n data exec -i deploy/postgres -- psql -U postgres -d gelp \
  -c "select count(*) from lists;" -c "select count(*) from places;" \
  -c "select count(*) from places where cache_key is not null;" \
  -c "select count(*) from place_cache;"   # 匯入後逐表計數驗證
```

**預期 / Expect:** `70 lists / 5469 places / 5469 enriched / 5350 cached` — full
Places-API enrichment worked. gelp LIVE. *全數 enrich,gelp 上線。*

---

## Day 4 (2026-07-26) — Gate 6 transigen (LIVE)

**目標 / Goal:** put transigen live at `https://transigen.lans-h.cc` and migrate its
existing data. The 3 gelp fixes (PATH export, `localhost/transigen` image,
`.env.prod` dotfile) were pre-applied on the Mac, so deploy → `Running 1/1` first
try; the real work was *after* deploy (login + data). *讓 transigen 上線並搬既有
資料;3 個修正上車前先套好,deploy 一次成功,重點在部署後(登入+資料)。*

### 1–3. Clone / provision / deploy(與 gelp 同套路)

```bash
# clone(root deploy key,同 Day 3)
sudo ssh-keygen -t ed25519 -f /root/.ssh/transigen_deploy_key -N "" -C "louis2-transigen-deploy"   # root 專屬金鑰
sudo cat /root/.ssh/transigen_deploy_key.pub     # 公鑰 → 貼到 transigen repo Deploy keys(唯讀)
sudo GIT_SSH_COMMAND="ssh -i /root/.ssh/transigen_deploy_key -o IdentitiesOnly=yes" \
  git clone --branch main git@github.com:amdslancelot/transigen.git /opt/transigen   # 用 key clone
sudo git -C /opt/transigen config core.sshCommand \
  "ssh -i /root/.ssh/transigen_deploy_key -o IdentitiesOnly=yes"                      # 釘住 key

# provision DB(角色是新的 → ROTATE=1 設成 .env.prod 密碼)
kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="transigen" ROTATE=1 TRANSIGEN_DB_PASSWORD="$TRANSIGEN_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh

# deploy
cd /opt/transigen && sudo bash deploy/deploy.sh   # build → import → rollout(3 個 fix 已預先套好)
kubectl -n transigen get pods                     # 應為 transigen-... 1/1 Running
curl -sI https://transigen.lans-h.cc | head -1    # 期望 HTTP/2 200(公開首頁在 200 就渲染,不是 302)
```

**預期 / Expect:** pod `1/1 Running`, curl `200`. *部署本身乾淨。*

### 4. Login broke — the lazy-migration trap

**問題 7 / Problem:** Google login → `/api/auth/error?error=Configuration`. Pod log:
`Migration 0001_init.sql failed: trigger "trg_users_updated_at" ... already exists`
(thrown from the Auth.js jwt callback; a one-off `iss missing` first was
stale-cookie noise). *登入報 Configuration,log 顯示非冪等 trigger 已存在。*

**Root cause (my mistake):** I hand-applied `0001_init.sql` via psql, assuming no
auto-migrate (only checked the Dockerfile). But `src/lib/db.ts` runs migrations
**lazily on the first DB query** (`getPool → runMigrations`, tracked in
`schema_migrations`). My manual apply built the objects but never recorded the
migration → the app re-ran it → the non-idempotent `create trigger` blew up.
*我以為不會自動 migrate,手動套用 schema 卻沒登記,app 首次查詢時又重跑一次就撞非
冪等 trigger。教訓:app 會自我 migrate(讀 db.ts 確認)就別手動套用其 migration。*

**解法 / Fix:** record the migration as applied so the lazy migrator skips it (the
DB is already in the correct post-0001 state — pure bookkeeping).

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql "postgres://transigen_rw:<hex>@localhost:5432/transigen" -c \
  "insert into schema_migrations (name) values ('0001_init.sql') on conflict (name) do nothing;"   # 補登=告訴 app「這條已套用」
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d transigen -c "select * from schema_migrations;"   # 驗證:應看到一列 0001_init.sql
```

**工作 / Then log in in a fresh incognito window → creates the prod user row:**

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d transigen -c "select id, email, google_sub from users;"   # 讀 prod user UUID(搬資料要用)
# → deba6cde-8be3-4269-9db9-27841e4758c9  lansoulot@gmail.com
```

**預期 / Expect:** login succeeds; one `users` row with the prod UUID. *登入成功、
建好 prod user 列。*

### 5. Data migration — re-point to prod user + preset id 衝突

**目標 / Goal:** load the Jul-23 `pg_dump` into prod. The dump has **no `users`
row** (login upserts it) but child tables reference the old dev UUID; also its 6
`transition_presets` have FIXED uuids while `0001_init.sql` seeded them with RANDOM
uuids → a `code`-unique clash on load. *把 7/23 快照灌進 prod;dump 無 users 列、
子表指向舊 UUID;preset 固定 id 撞 seed 的隨機 id。*

**解法 / Fix:** `sed` old→prod UUID; prepend `DELETE FROM transition_presets` and
load the whole dump in one `--single-transaction` (atomic — a mid-load failure
rolls back).

```bash
# Mac — 產生 prod 版 dump(P = prod user UUID)
cd ~/Documents/Cursor/transigen
{ echo "DELETE FROM public.transition_presets;"; \
  sed 's/15fc6cc8-2053-446e-b39c-3530efee8ba2/deba6cde-8be3-4269-9db9-27841e4758c9/g' data.sql; } \
  > data.prod.sql                                     # 先刪 seed presets,再把舊 UUID 全換成 prod UUID
scp data.prod.sql opc@92.5.135.46:~/data.prod.sql     # 傳到節點

# node — 原子載入
kubectl -n data exec -i deploy/postgres -- \
  psql "postgres://transigen_rw:<hex>@localhost:5432/transigen" \
  --single-transaction -v ON_ERROR_STOP=1 < ~/data.prod.sql   # 整包一個交易,任一句錯就全 rollback

# 驗證每張表列數對得上 7/23 快照
kubectl -n data exec -i deploy/postgres -- psql -U postgres -d transigen -c "
  select 'presets' t,count(*) from transition_presets
  union all select 'proposals',count(*) from transition_proposals
  union all select 'pairs',count(*) from transition_pairs
  union all select 'rooms',count(*) from rooms order by 1;"

# 清掉含真實資料的檔案(節點端;Mac 端同樣刪除)
shred -u ~/data.prod.sql 2>/dev/null || rm -f ~/data.prod.sql   # 優先安全抹除,沒有 shred 就退回 rm
```

**預期 / Expect:** `DELETE 6` then `46× INSERT 0 1`; counts = presets 6, proposals
8, pairs 5, rooms 3, … (46 total) matching the snapshot; old rooms/proposals now
visible in the UI. transigen LIVE. *列數吻合、UI 看得到舊資料,transigen 上線。*

**Note — env-file convention unified:** `deploy/env.prod` → `deploy/.env.prod`
(gitignored) + `.env.prod.example` (committed); `env.staging` split into
`.env.staging.example` (committed) + `.env.staging` (gitignored); all stay in
`deploy/` (inputs to deploy tooling). Same Google OAuth client across envs.
*env 統一成 dotfile + .example 拆分,留在 deploy/。*

**Note — cosmetic (non-migration):** room "Play full set" is disabled until both
hidden YouTube deck players fire `onReady` (`RoomFullSetPlayer.tsx`); first visit
can sit greyed ("Loading players…"), a reload fixes it — data was correct (3 edges
built). Logged as a transigen TODO. *首訪播放器未 ready 會卡灰,reload 即好,非遷移
bug,列 TODO。*

---

## Day 5 (2026-07-26) — Gate 6 my_website (in progress)

**目標 / Goal:** put the static site live at apex `lans-h.cc`. Different shape from
gelp/transigen: static Astro→nginx, a **git-poll systemd timer** (not a webhook),
private repo. The local clone had **no GitHub remote** and was on `master`.
*讓靜態站上線於 apex `lans-h.cc`;形狀不同:靜態站、git-poll timer、private repo;
本機還沒有 remote、分支是 master。*

### 1. Mac — 調整成平台相容 + 推上 GitHub

**工作 / Work (edits mirroring gelp):** `poll.sh` podman-aware +
`localhost/lans-h-site` image + PATH export; `deployment.yaml` image
`localhost/lans-h-site`; `ingress.yaml` host `lans-h.ai`→`lans-h.cc` +
`ingressClassName: traefik`; systemd unit paths `/opt/lans-h-ai`→`/opt/my_website`;
DEPLOY.md rewritten for the platform context. *poll.sh podman 化、image localhost、
ingress 改 host、unit 路徑、DEPLOY.md 重寫。*

```bash
cd ~/Documents/claude/my_website
printf '\nworklog.md\nUPWARD-STATS.md\n.upward-stats-state.json\n' >> .gitignore   # 個人/工具檔加進 gitignore
git rm --cached worklog.md UPWARD-STATS.md .upward-stats-state.json                # 停止追蹤(已 commit 過)
git branch -m master main                                                          # 分支改名 master → main(poll.sh 追 main)
git add .gitignore DEPLOY.md deploy/poll.sh deploy/deploy-poll.service \
  k8s/deployment.yaml k8s/ingress.yaml                                             # 只 stage 這次改的檔
git commit -m "deploy: onboard onto shared platform k3s node"                      # → 6f69bd5
# 在 github.com/amdslancelot/my_website 建一個空的 PRIVATE repo(網頁),然後:
git remote set-url origin git@github.com:amdslancelot/my_website.git               # 指向新 repo
git push -u origin main                                                            # 推上去
```

**預期 / Expect:** `main → origin/main`, personal files no longer tracked. ✅ done.

### 2. Node — deploy key + clone

**目標 / Goal:** clone the private repo into `/opt/my_website` as root (git-poll runs
as root), using a per-app read-only deploy key. *以 root clone 到 /opt/my_website,
用 per-app 唯讀 deploy key(git-poll 以 root 跑)。*

```bash
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/my_website_deploy_key -C louis2-my_website-deploy   # 產 root 金鑰
sudo cat /root/.ssh/my_website_deploy_key.pub     # 公鑰 → 貼到 repo Deploy keys(唯讀)
sudo GIT_SSH_COMMAND='ssh -i /root/.ssh/my_website_deploy_key -o IdentitiesOnly=yes' \
  git clone git@github.com:amdslancelot/my_website.git /opt/my_website   # 用 key clone
sudo git -C /opt/my_website config core.sshCommand \
  'ssh -i /root/.ssh/my_website_deploy_key -o IdentitiesOnly=yes'         # 釘住 key(git-poll 每分鐘 fetch 要用)
sudo git -C /opt/my_website log --oneline -1      # 驗證:應為 6f69bd5
```

**預期 / Expect:** `/opt/my_website` at `6f69bd5`. ✅ done.

### 3. Node — apply manifests + 裝 poll timer(pending)

**目標 / Goal:** create the Deployment/Service/Ingress, then install the timer that
polls `origin/main` every minute and rebuilds on change. *建 Deployment/Service/
Ingress,再裝每分鐘輪詢 origin/main、有變才重建的 timer。*

```bash
kubectl apply -f /opt/my_website/k8s/                              # 套 Deployment(映像未 build)+ Service + Ingress;不用 sudo(opc 用 644 kubeconfig)
sudo chmod +x /opt/my_website/deploy/poll.sh                       # 確保可執行
sudo cp /opt/my_website/deploy/deploy-poll.service /etc/systemd/system/   # 安裝 service unit
sudo cp /opt/my_website/deploy/deploy-poll.timer /etc/systemd/system/     # 安裝 timer unit
sudo systemctl daemon-reload                                       # 讓 systemd 讀取新 unit
sudo systemctl enable --now deploy-poll.timer                      # 啟用並立即啟動 timer
```

**工作 / First build — force it (an idle poll is a no-op since HEAD==origin/main):**

```bash
sudo /opt/my_website/deploy/poll.sh   # 手動強制跑一次:podman build(Astro→nginx)→ import → kubectl rollout
```

**預期 / Expect:** the build runs, image imports as `localhost/lans-h-site:latest`,
rollout succeeds. This is the **first real test of my_website's poll.sh** against
the gelp bugs (PATH / image name) — all pre-fixed, but confirmed only by running.
*首次驗證 my_website 的 poll.sh 有沒有踩 gelp 那些坑;都先修好了,實跑才算數。*

### 4. Verify(pending)

```bash
kubectl rollout status deployment/lans-h-site        # 應為 successfully rolled out(opc,不用 sudo)
curl -sI https://lans-h.cc | head -1                 # 期望 HTTP/2 200 + 有效 TLS(平台 wildcard 自動涵蓋 apex)
# 確認 Cloudflare apex A 記錄:lans-h.cc → 92.5.135.46(灰雲)
```

**預期 / Expect:** `200` with valid TLS at the apex → my_website LIVE, Gate 6
complete. *apex 200 且憑證有效 → my_website 上線,Gate 6 完成。*

---

## Reference — recurring concepts / 重點觀念(問過的問題精華)

Kept because the *why* is the reusable part. *「為什麼」才是能重用的部分。*

- **sudo secure_path:** sudo swaps PATH for a trusted minimal list (anti PATH-
  injection); OL9's excludes `/usr/local/bin`, so bare `k3s`/`kubectl` fail under
  `sudo` but work under systemd/login. *故用全路徑或 PATH prepend。*
- **image normalization:** bare `x:latest` → `docker.io/library/x:latest`; podman
  tags unqualified as `localhost/x`. Use `localhost/x` so containerd never pulls.
  *裸名會被正規化成 docker.io;用 localhost 永不 pull。*
- **`AUTH_SECRET`:** symmetric session-signing key — leak ⇒ forge any session;
  never share across envs (blast radius = everywhere it exists). *對稱鑰,不跨環境
  共用。*
- **`AUTH_TRUST_HOST=true`:** trust the proxy's `Host`/`X-Forwarded-Host` (you own
  Traefik); prod otherwise distrusts it to block host-header→OAuth-callback hijack.
  *Traefik 後面設 true。*
- **`GOOGLE_MAPS_API_KEY`:** server-side key in *your* GCP project (billed to you),
  not any end-user's — distinct from the OAuth client and the Drive service
  account. *是你專案的 server key,三種憑證不同物。*
- **`DRIVE_FOLDER_ID`:** belongs only to the headless nightly CronJob (no session →
  single service account + folder); the main app is multi-user via
  `session.user.id`. *只屬夜間 CronJob,主 app 仍是多人。*
- **k3s reinstall didn't disrupt pods:** the containerd-shim decouples running
  containers from the daemon; kubelet reconciles, doesn't recreate. Node uses
  SQLite (single-node default), not etcd. *shim 讓容器與 daemon 解耦。*
- **adnanh/webhook** routes by URL path `/hooks/<id>` only (not Host header) → ids
  must be globally unique (`deploy-<app>`). *只靠路徑路由,id 要全域唯一。*
- **lazy migrations:** an app may run its migrations on the first DB query (check
  the DB bootstrap, e.g. `db.ts`, not just the Dockerfile) — never hand-apply its
  migration files, or record them in its ledger if you must. *app 可能首次查詢才
  migrate;別手動套用它的 migration。*
- **`-C` (ssh-keygen):** sets the key comment (a label in the `.pub`); no security
  effect. *只是 key 的標籤。*
