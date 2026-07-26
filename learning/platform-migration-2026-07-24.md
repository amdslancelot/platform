# Platform migration log — shared k3s node cutover

Command-led runbook of executing `docs/runbook.md` on the prod node (`louis2`,
OCI A1.Flex, 92.5.135.46). Each step is the commands as given; where a problem
hit, it's recorded as **問題 → 解法** right before the fix commands.

*在 prod 節點執行 `docs/runbook.md` 的指令實錄。每步就是當時給的指令;遇到問題就
在修復指令前記一行「問題 → 解法」。*

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
| ☐ | Gate 6 my_website 收尾(deploy key → clone → apply → timer → 驗證) |
| ☐ | Gate 7:退休各 app 的舊 `setup-server.sh` / `setup-app.sh` 等節點級腳本 |
| ☐ | tag-gate flip:gelp/transigen 由 push-to-main 改為 `v*` tag(對齊 snoopy) |
| ☐ | 可選加固:`shred -u /opt/<app>/.env.prod` |

---

## Day 1 (2026-07-24) — Gates 0–4

### Gate 0+1 — bootstrap-node.sh(重新啟用 Traefik/servicelb)

```bash
sudo bash bootstrap/bootstrap-node.sh
```

**問題 1 / Problem:** script queried `rollout status` right after node Ready, but
k3s deploys Traefik async via helm-controller → `deployments.apps "traefik" not
found`. *腳本在節點 Ready 後立刻查 rollout,但 Traefik 是 helm-controller 非同步
部署,NotFound 是競態非失敗。*
**解法 / Fix:** wait-loop for the Deployment to exist before the rollout check
(commit `769b3f6`). *先等 Deployment 存在再查 rollout。*

**問題 2 / Problem:** `opc` kubectl → permission denied (`Unable to read
/etc/rancher/k3s/k3s.yaml`); script had carried over `chmod 600` from gelp's
root-centric setup, clashing with this node's `--write-kubeconfig-mode 644`.
*腳本盲搬 gelp 的 `chmod 600`,與本節點刻意的 644 衝突。*
**解法 / Fix:** *節點一次性復原 644,並從腳本刪掉該行(commit `c942415`)。*

```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```

Verify / 驗證:

```bash
grep -c "disable" /etc/systemd/system/k3s.service   # → 0
kubectl -n kube-system get jobs                     # helm-install-traefik Complete
kubectl -n kube-system get deploy traefik           # 1/1 Available
kubectl -n kube-system get svc traefik              # LoadBalancer 80:.../443:...
kubectl -n kube-system get pods | grep -E "traefik|svclb"   # both Running
kubectl -n snoopy get pods                          # snoopy Running, AGE 29h (untouched)
kubectl -n data get pods                            # postgres Running, AGE 31h
```

### Gate 2 — OCI security list(開 80/443,console 操作)

```bash
curl -sk https://92.5.135.46 -o /dev/null -w "%{http_code}\n"   # → 404
```

404 = internet → security list → svclb → Traefik 全線通(此時仍是自簽佔位憑證,
故需 `-k`)。*404 代表整條路通了。*

### Gate 3 — Postgres no-op 擁有權交接

```bash
kubectl diff -f cluster/data-postgres/postgres.yaml && echo "NO-OP CONFIRMED"   # diff 零輸出
kubectl apply -f cluster/data-postgres/postgres.yaml                            # 四項全 unchanged
```

Textbook handover: platform is now applier of record, data untouched.
*教科書級交接:apply 全 unchanged,platform 成為單一真相,資料零變動。*

### Gate 4 — TLS 全鏈

```bash
bash cluster/cert-manager/install.sh   # cert-manager v1.15.3, 3 deployments Available
```

**問題 3 / Problem:** cert stuck READY False, log `6003/6111: Invalid format for
Authorization header`; the stored secret literally held the placeholder string
`<你的token>`. *secret 存的是佔位符本身(當初沒換成真值)。*
**解法 / Fix:** verify the token BEFORE storing, then recreate the secret +
`rollout restart` cert-manager. *token 先驗證再入庫。*

```bash
kubectl -n cert-manager get secret cloudflare-api-token \
  -o jsonpath='{.data.api-token}' | base64 -d | wc -c        # → 25 (真 token 應為 40)
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify    # → "success":true
```

**問題 4 / Problem:** token fixed, but cert still False; log
`DELETE /zones//dns_records/... 7003` (empty zone id). A mid-challenge `rollout
restart` (during fix #3) wiped cert-manager's in-memory zone cache. *修問題 3 時
在 challenge 進行中重啟,洗掉 zone 快取,TXT 清理帶空 zone id 無限重試。*
**解法 / Fix:** delete the CertificateRequest so a clean order runs end-to-end.
Lesson: never `rollout restart` cert-manager mid-challenge. *刪 CertificateRequest
讓它整輪重來;切勿在 challenge 中重啟 cert-manager。*

```bash
kubectl -n platform delete certificaterequest lans-h-cc-1
kubectl -n platform get certificate lans-h-cc                # → True ... READY
```

Apply the last two pieces + acceptance test from the Mac (no `-k`):

```bash
kubectl apply -f cluster/traefik/tlsstore-default.yaml
kubectl apply -f cluster/traefik/www-redirect.yaml

curl -sI https://test.lans-h.cc | head -1        # HTTP/2 404  (有效憑證,乾淨 404)
curl -sI https://www.lans-h.cc/abc               # HTTP/2 301 → location: https://lans-h.cc/abc
curl -sI https://lans-h.cc | head -1             # HTTP/2 404
```

Gate 4 done: every `*.lans-h.cc` gets valid HTTPS automatically; www→apex at
Traefik; renewal automatic. *所有子網域自動有效 HTTPS,www 301 回 apex,續簽全自動。*

---

## Day 2 (2026-07-25) — Gate 5: webhook listener

Secrets exported only into the sudo env for the one command, `unset` right after
— never to shell history/disk. *secret 只在單一指令的 sudo 環境內短暫存在,結束
立刻 unset。*

```bash
sudo GELP_WEBHOOK_SECRET="$GELP_WH" TRANSIGEN_WEBHOOK_SECRET="$TRAN_WH" \
  bash bootstrap/install-webhook.sh
# → webhook 2.8.3, listener ready on :9000

systemctl status webhook                          # active (running), enabled
curl -s http://localhost:9000/hooks/deploy        # Hook rules were not satisfied.
```

External check from the Mac:

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://92.5.135.46:9000/hooks/deploy   # HTTP 200
curl -s http://92.5.135.46:9000/hooks/deploy                                          # Hook rules were not satisfied.
```

"Hook rules were not satisfied" (no valid HMAC) = listener up and evaluating
rules, not just reachable. *沒帶正確 HMAC 的正確回應,證明規則有在跑判斷。*

**Follow-up / 後續 — hook-id 一致性 + app repo 清理:** gelp's hook id was bare
`deploy` (only-app leftover) vs transigen's `deploy-transigen`. *不一致。*

```bash
# Mac: rename to deploy-gelp in webhook/hooks.json (commit a0463d3), then on node:
sudo GELP_WEBHOOK_SECRET="$GELP_WH" TRANSIGEN_WEBHOOK_SECRET="$TRAN_WH" \
  bash bootstrap/install-webhook.sh
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy-gelp        # 200
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy             # 404 (gone)
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy-transigen   # 200 (unaffected)
```

Also cleaned gelp's + transigen's `deploy.sh`/prod overlay (dropped per-app
cert-manager + ClusterIssuer + `tls:` patch; host hardcoded) since the platform
wildcard now covers every Ingress. GitHub webhook Payload URL convention:
`http://deploy.lans-h.cc:9000/hooks/deploy-<app>` (DNS name, resolved by the
existing wildcard; adnanh/webhook routes by path only). Both webhooks configured
live, still `refs/heads/main` gated (tag-flip deferred). *兩邊 overlay 拿掉自帶
TLS;webhook 用網域名稱、路徑路由;tag-gate 之後再處理。*

**transigen branch-hygiene 插曲:** deploy fix commit 誤落在本機 `webaudio-playback`
feature branch。用 cherry-pick 把 fix 搬回 main、branch soft-reset 後單獨 restore
那 3 個 deploy 檔,feature WIP 完全沒動。*staged by explicit filename, never
`git add -A`.*

```bash
git checkout main && git cherry-pick c60619a9         # main → c3319b68
git checkout webaudio-playback && git reset --soft HEAD~1
git restore --source=HEAD --staged --worktree -- \
  deploy/deploy.sh deploy/env.prod.example deploy/k8s/overlays/prod/kustomization.yaml
```

---

## Day 3 (2026-07-25) — Gate 6 gelp (LIVE)

Onboarding shape (reused per app): **plain `git clone`, NOT `setup-server.sh`**
(that from-zero node builder collides with platform — Gate-7 fodder).
*上車一律 plain clone,不用會跟 platform 打架的 setup-server.sh。*

### 1. Clone as root — needs a per-app deploy key

**問題 / Problem:** `sudo git clone` runs as root; root has no GitHub key.
*root 沒 GitHub key → publickey denied.*

```bash
sudo git clone --branch main git@github.com:amdslancelot/gelp.git /opt/gelp
# → git@github.com: Permission denied (publickey).
```

**解法 / Fix:** per-app read-only deploy key, clone with it, pin for future
webhook pulls. *per-app 唯讀 deploy key + `core.sshCommand`。*

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/gelp_deploy_key -N "" -C "louis2-gelp-deploy"
sudo cat /root/.ssh/gelp_deploy_key.pub          # → add as read-only Deploy key on the repo
sudo GIT_SSH_COMMAND="ssh -i /root/.ssh/gelp_deploy_key -o IdentitiesOnly=yes" \
  git clone --branch main git@github.com:amdslancelot/gelp.git /opt/gelp
sudo git -C /opt/gelp config core.sshCommand "ssh -i /root/.ssh/gelp_deploy_key -o IdentitiesOnly=yes"
```

### 2. Provision the DB

**問題 / Problem:** prod `gelp_rw` role already existed → password NOT applied
(`exists: role 'gelp_rw' — password untouched`). *角色已存在,密碼沒被套用。*
**解法 / Fix:** re-run with `ROTATE=1` (safe — nothing used the prod role yet).
Use a hex password to avoid `DATABASE_URL` percent-encoding. *`ROTATE=1` 重跑;
密碼用 hex 避開 URL 編碼坑。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="gelp" GELP_DB_PASSWORD="$GELP_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh          # → password untouched

kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="gelp" ROTATE=1 GELP_DB_PASSWORD="$GELP_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh          # → rotated
```

### 3. First manual deploy — surfaced 3 gelp-only deploy.sh bugs

```bash
cd /opt/gelp && sudo bash deploy/deploy.sh
```

**問題 5 / Bug 1 — sudo secure_path:** `deploy.sh: line 61: k3s: command not
found`. `sudo` swaps PATH for `secure_path`, which on OL9 excludes
`/usr/local/bin` (where k3s lives). *sudo 的 secure_path 不含 /usr/local/bin。*
**解法 / Fix:** `export PATH="/usr/local/bin:$PATH"` atop deploy.sh (commit
`f002c33`); for interactive use the full path `sudo /usr/local/bin/k3s`.

**問題 6 / Bug 2 — image name → ImagePull:** pod "trying and failing to pull
image". podman builds `localhost/gelp:latest`, but bare `gelp:latest` in the pod
spec normalizes to `docker.io/library/gelp:latest` → registry pull → fail.
*裸名被正規化成 docker.io,找不到就去 registry 拉。*
**解法 / Fix:** name the prod image `localhost/gelp` via the prod overlay
`images: newName` (commit `396fe8a`) — honest, containerd never pulls `localhost`.

```bash
kubectl -n gelp logs deploy/gelp        # → waiting to start: trying and failing to pull image
# both fixes pushed from Mac → webhook redeploys
```

**Verify — bug 1 also bites the interactive command:**

```bash
sudo k3s ctr images ls | grep gelp                  # → sudo: k3s: command not found
sudo /usr/local/bin/k3s ctr images ls | grep gelp   # localhost/gelp + docker.io/library/gelp
kubectl -n gelp get pods                            # gelp-... 1/1 Running
curl -sI https://gelp.lans-h.cc | grep -i location  # location: https://gelp.lans-h.cc/login
sudo /usr/local/bin/k3s ctr images rm docker.io/library/gelp:latest   # prune debug leftover
```

### 4. Data seed — Takeout re-upload (not pg_dump)

**Decision:** the TODO's `pg_dump` from a `gelp-pgdata` volume was moot (volume
gone; app never really on prod). Instead re-upload the Google Takeout zip via the
app's own `/import`, which auto-scopes to the logged-in user — zero DB surgery.
*改用 app 的 /import 重傳 Takeout,自動歸給登入者,不動 DB。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d gelp -c "select id, email, google_sub from users;"
# → ee55ef4e-...  lansoulot@gmail.com  (prod user)

# ... upload the Takeout zip at https://gelp.lans-h.cc/import (logged in) ...

kubectl -n data exec -i deploy/postgres -- psql -U postgres -d gelp \
  -c "select count(*) from lists;" -c "select count(*) from places;" \
  -c "select count(*) from places where cache_key is not null;" \
  -c "select count(*) from place_cache;"
# → 70 lists / 5469 places / 5469 enriched / 5350 cached
```

gelp LIVE at `https://gelp.lans-h.cc`.

---

## Day 4 (2026-07-26) — Gate 6 transigen (LIVE)

The 3 gelp fixes were pre-applied to transigen's `deploy.sh` on the Mac (PATH
export, `localhost/transigen` image, `.env.prod` dotfile), so deploy → `Running
1/1` first try. *三個修正上車前就先套好,deploy 一次成功。*

### 1–3. Clone / provision / deploy (same shape as gelp)

```bash
# clone (root deploy key, as in Day 3)
sudo ssh-keygen -t ed25519 -f /root/.ssh/transigen_deploy_key -N "" -C "louis2-transigen-deploy"
sudo cat /root/.ssh/transigen_deploy_key.pub     # → add as read-only Deploy key
sudo GIT_SSH_COMMAND="ssh -i /root/.ssh/transigen_deploy_key -o IdentitiesOnly=yes" \
  git clone --branch main git@github.com:amdslancelot/transigen.git /opt/transigen
sudo git -C /opt/transigen config core.sshCommand "ssh -i /root/.ssh/transigen_deploy_key -o IdentitiesOnly=yes"

# provision DB (fresh role → ROTATE=1 to set the .env.prod password)
kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="transigen" ROTATE=1 TRANSIGEN_DB_PASSWORD="$TRANSIGEN_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh

# deploy
cd /opt/transigen && sudo bash deploy/deploy.sh
kubectl -n transigen get pods                    # transigen-... 1/1 Running
curl -sI https://transigen.lans-h.cc | head -1   # HTTP/2 200 (public landing renders at 200, not 302)
```

### 4. Login broke — the lazy-migration trap

**問題 7 / Problem:** Google login → `/api/auth/error?error=Configuration`. Pod
log: `Migration 0001_init.sql failed: trigger "trg_users_updated_at" ... already
exists` (thrown from the Auth.js jwt callback; a one-off `iss missing` first was
stale-cookie noise). *登入報 Configuration,log 顯示非冪等 trigger 已存在。*

**Root cause (my mistake):** I hand-applied `0001_init.sql` via psql, assuming no
auto-migrate (only checked Dockerfile). But `src/lib/db.ts` runs migrations
**lazily on first query** (`getPool → runMigrations`, tracked in
`schema_migrations`). My manual apply built the objects but never recorded the
migration → the app re-ran it → non-idempotent `create trigger` blew up. *我以為
不會自動 migrate,手動套用 schema 卻沒登記,app 首次查詢時又重跑一次就撞非冪等
trigger。教訓:app 會自我 migrate(讀 db.ts 確認)就別手動套用其 migration。*

**解法 / Fix:** record the migration as applied so the lazy migrator skips it (DB
already in the correct post-0001 state). *補登 schema_migrations,純記帳。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql "postgres://transigen_rw:<hex>@localhost:5432/transigen" -c \
  "insert into schema_migrations (name) values ('0001_init.sql') on conflict (name) do nothing;"   # INSERT 0 1
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d transigen -c "select * from schema_migrations;"    # → 0001_init.sql
```

Then login in a **fresh incognito window** → succeeds, prod user row created:

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d transigen -c "select id, email, google_sub from users;"
# → deba6cde-8be3-4269-9db9-27841e4758c9  lansoulot@gmail.com
```

### 5. Data migration — re-point to prod user + preset id conflict

**問題 8 / Problem:** the Jul-23 `pg_dump` has no `users` row (login upserts it),
but child tables reference the old dev UUID; also the dump's 6 `transition_presets`
have FIXED uuids while `0001_init.sql` seeded them with RANDOM uuids → `code`
unique clash on load. *dump 無 users 列、子表指向舊 UUID;preset 固定 id 撞 seed
的隨機 id。*
**解法 / Fix:** `sed` old→prod UUID; prepend `DELETE FROM transition_presets` and
load the whole dump in one `--single-transaction`. *sed 重指 + 先刪 seed presets,
整包原子載入。*

```bash
# Mac — build the prod dump (P = prod user UUID)
cd ~/Documents/Cursor/transigen
{ echo "DELETE FROM public.transition_presets;"; \
  sed 's/15fc6cc8-2053-446e-b39c-3530efee8ba2/deba6cde-8be3-4269-9db9-27841e4758c9/g' data.sql; } \
  > data.prod.sql
scp data.prod.sql opc@92.5.135.46:~/data.prod.sql

# node — atomic load
kubectl -n data exec -i deploy/postgres -- \
  psql "postgres://transigen_rw:<hex>@localhost:5432/transigen" \
  --single-transaction -v ON_ERROR_STOP=1 < ~/data.prod.sql       # DELETE 6 ; 46× INSERT 0 1

# verify per-table counts match the Jul-23 snapshot
kubectl -n data exec -i deploy/postgres -- psql -U postgres -d transigen -c "
  select 'presets' t,count(*) from transition_presets
  union all select 'proposals',count(*) from transition_proposals
  union all select 'pairs',count(*) from transition_pairs
  union all select 'rooms',count(*) from rooms order by 1;"
# → presets 6, proposals 8, pairs 5, rooms 3, ... (46 rows total)

# cleanup the real-data file from both ends
shred -u ~/data.prod.sql 2>/dev/null || rm -f ~/data.prod.sql     # on node
```

transigen LIVE at `https://transigen.lans-h.cc` (login + data verified in UI).

**Note — env-file convention unified:** `deploy/env.prod` → `deploy/.env.prod`
(gitignored) + `.env.prod.example` (committed); `env.staging` split into
`.env.staging.example` (committed) + `.env.staging` (gitignored). Stays in
`deploy/` (input to deploy tooling). Same Google OAuth client across envs.
*env 統一成 dotfile + .example 拆分,留在 deploy/。*

**Note — cosmetic (non-migration):** room "Play full set" is disabled until both
hidden YouTube deck players fire `onReady` (`RoomFullSetPlayer.tsx`); first visit
can sit greyed ("Loading players…"), a reload fixes it. Data was correct (3 edges
built). Logged as a transigen TODO. *首訪播放器未 ready 會卡灰,reload 即好,非
遷移 bug,列 TODO。*

---

## Day 5 (2026-07-26) — Gate 6 my_website (in progress)

Different shape: static Astro→nginx, apex `lans-h.cc`, **git-poll systemd timer**
(not webhook), private repo. The local clone had **no GitHub remote** and was on
`master`. *形狀不同:靜態站、apex、git-poll timer、private repo;本機還沒有 remote、
分支是 master。*

### 1. Mac — adapt to platform + push to GitHub

Edits (mirroring gelp): `poll.sh` podman-aware + `localhost/lans-h-site` image +
PATH export; `deployment.yaml` image `localhost/lans-h-site`; `ingress.yaml` host
`lans-h.ai`→`lans-h.cc` + `ingressClassName: traefik`; systemd unit paths
`/opt/lans-h-ai`→`/opt/my_website`; DEPLOY.md rewritten for platform context.
*poll.sh podman 化、image localhost、ingress 改 host、unit 路徑、DEPLOY.md 重寫。*

```bash
cd ~/Documents/claude/my_website
# gitignore + untrack personal files (worklog rule); rename branch; commit
printf '\nworklog.md\nUPWARD-STATS.md\n.upward-stats-state.json\n' >> .gitignore
git rm --cached worklog.md UPWARD-STATS.md .upward-stats-state.json
git branch -m master main
git add .gitignore DEPLOY.md deploy/poll.sh deploy/deploy-poll.service \
  k8s/deployment.yaml k8s/ingress.yaml
git commit -m "deploy: onboard onto shared platform k3s node"   # 6f69bd5

# create empty PRIVATE repo on github.com/amdslancelot/my_website (web UI), then:
git remote set-url origin git@github.com:amdslancelot/my_website.git
git push -u origin main                                          # main → origin/main
```

### 2. Node — deploy key + clone (next / pending)

```bash
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/my_website_deploy_key -C louis2-my_website-deploy
sudo cat /root/.ssh/my_website_deploy_key.pub     # → add as read-only Deploy key on the repo
sudo GIT_SSH_COMMAND='ssh -i /root/.ssh/my_website_deploy_key -o IdentitiesOnly=yes' \
  git clone git@github.com:amdslancelot/my_website.git /opt/my_website
sudo git -C /opt/my_website config core.sshCommand \
  'ssh -i /root/.ssh/my_website_deploy_key -o IdentitiesOnly=yes'
sudo git -C /opt/my_website log --oneline -1      # → 6f69bd5
```

### 3. Node — apply manifests + install poll timer (pending)

```bash
sudo kubectl apply -f /opt/my_website/k8s/
sudo chmod +x /opt/my_website/deploy/poll.sh
sudo cp /opt/my_website/deploy/deploy-poll.service /etc/systemd/system/
sudo cp /opt/my_website/deploy/deploy-poll.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now deploy-poll.timer
journalctl -u deploy-poll.service -f              # watch the first build+deploy
```

### 4. Verify (pending)

```bash
sudo kubectl rollout status deployment/lans-h-site
curl -sI https://lans-h.cc | head -1              # expect HTTP/2 200 + valid TLS
# confirm Cloudflare apex A record: lans-h.cc → 92.5.135.46 (grey-cloud)
```

---

## Reference — recurring concepts / 重點觀念(問過的問題精華)

Kept because the *why* is the reusable part. *「為什麼」才是能重用的部分。*

- **sudo secure_path:** sudo swaps PATH for a trusted minimal list (anti PATH-
  injection); OL9's excludes `/usr/local/bin` (FHS local installs), so bare
  `k3s`/`kubectl` fail under `sudo` but work under systemd/login. *故用全路徑或
  PATH prepend。*
- **image normalization:** bare `x:latest` → `docker.io/library/x:latest`
  (registry `docker.io`, ns `library`); podman tags unqualified as `localhost/x`.
  Use `localhost/x` so containerd never pulls. *裸名會被正規化成 docker.io;用
  localhost 永不 pull。*
- **`AUTH_SECRET`:** symmetric session-signing key — leak ⇒ forge any session;
  never share across envs (blast radius = everywhere it exists). *對稱鑰,不跨環境
  共用。*
- **`AUTH_TRUST_HOST=true`:** trust the proxy's `Host`/`X-Forwarded-Host` (you own
  Traefik); prod otherwise distrusts it to block host-header→OAuth-callback
  hijack. *Traefik 後面設 true。*
- **`GOOGLE_MAPS_API_KEY`:** server-side key in *your* GCP project (billed to you),
  not any end-user's — distinct from the OAuth client and the Drive service
  account. *是你專案的 server key,三種憑證不同物。*
- **`DRIVE_FOLDER_ID`:** belongs only to the headless nightly CronJob (no session
  → single service account + folder); the main app is multi-user via
  `session.user.id`. *只屬夜間 CronJob,主 app 仍是多人。*
- **k3s reinstall didn't disrupt pods:** containerd-shim decouples running
  containers from the daemon; kubelet reconciles, doesn't recreate. Node uses
  SQLite (single-node default), not etcd. *shim 讓容器與 daemon 解耦。*
- **adnanh/webhook** routes by URL path `/hooks/<id>` only (not Host header) → ids
  must be globally unique (`deploy-<app>`). *只靠路徑路由,id 要全域唯一。*
- **`-C` (ssh-keygen):** sets the key comment (a human label in the `.pub`); no
  security effect. *只是 key 的標籤。*
