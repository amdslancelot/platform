# Platform migration log — shared k3s node cutover

A walkthrough of moving four workloads onto one shared k3s node (`louis2`, OCI
A1.Flex, 92.5.135.46), written the way I'd guide it step by step in the CLI: each
task opens with what we're doing and why, then numbered steps — a sentence of
context, the commands (with inline `#` notes), and what to expect. Problems are
told inline where they hit, with how they were solved.

*把四個 workload 搬上同一台 k3s 節點的實作紀錄,用我在 CLI 一步步帶你的口吻寫:每
個任務先講「在做什麼、為什麼」,再編號步驟——一句背景、指令(行內 `#` 註解)、預期
結果;遇到問題就在當下說明怎麼解的。*

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
| ☐ | Gate 6 my_website 收尾(首次 build → 驗證 `https://lans-h.cc`) |
| ☐ | Gate 7:退休各 app 的舊 `setup-server.sh` / `setup-app.sh` 等節點級腳本 |
| ☐ | tag-gate flip:gelp/transigen 由 push-to-main 改為 `v*` tag(對齊 snoopy) |
| ☐ | 可選加固:`shred -u /opt/<app>/.env.prod` |

---

## Day 1 (2026-07-24) — Gates 0–4

### Gate 0+1 — 重新啟用 Traefik/servicelb

The node was originally installed with `--disable traefik --disable servicelb`
(the snoopy-only era), so it can't serve 80/443 yet. `bootstrap-node.sh` re-runs
the k3s installer *without* those flags — the running snoopy/postgres pods survive
because a k3s restart doesn't recreate containers, it just reconciles.

*節點當初裝了 `--disable traefik --disable servicelb`(只有 snoopy 的年代),還不能
服務 80/443。`bootstrap-node.sh` 重跑 k3s installer、拿掉那兩個旗標;執行中的
snoopy/postgres 不會被動到,因為 k3s 重啟只是對帳、不會重建容器。*

**1. 跑 bootstrap(升級套件 + 重寫 k3s unit + 重啟):**

```bash
sudo bash bootstrap/bootstrap-node.sh
```

Two things bit here, both from the script blindly inheriting gelp's old
root-centric assumptions:

*這裡踩到兩個坑,都是腳本盲目沿用 gelp 舊的 root 中心假設造成的:*

- **問題 1 / Problem:** it queried `rollout status` the instant the node was Ready,
  but k3s deploys Traefik asynchronously (~30–90s) via its helm-controller →
  `deployments.apps "traefik" not found`. That's a race, not a failure. **解法:**
  wait-loop for the Deployment to exist first (commit `769b3f6`). *查太早,Traefik
  還沒被非同步部署出來;改成先等 Deployment 存在再查。*
- **問題 2 / Problem:** `opc` running kubectl → permission denied. The script had
  carried over `chmod 600` on the kubeconfig from gelp's setup, but this node
  deliberately uses `--write-kubeconfig-mode 644` so `opc` (and snoopy's CI over
  SSH) can run bare kubectl. **解法:** restore 644 on the node and delete the chmod
  from the script (commit `c942415`). *腳本盲搬 `chmod 600`,與本節點刻意的 644 衝
  突;節點復原 644、腳本刪掉該行。*

```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml   # 讓 opc / CI 能直接跑 kubectl(這把 644 之後每個 kubectl 都靠它)
```

**2. 驗證 Traefik 回來了、而且沒動到現有 pod:**

```bash
grep -c "disable" /etc/systemd/system/k3s.service          # 期望 0(disable 旗標已消失)
kubectl -n kube-system get deploy traefik                  # 期望 1/1 Available
kubectl -n kube-system get pods | grep -E "traefik|svclb"  # traefik + svclb 都 Running
kubectl -n snoopy get pods                                 # snoopy 仍 Running、AGE 沒歸零(沒被重建)
kubectl -n data get pods                                   # postgres 仍 Running、AGE 沒歸零
```

Expect: disable count `0`, Traefik `1/1`, and the snoopy/postgres AGE still
counting from before — that last part is the proof the k3s restart was
non-destructive. *disable 為 0、Traefik 1/1、snoopy/postgres 的 AGE 沒歸零——最後
這點就是「重啟沒破壞」的證明。*

### Gate 2 — OCI security list 開 80/443

Open ingress TCP 80/443 in the OCI console's security list, then prove the path
from the public internet all the way to Traefik.

*在 OCI console 的 security list 開 80/443,然後驗證從外網一路到 Traefik 通不通。*

**1. 從 Mac 打節點的 public IP:**

```bash
curl -sk https://92.5.135.46 -o /dev/null -w "%{http_code}\n"   # -k:此刻還是自簽佔位憑證,先略過驗證
```

Expect `404` — that means the request reached Traefik (which just has no route
yet). The full chain internet → security list → svclb → Traefik is wired.
*期望 404:代表打到 Traefik 了(只是還沒路由規則),整條路通。*

### Gate 3 — Postgres no-op 擁有權交接

The shared Postgres was first stood up inside snoopy's repo. We want the
`platform` repo to become its single source of truth — but only if that's a
byte-for-byte no-op, so there's zero risk to the live data. `kubectl diff` proves
it before `apply` touches anything.

*共用 Postgres 最早是建在 snoopy 的 repo 裡。我們要讓 `platform` repo 成為它的單一
真相——但前提是這必須是「零變動」的交接,對線上資料零風險。先用 `kubectl diff` 證
明,再 `apply`。*

**1. 先證明零差異,再接管:**

```bash
kubectl diff -f cluster/data-postgres/postgres.yaml && echo "NO-OP CONFIRMED"   # diff 空=platform 版與線上完全一致
kubectl apply -f cluster/data-postgres/postgres.yaml                            # 接管;期望四項全 unchanged
```

Expect an empty diff (`NO-OP CONFIRMED`) then all resources `unchanged`. Platform
is now the applier of record and not one byte of data moved. *diff 空、apply 全
unchanged;platform 正式接管,資料一個 byte 都沒動。*

### Gate 4 — TLS 全鏈(cert-manager → Cloudflare DNS-01 → wildcard)

The goal is one `*.lans-h.cc` (+apex) wildcard cert, issued automatically by
cert-manager via a Cloudflare DNS-01 challenge, and set as Traefik's *default*
certificate — so every current and future host gets valid HTTPS with no per-app
config. This gate had the two real fights of the day.

*目標是一張 `*.lans-h.cc`(含 apex)wildcard 憑證,由 cert-manager 透過 Cloudflare
DNS-01 自動簽發,並設為 Traefik 的**預設**憑證——這樣現有和未來的每個 host 都自動
有有效 HTTPS、不用逐 app 設定。今天兩場硬仗都在這關。*

**1. 裝 cert-manager:**

```bash
bash cluster/cert-manager/install.sh   # v1.15.3;3 個 deployment 應全 Available
```

**2. 建 Cloudflare token secret → 但這裡爆了問題 3。**

**問題 3 / Problem:** the certificate stayed READY False with
`6003/6111: Invalid format for Authorization header`. The stored secret literally
contained the placeholder string `<你的token>` — the create-secret command had been
run without substituting the real value. The lesson: verify the token against
Cloudflare *before* storing it, so a bad value fails loudly at your hands instead
of silently inside cert-manager.

*憑證一直 READY False,報 `Invalid format for Authorization header`。原來 secret 裡
存的是佔位字串 `<你的token>` 本身——當初跑指令沒換成真值。教訓:token 一律先對
Cloudflare 驗證再入庫,壞值就會在你手上當場報錯,而不是默默死在 cert-manager 裡。*

```bash
kubectl -n cert-manager get secret cloudflare-api-token \
  -o jsonpath='{.data.api-token}' | base64 -d | wc -c        # 檢查長度:應 40,結果是 25 → 存錯了
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify    # 對 Cloudflare 驗證,期望 "success":true
# 驗證通過 → 重建 secret → rollout restart cert-manager
```

**3. Token 修好了,卻又卡問題 4。**

**問題 4 / Problem:** the challenge went `valid` but the cert was still False, now
logging `DELETE /zones//dns_records/... 7003` with an *empty* zone id. Root cause:
the `rollout restart` I did while fixing #3 happened *mid-challenge*, wiping
cert-manager's in-memory zone cache; the post-validation TXT cleanup then looped
forever on the empty zone id, blocking the second (same-domain) challenge. The
fix is to scrap the half-done request and let a clean order run end to end — and
the lesson is to never `rollout restart` cert-manager mid-challenge.

*token 修好後 challenge 轉 valid,但憑證仍 False,改報 `DELETE /zones//dns_records/`
帶**空的** zone id。根因:修問題 3 時的 `rollout restart` 正好在 challenge 進行中,
洗掉了記憶體裡的 zone 快取;驗證後的 TXT 清理就帶著空 zone id 無限重試,卡死同網域
的第二個 challenge。解法:砍掉半途的請求讓它整輪重來;教訓是切勿在 challenge 進行
中重啟 cert-manager。*

```bash
kubectl -n platform delete certificaterequest lans-h-cc-1   # 砍掉半途請求,cert-manager 自動開一張全新 order
kubectl -n platform get certificate lans-h-cc               # 等它變 READY True
```

**4. 補上最後兩塊,然後從 Mac 做驗收(不帶 -k 才算數):**

```bash
kubectl apply -f cluster/traefik/tlsstore-default.yaml   # 把 wildcard 設為 Traefik 預設憑證
kubectl apply -f cluster/traefik/www-redirect.yaml       # www→apex 的 301 middleware

curl -sI https://test.lans-h.cc | head -1   # 任意子網域:期望 HTTP/2 404 且憑證有效
curl -sI https://www.lans-h.cc/abc          # 期望 301 → location: https://lans-h.cc/abc
curl -sI https://lans-h.cc | head -1        # apex:期望 HTTP/2 404
```

Expect all three to succeed **without `-k`** (valid cert is the acceptance test),
www 301-ing to apex, and unrouted names giving a clean 404. Renewal is automatic
from here. *三個都不用 -k 就成功=憑證有效(這就是驗收);www 301 回 apex;未路由的
乾淨 404;之後續簽全自動。*

---

## Day 2 (2026-07-25) — Gate 5: webhook listener

We install the adnanh/webhook listener on `:9000` so a GitHub push can later
trigger a deploy. The webhook secrets are passed only as one-shot sudo env vars
for the single install command and `unset` right after — never written to shell
history or disk.

*裝 adnanh/webhook listener 在 :9000,讓之後 GitHub push 能觸發部署。webhook secret
只在這一條安裝指令的 sudo 環境變數裡短暫存在、跑完立刻 unset,不落地到 history 或
磁碟。*

**1. 安裝並本機檢查:**

```bash
sudo GELP_WEBHOOK_SECRET="$GELP_WH" TRANSIGEN_WEBHOOK_SECRET="$TRAN_WH" \
  bash bootstrap/install-webhook.sh          # 裝 webhook 2.8.3 + 渲染 hooks.json + 起 systemd 服務
systemctl status webhook                     # 期望 active (running), enabled
curl -s http://localhost:9000/hooks/deploy   # 期望回 "Hook rules were not satisfied."
```

**2. 從 Mac 做外網檢查:**

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://92.5.135.46:9000/hooks/deploy   # 期望 HTTP 200
curl -s http://92.5.135.46:9000/hooks/deploy                                          # 期望 "Hook rules were not satisfied."
```

"Hook rules were not satisfied" (no valid HMAC signature) is the *correct* answer
— it proves the listener is up **and actually evaluating rules**, not merely
reachable. Full path verified: internet → security list :9000 → servicelb →
webhook daemon. *「Hook rules were not satisfied」是沒帶正確 HMAC 時的正確回應,證明
listener 不只是打得通、而是真的在跑規則判斷。整條外網路徑已驗證。*

**3. 後續:hook-id 一致性 + 兩個 app repo 的清理。**

Before either app's real GitHub webhook existed, I caught that gelp's hook id was
a bare `deploy` (a leftover from when it was the only app) while transigen's was
`deploy-transigen`. Renamed gelp's to `deploy-gelp` (commit `a0463d3`) and re-ran
the installer, since adnanh/webhook routes purely by URL path — ids must be
globally unique. Also cleaned both apps' `deploy.sh`/overlays (dropped their own
cert-manager install, ClusterIssuer, and `tls:` patch; hardcoded the host), now
that the platform wildcard covers every Ingress.

*趁兩個 app 的真 webhook 還沒接上,發現 gelp 的 hook id 是裸的 `deploy`(當初唯一
app 留下的),而 transigen 是 `deploy-transigen`。把 gelp 改成 `deploy-gelp`(commit
`a0463d3`)並重跑 installer——因為 adnanh/webhook 只靠 URL 路徑路由,id 必須全域唯
一。順便清掉兩個 app 自帶的 cert-manager 安裝/ClusterIssuer/tls patch(host 寫死),
因為平台 wildcard 已涵蓋所有 Ingress。*

```bash
# Mac: hooks.json 改名 deploy-gelp(a0463d3),然後節點重跑:
sudo GELP_WEBHOOK_SECRET="$GELP_WH" TRANSIGEN_WEBHOOK_SECRET="$TRAN_WH" \
  bash bootstrap/install-webhook.sh
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy-gelp        # 期望 200(新路徑)
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy             # 期望 404(舊路徑已移除)
curl -s -o /dev/null -w "%{http_code}\n" http://92.5.135.46:9000/hooks/deploy-transigen   # 期望 200(不受影響)
```

The GitHub Payload URL convention going forward is a DNS name, not an IP:
`http://deploy.lans-h.cc:9000/hooks/deploy-<app>` — the `*.lans-h.cc` wildcard
already resolves it, so no new Cloudflare record is needed. *之後 GitHub Payload
URL 一律用網域名不用 IP;wildcard 已能解析,不用加新記錄。*

**問題 / Problem (branch hygiene):** transigen's deploy-cleanup commit accidentally
landed on its local-only `webaudio-playback` feature branch instead of `main`.
**解法:** cherry-pick the fix onto main, then soft-reset the feature branch and
restore only the 3 deploy files — leaving its uncommitted audio WIP untouched
(the branch was never pushed, so rewriting it was safe). *deploy 清理 commit 誤落在
本機 feature branch;cherry-pick 回 main,feature branch soft-reset 後只還原那 3 個
deploy 檔,audio WIP 沒動;branch 沒推過遠端,改寫安全。*

```bash
git checkout main && git cherry-pick c60619a9              # 把 fix 搬到 main(→ c3319b68)
git checkout webaudio-playback && git reset --soft HEAD~1  # feature branch 退回 commit 前(改動留工作區)
git restore --source=HEAD --staged --worktree -- \
  deploy/deploy.sh deploy/env.prod.example deploy/k8s/overlays/prod/kustomization.yaml   # 只還原這 3 個 deploy 檔
```

---

## Day 3 (2026-07-25) — Gate 6 gelp 上車 (LIVE)

Now the first app. The goal is gelp live at `https://gelp.lans-h.cc`: clone,
provision its DB, deploy, seed data. One thing up front — **do not run gelp's
`deploy/setup-server.sh`**. That's the old from-zero node builder (installs its
own k3s and webhook.service); the node is platform-managed now, so re-running it
would collide with the existing setup. It's Gate-7 retirement fodder. This
clone→provision→deploy shape is reused for every app.

*第一個 app。目標是 gelp 上線於 `https://gelp.lans-h.cc`:clone、開通 DB、部署、灌資
料。先講一件事——**gelp 的 `deploy/setup-server.sh` 不要跑**。那是舊的「從零建節點」
腳本(自己裝 k3s 和 webhook.service);節點現在由 platform 管,重跑它會跟現有設定打
架,是 Gate 7 要退休的舊副本。這套 clone→provision→deploy 之後每個 app 重用。*

**1. Clone 到 /opt/gelp —— 但 root 沒 GitHub key。**

The deploy runs as **root** (webhook service), and root has no GitHub key, so a
plain `sudo git clone` fails with `Permission denied (publickey)`. The fix is a
per-app read-only deploy key for root — least-privilege, matching the project's
per-app-secret style — then pin it so future webhook-triggered pulls use it too.

*部署以 **root** 身分跑(webhook 服務),root 沒 GitHub key,所以 `sudo git clone`
會 `Permission denied (publickey)`。解法是給 root 一把 per-app 唯讀 deploy key(最小
權限,符合本專案 per-app secret 的風格),再把它釘進 repo,之後 webhook 觸發的 pull
也用它。*

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/gelp_deploy_key -N "" -C "louis2-gelp-deploy"   # 產 root 專屬金鑰;-C 只是標籤
sudo cat /root/.ssh/gelp_deploy_key.pub          # → 貼到 gelp repo Settings → Deploy keys,唯讀(不勾 write)
sudo GIT_SSH_COMMAND="ssh -i /root/.ssh/gelp_deploy_key -o IdentitiesOnly=yes" \
  git clone --branch main git@github.com:amdslancelot/gelp.git /opt/gelp   # 用這把 key clone
sudo git -C /opt/gelp config core.sshCommand \
  "ssh -i /root/.ssh/gelp_deploy_key -o IdentitiesOnly=yes"                 # 釘住 key,之後 fetch/pull 自動用它
```

**2. 開通 gelp 的 DB —— 角色可能早就存在。**

Run platform's `provision-db.sh` against the shared Postgres. The prod `gelp_rw`
role already existed here, so the first run reported `password untouched` — the
password we passed was *not* applied. Re-run with `ROTATE=1` to set it (safe, since
nothing was using the prod role yet; staging is a separate minikube Postgres). Use
a hex password to avoid `DATABASE_URL` percent-encoding headaches.

*用 platform 的 `provision-db.sh` 對共用 Postgres 跑。這裡 prod `gelp_rw` 角色早就存
在,所以首跑回報 `password untouched`——傳進去的密碼沒被套用。加 `ROTATE=1` 重跑設
定它(安全,prod 角色還沒人在用;staging 是另一台 minikube Postgres)。密碼用 hex,
免去 `DATABASE_URL` 的百分比編碼麻煩。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="gelp" GELP_DB_PASSWORD="$GELP_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh          # 首跑:回報 "password untouched"

kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="gelp" ROTATE=1 GELP_DB_PASSWORD="$GELP_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh          # 加 ROTATE=1 重跑:回報 "rotated"
```

**3. 手動跑一次 deploy.sh —— 一口氣冒出 3 個 gelp 專屬的 bug。**

Run `deploy.sh` by hand once to validate build → import → rollout before trusting
the webhook. gelp's script predated fixes transigen already had, so it surfaced
three bugs one by one.

*先手動跑一次 deploy.sh,驗證 build → import → rollout 整條路,再信任 webhook。gelp
的腳本比 transigen 舊、少了幾個修正,於是一個一個冒出三個 bug。*

```bash
cd /opt/gelp && sudo bash deploy/deploy.sh   # build 映像 → import 進 containerd → kubectl rollout
```

- **問題 5 / Bug 1 — sudo secure_path:** `deploy.sh: line 61: k3s: command not
  found`. `sudo` replaces PATH with its `secure_path`, which on OL9 excludes
  `/usr/local/bin` (where k3s lives). **解法:** `export PATH="/usr/local/bin:$PATH"`
  at the top of deploy.sh (commit `f002c33`); for interactive use, the full path
  `sudo /usr/local/bin/k3s`. *sudo 的 secure_path 不含 /usr/local/bin;腳本頂端
  export PATH,手打就用全路徑。*
- **問題 6 / Bug 2 — image name → ImagePull:** the pod was stuck "trying and failing
  to pull image". podman builds an unqualified tag as `localhost/gelp:latest`, but
  the bare `gelp:latest` in the pod spec normalizes to `docker.io/library/gelp`,
  so containerd tries a (failing) registry pull. **解法:** name the prod image
  `localhost/gelp` via the overlay's `images: newName` (commit `396fe8a`) — honest,
  and containerd never pulls a `localhost` host. *裸名被正規化成 docker.io、去
  registry 拉失敗;用 overlay 的 `newName: localhost/gelp` 誠實命名,永不 pull。*

```bash
kubectl -n gelp logs deploy/gelp   # 診斷 bug 2:應看到 "waiting to start: trying and failing to pull image"
# 兩個 fix 都在 Mac 改好、git push → webhook 自動 redeploy
```

**4. 驗證 —— bug 1 也會咬互動指令,改用全路徑:**

```bash
sudo k3s ctr images ls | grep gelp                  # → sudo: k3s: command not found(同一個 secure_path 坑)
sudo /usr/local/bin/k3s ctr images ls | grep gelp   # 用全路徑:應列出 localhost/gelp(+ 殘留的 docker.io/library/gelp)
kubectl -n gelp get pods                            # 應為 gelp-... 1/1 Running
curl -sI https://gelp.lans-h.cc | grep -i location  # 應為 location: https://gelp.lans-h.cc/login
sudo /usr/local/bin/k3s ctr images rm docker.io/library/gelp:latest   # 清掉 debug 過程留下的中間映像
```

**5. 灌資料 —— 用 Takeout 重傳,不是 pg_dump。**

The TODO's original plan (pg_dump from a preserved `gelp-pgdata` volume + repoint
every `user_id`) was moot: that volume is gone and gelp was never really on prod
before. So instead, log into prod and re-upload the Google Takeout zip through the
app's own `/import` flow, which auto-scopes the import to the logged-in user —
zero DB surgery.

*TODO 原本的計畫(從保留的 `gelp-pgdata` volume 做 pg_dump + 重指每個 user_id)行不
通:那個 volume 沒了,而且 gelp 之前根本沒真的上過 prod。所以改成登入 prod、用 app
自己的 `/import` 重傳 Google Takeout zip,匯入會自動歸給登入者——完全不動 DB。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d gelp -c "select id, email, google_sub from users;"   # 先確認 prod user(登入後才有這列)
# → ee55ef4e-...  lansoulot@gmail.com

# ... 在 https://gelp.lans-h.cc/import(已登入)上傳 Takeout zip ...

kubectl -n data exec -i deploy/postgres -- psql -U postgres -d gelp \
  -c "select count(*) from lists;" -c "select count(*) from places;" \
  -c "select count(*) from places where cache_key is not null;" \
  -c "select count(*) from place_cache;"   # 匯入後逐表計數驗證
```

Expect `70 lists / 5469 places / 5469 enriched / 5350 cached` — full Places-API
enrichment worked. gelp is LIVE, and push-to-deploy is proven end-to-end.
*期望 70 清單 / 5469 地點 / 5469 全 enrich / 5350 快取;gelp 上線,push 自動部署整條
路也驗證過了。*

---

## Day 4 (2026-07-26) — Gate 6 transigen 上車 (LIVE)

Second app, same shape — but this time the three gelp fixes (PATH export,
`localhost/transigen` image, `.env.prod` dotfile) were pre-applied on the Mac
first, so the deploy itself went `Running 1/1` on the first try. The real work was
*after* deploy: login broke, and then the data migration.

*第二個 app,同套路——但這次 gelp 的三個修正(PATH export、`localhost/transigen`
image、`.env.prod` dotfile)在 Mac 上先套好了,所以部署本身一次就 `Running 1/1`。真
正的工作在部署之後:登入壞掉,以及資料搬遷。*

**1–3. Clone / provision / deploy(與 gelp 同套路,不再贅述):**

```bash
# clone（root deploy key,同 Day 3）
sudo ssh-keygen -t ed25519 -f /root/.ssh/transigen_deploy_key -N "" -C "louis2-transigen-deploy"
sudo cat /root/.ssh/transigen_deploy_key.pub     # → 貼到 transigen repo Deploy keys(唯讀)
sudo GIT_SSH_COMMAND="ssh -i /root/.ssh/transigen_deploy_key -o IdentitiesOnly=yes" \
  git clone --branch main git@github.com:amdslancelot/transigen.git /opt/transigen
sudo git -C /opt/transigen config core.sshCommand "ssh -i /root/.ssh/transigen_deploy_key -o IdentitiesOnly=yes"

# provision DB（角色是新的 → 直接帶 ROTATE=1 一次到位）
kubectl -n data exec -i deploy/postgres -- \
  env PROVISION_APPS="transigen" ROTATE=1 TRANSIGEN_DB_PASSWORD="$TRANSIGEN_DB_PASSWORD" \
  bash -s < cluster/data-postgres/provision-db.sh

# deploy
cd /opt/transigen && sudo bash deploy/deploy.sh   # 3 個 fix 已預先套好,應一次成功
kubectl -n transigen get pods                     # 期望 transigen-... 1/1 Running
curl -sI https://transigen.lans-h.cc | head -1    # 期望 HTTP/2 200(公開首頁在 200 就渲染,不是 302)
```

**4. 登入壞掉 —— 惰性 migration 的坑(我犯的錯)。**

**問題 7 / Problem:** Google login redirected to
`/api/auth/error?error=Configuration`. The pod log's definitive line was
`Migration 0001_init.sql failed: trigger "trg_users_updated_at" ... already
exists`, thrown from the Auth.js jwt callback (a one-off `iss missing` first was
just stale-cookie noise).

**Root cause (mine):** I had hand-applied `0001_init.sql` via psql to stand up the
schema, assuming there was no auto-migrate step — I'd only checked the Dockerfile.
But `src/lib/db.ts` runs migrations **lazily on the first DB query** (`getPool →
runMigrations`, tracked in a `schema_migrations` table). My manual apply built all
the objects but never recorded the migration, so on first login the app re-ran it
and died on the non-idempotent `create trigger`. The lesson: if an app
self-migrates (even lazily), don't hand-apply its migration files — read the DB
bootstrap (`db.ts`), not just the Dockerfile.

*問題 7:Google 登入導到 `error=Configuration`,pod log 關鍵是
`Migration 0001_init.sql failed: trigger ... already exists`(從 Auth.js jwt
callback 拋出;先前那次 `iss missing` 只是舊 cookie 殘留)。根因(我的錯):我以為沒
有自動 migrate(只看了 Dockerfile),就手動 psql 套用了 schema——但 `src/lib/db.ts`
會在**首次查詢時惰性跑 migration**,記錄在 `schema_migrations`。我手動套用建好所有物
件卻沒登記,app 首次登入又重跑一次,撞上非冪等的 `create trigger`。教訓:app 會自我
migrate(哪怕只在首次查詢)就別手動套用它的 migration 檔,要讀 DB bootstrap(db.ts)
確認,不能只看 Dockerfile。*

**解法:** record the migration as already applied so the lazy migrator skips it —
the DB is already in the correct post-0001 state, so this is pure bookkeeping.
*把該 migration 補登為已套用,惰性 migrator 就跳過;DB 已是正確狀態,純記帳。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql "postgres://transigen_rw:<hex>@localhost:5432/transigen" -c \
  "insert into schema_migrations (name) values ('0001_init.sql') on conflict (name) do nothing;"   # INSERT 0 1
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d transigen -c "select * from schema_migrations;"   # 驗證:應看到一列 0001_init.sql
```

Then log in again in a fresh incognito window — it succeeds and creates the prod
user row. Read its UUID; the data migration needs it. *然後用全新無痕視窗重登一次即
成功,並建好 prod user 列。讀出它的 UUID,搬資料要用。*

```bash
kubectl -n data exec -i deploy/postgres -- \
  psql -U postgres -d transigen -c "select id, email, google_sub from users;"
# → deba6cde-8be3-4269-9db9-27841e4758c9  lansoulot@gmail.com
```

**5. 搬資料 —— 重指 prod user + preset id 衝突。**

We load the Jul-23 `pg_dump` into prod. Two wrinkles: the dump has **no `users`
row** (login upserts it) but every child table references the old dev UUID; and
its 6 `transition_presets` have FIXED uuids while `0001_init.sql` seeded them with
RANDOM ones → a `code`-unique clash on load. So: `sed` the old UUID to the prod
UUID, prepend a `DELETE` of the seeded presets, and load the whole thing in one
`--single-transaction` so any failure rolls back cleanly.

*把 7/23 的 `pg_dump` 灌進 prod。兩個眉角:dump 裡**沒有 users 列**(登入時 upsert 自
建),但所有子表都指向舊 dev UUID;而它的 6 筆 `transition_presets` 是固定 uuid,
`0001_init.sql` 卻用隨機 uuid seed 過 → 載入時 `code` unique 撞鍵。所以:`sed` 把舊
UUID 換成 prod UUID、在最前面加一句刪掉 seed 的 presets、整包用
`--single-transaction` 載入,任何錯誤都乾淨 rollback。*

```bash
# Mac — 產生 prod 版 dump（P = prod user UUID）
cd ~/Documents/Cursor/transigen
{ echo "DELETE FROM public.transition_presets;"; \
  sed 's/15fc6cc8-2053-446e-b39c-3530efee8ba2/deba6cde-8be3-4269-9db9-27841e4758c9/g' data.sql; } \
  > data.prod.sql                                     # 先刪 seed presets,再把舊 UUID 全換成 prod UUID
scp data.prod.sql opc@92.5.135.46:~/data.prod.sql     # 傳到節點

# node — 原子載入
kubectl -n data exec -i deploy/postgres -- \
  psql "postgres://transigen_rw:<hex>@localhost:5432/transigen" \
  --single-transaction -v ON_ERROR_STOP=1 < ~/data.prod.sql   # 整包一個交易,任一句錯全 rollback

# 驗證每張表列數對得上 7/23 快照
kubectl -n data exec -i deploy/postgres -- psql -U postgres -d transigen -c "
  select 'presets' t,count(*) from transition_presets
  union all select 'proposals',count(*) from transition_proposals
  union all select 'pairs',count(*) from transition_pairs
  union all select 'rooms',count(*) from rooms order by 1;"

# 清掉含真實資料的檔案（節點端;Mac 端同樣刪除）
shred -u ~/data.prod.sql 2>/dev/null || rm -f ~/data.prod.sql   # 優先安全抹除,沒有 shred 就退回 rm
```

Expect `DELETE 6` then `46× INSERT 0 1`, counts matching the snapshot (presets 6,
proposals 8, pairs 5, rooms 3, … 46 total), and the old rooms/proposals now
showing in the UI. transigen is LIVE. *期望 DELETE 6、46× INSERT 0 1,列數對得上快
照,UI 也看得到舊 rooms/proposals;transigen 上線。*

Two side-notes from this app: its env files were unified to the repo convention
(`deploy/.env.prod` dotfile + `.env.prod.example`; `.env.staging` split into a
committed `.example` + gitignored real file, all under `deploy/` as deploy-tool
inputs; same Google OAuth client across envs). And a known cosmetic quirk: a
room's "Play full set" button stays disabled until both hidden YouTube players
fire `onReady` — first visit can sit greyed ("Loading players…"), a reload fixes
it (data was correct). Logged as a transigen TODO.

*這個 app 兩點附註:env 檔統一成 repo 慣例(`deploy/.env.prod` dotfile +
`.env.prod.example`;`.env.staging` 拆成 committed 的 `.example` + gitignore 的真檔,
全放 `deploy/` 當部署工具輸入;dev/staging/prod 共用同一個 Google OAuth client)。另
有一個既有小瑕疵:room 的「Play full set」在兩個隱藏 YouTube player 都 `onReady` 前
是灰的,首訪可能卡灰(顯示「Loading players…」),reload 即好(資料是對的),已列
transigen TODO。*

---

## Day 5 (2026-07-26) — Gate 6 my_website 上車(進行中)

Last app, and a different shape: a static Astro→nginx site at the apex
`lans-h.cc`, deployed by a **git-poll systemd timer** (not a webhook), from a
private repo. The local clone had no GitHub remote and was on `master`, so this
one also needed a GitHub repo created and a branch rename first.

*最後一個 app,形狀不同:靜態 Astro→nginx 站,掛在 apex `lans-h.cc`,由 **git-poll
systemd timer**(不是 webhook)部署,來自一個 private repo。本機這份還沒有 GitHub
remote、分支是 `master`,所以這個還得先建 GitHub repo、改分支名。*

**1. Mac —— 調整成平台相容,然後推上 GitHub。**

The edits mirror gelp: `poll.sh` made podman-aware with a `localhost/lans-h-site`
image and a PATH export; `deployment.yaml` image renamed to match; `ingress.yaml`
host `lans-h.ai`→`lans-h.cc` plus `ingressClassName: traefik` (TLS comes free from
the platform wildcard, no tls block); systemd unit paths `/opt/lans-h-ai`→
`/opt/my_website`; DEPLOY.md rewritten for the platform context. Also gitignore +
untrack the personal `worklog.md`/`UPWARD-STATS.md` files.

*改動比照 gelp:`poll.sh` 改用 podman、image 用 `localhost/lans-h-site`、加 PATH
export;`deployment.yaml` image 跟著改名;`ingress.yaml` host 改 `lans-h.cc` 並加
`ingressClassName: traefik`(TLS 由平台 wildcard 免費涵蓋,不用 tls block);systemd
unit 路徑改 `/opt/my_website`;DEPLOY.md 重寫成平台版。順手把個人的 worklog.md /
UPWARD-STATS.md gitignore 並停止追蹤。*

```bash
cd ~/Documents/claude/my_website
printf '\nworklog.md\nUPWARD-STATS.md\n.upward-stats-state.json\n' >> .gitignore   # 個人/工具檔加進 gitignore
git rm --cached worklog.md UPWARD-STATS.md .upward-stats-state.json                # 停止追蹤(已 commit 過)
git branch -m master main                                                          # 分支改名 → main(poll.sh 追 main)
git add .gitignore DEPLOY.md deploy/poll.sh deploy/deploy-poll.service \
  k8s/deployment.yaml k8s/ingress.yaml
git commit -m "deploy: onboard onto shared platform k3s node"                      # → 6f69bd5
# 在 github.com/amdslancelot/my_website 建一個空的 PRIVATE repo(網頁),然後:
git remote set-url origin git@github.com:amdslancelot/my_website.git
git push -u origin main                                                            # main → origin/main
```

**2. Node —— deploy key + clone(root,同前兩個 app):**

```bash
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/my_website_deploy_key -C louis2-my_website-deploy
sudo cat /root/.ssh/my_website_deploy_key.pub     # → 貼到 repo Deploy keys(唯讀)
sudo GIT_SSH_COMMAND='ssh -i /root/.ssh/my_website_deploy_key -o IdentitiesOnly=yes' \
  git clone git@github.com:amdslancelot/my_website.git /opt/my_website
sudo git -C /opt/my_website config core.sshCommand \
  'ssh -i /root/.ssh/my_website_deploy_key -o IdentitiesOnly=yes'
sudo git -C /opt/my_website log --oneline -1      # 驗證:應為 6f69bd5
```

**3. Node —— apply manifests + 裝 poll timer。**

Note the split: `kubectl` needs **no sudo** here (the node's kubeconfig is mode
644, so `opc` runs it directly — and `sudo kubectl` would actually fail on the
same secure_path trap, since kubectl lives in `/usr/local/bin`). The `cp`/
`systemctl` steps do need sudo because they write to `/etc`.

*注意這個分界:`kubectl` 這裡**不用 sudo**(節點 kubeconfig 是 644,`opc` 直接跑就
好——而且 `sudo kubectl` 反而會踩同一個 secure_path 坑,因為 kubectl 在
`/usr/local/bin`)。`cp`/`systemctl` 要 sudo,因為寫的是 `/etc`。*

```bash
kubectl apply -f /opt/my_website/k8s/                              # opc 直接跑;建 Deployment(映像未 build)+ Service + Ingress
sudo chmod +x /opt/my_website/deploy/poll.sh
sudo cp /opt/my_website/deploy/deploy-poll.service /etc/systemd/system/
sudo cp /opt/my_website/deploy/deploy-poll.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now deploy-poll.timer                      # 啟用並啟動 timer(每分鐘輪詢 origin/main)
```

**問題 8 / Problem:** the first manual `sudo poll.sh` did nothing but fetch. That's
by design — poll.sh compares local HEAD to `origin/main` and exits if they're
equal (an idle poll is a no-op). The clone was already at the tip. **解法:** push a
real commit (the pending DEPLOY.md fix) so `origin/main` moves ahead — which also
doubles as the genuine end-to-end push-to-deploy test — then re-run poll.sh.

*問題 8:第一次手動 `sudo poll.sh` 只做了 fetch 就結束。這是設計行為——poll.sh 比對
本機 HEAD 與 `origin/main`,相等就 exit(idle poll 是 no-op),而 clone 本來就在最新。
解法:push 一個真的 commit(那個 pending 的 DEPLOY.md 修正)讓 `origin/main` 前進
——順便當作真正的 push-to-deploy 全鏈測試——再重跑 poll.sh。*

```bash
# Mac
cd ~/Documents/claude/my_website && git push origin main   # origin/main → 1ff0810(領先節點一個 commit)

# node — 現在有差異,強制首次 build
sudo /opt/my_website/deploy/poll.sh   # podman build(Astro→nginx)→ import localhost/lans-h-site → kubectl rollout
```

Expect the run to now print `New commit …, deploying…`, then the podman build, an
image import as `localhost/lans-h-site:latest`, and a successful rollout. This is
the first real test of my_website's `poll.sh` against the gelp traps (PATH / image
name) — all pre-fixed, but only a real run confirms it. **(進行到這裡 / current
position.)**

*期望這次會印出 `New commit …, deploying…`,接著 podman build、映像以
`localhost/lans-h-site:latest` import、rollout 成功。這是第一次真的驗證 my_website 的
`poll.sh` 有沒有踩 gelp 那些坑(PATH / image 命名)——都先修好了,但要實跑才算數。
**目前進行到這一步。***

**4. 驗證(待做):**

```bash
kubectl rollout status deployment/lans-h-site   # 期望 successfully rolled out(opc,不用 sudo)
curl -sI https://lans-h.cc | head -1            # 期望 HTTP/2 200 + 有效 TLS(平台 wildcard 自動涵蓋 apex)
# 確認 Cloudflare apex A 記錄:lans-h.cc → 92.5.135.46(灰雲)
```

Expect `200` with a valid cert at the apex → my_website LIVE and Gate 6 complete.
*apex 拿到 200 且憑證有效 → my_website 上線,Gate 6 完成。*

---

## Reference — 重點觀念(問過的問題精華)

Kept because the *why* is the reusable part. *「為什麼」才是能重用的部分。*

- **sudo secure_path:** sudo swaps PATH for a trusted minimal list (anti
  PATH-injection); OL9's excludes `/usr/local/bin`, so bare `k3s`/`kubectl` fail
  under `sudo` but work under systemd/login. *故用全路徑或 PATH prepend。*
- **image normalization:** bare `x:latest` → `docker.io/library/x:latest`; podman
  tags unqualified as `localhost/x`. Use `localhost/x` so containerd never pulls.
  *裸名會被正規化成 docker.io;用 localhost 永不 pull。*
- **`AUTH_SECRET`:** symmetric session-signing key — leak ⇒ forge any session;
  never shared across envs. *對稱鑰,不跨環境共用。*
- **`AUTH_TRUST_HOST=true`:** trust the proxy's `Host`/`X-Forwarded-Host` (you own
  Traefik); prod otherwise distrusts it to block host-header→OAuth-callback hijack.
  *Traefik 後面設 true。*
- **`GOOGLE_MAPS_API_KEY`:** server-side key in *your* GCP project (billed to you),
  distinct from the OAuth client and the Drive service account. *是你專案的 server
  key,三種憑證不同物。*
- **`DRIVE_FOLDER_ID`:** belongs only to the headless nightly CronJob (no session);
  the main app is multi-user via `session.user.id`. *只屬夜間 CronJob,主 app 仍是
  多人。*
- **k3s reinstall didn't disrupt pods:** the containerd-shim decouples running
  containers from the daemon; kubelet reconciles, doesn't recreate. Node uses
  SQLite (single-node default), not etcd. *shim 讓容器與 daemon 解耦。*
- **adnanh/webhook** routes by URL path `/hooks/<id>` only (not Host header) → ids
  must be globally unique. *只靠路徑路由,id 要全域唯一。*
- **lazy migrations:** an app may run migrations on the first DB query (check the DB
  bootstrap, e.g. `db.ts`, not just the Dockerfile) — never hand-apply its
  migration files. *app 可能首次查詢才 migrate;別手動套用它的 migration。*
- **`-C` (ssh-keygen):** sets the key comment (a label in the `.pub`); no security
  effect. *只是 key 的標籤。*
