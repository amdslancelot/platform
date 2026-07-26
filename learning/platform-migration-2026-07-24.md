# Platform migration log — shared k3s node cutover

Live log of executing `docs/runbook.md` on the prod node (`louis2`, OCI A1.Flex,
public IP 92.5.135.46). Running record: every command, its outcome, every
problem hit and how it was solved. Updated continuously until the migration
(Gates 0–7) is complete.

*在 prod 節點上執行 `docs/runbook.md` 的實況記錄:每條指令、結果、遇到的每個
問題與解法。持續更新直到遷移(Gate 0-7)全部完成。*

**Status board / 進度看板**

| Gate | 內容 | 狀態 | 完成時間 (GMT) |
|---|---|---|---|
| 0 | 起點驗證(節點只有 snoopy + Postgres,無 Traefik) | ✅ | 2026-07-24 |
| 1 | 重新啟用 Traefik + servicelb | ✅ | 2026-07-24 ~07:10 |
| 2 | OCI security list 開 80/443/9000 | ✅ | 2026-07-24 |
| 3 | Postgres no-op 擁有權交接 | ✅ | 2026-07-24 |
| 4 | TLS 全鏈(cert-manager → Cloudflare DNS-01 → wildcard → Traefik 預設憑證) | ✅ | 2026-07-24 ~08:0x |
| 5 | webhook listener (:9000) | ✅ | 2026-07-25 07:11 |
| 6 | app 上車(gelp ✅ / transigen ⬜ / my_website ⬜) | 🟡 | gelp 2026-07-25 |
| 7 | 清理各 app repo 舊副本 | ⬜ | — |

**Outstanding / 未結事項**
- [ ] Cloudflare API token 曾在對話中以明文出現 → 全部完成後去 Cloudflare **Roll**
      一把新值並更新 `cloudflare-api-token` Secret。
- [ ] Cloudflare 殘留的 `_acme-challenge` TXT 記錄順手清掉(無害,純衛生)。
- [x] Gate 5 需產生 `GELP_WEBHOOK_SECRET` / `TRANSIGEN_WEBHOOK_SECRET` 並存入密碼
      管理器(Gate 6 在 GitHub 設 webhook 要用同一把)——密碼已由使用者存放,
      同一把值 Gate 6 設定 GitHub webhook 時要重用。
- [x] **git push 三個 repo** — 2026-07-25 用 `git fetch` 逐一確認(非只看快取的
      tracking ref):`platform` main(`c46e105c`)、`gelp` main(`7fa375f`)、
      `transigen` main(`c3319b68`)三個都已經跟 `origin/main` 一致。
- [x] **Gate 6 gelp** — LIVE at `https://gelp.lans-h.cc`(見 Day 3 段)。clone
      進 `/opt/gelp`、`ROTATE=1` provision DB、寫 `.env.prod`、修掉三個 gelp 專屬
      deploy.sh bug、Takeout 重傳 seed(70 清單 / 5469 地點全 enrich)。push
      自動部署整條路已驗證。
- [ ] **Gate 6 transigen / my_website** 還沒做。transigen 同套路(clone
      `/opt/transigen`、provision DB 可能要 ROTATE、`env.prod`、deploy);記得每個
      app 要 root 專屬的 GitHub deploy key(`/root/.ssh/<app>_deploy_key`,唯讀,
      `core.sshCommand`)。
- [ ] 可選加固:`shred -u /opt/gelp/.env.prod`(deploy.sh 首次部署後沒有它也能跑)。

---

## 2026-07-24 — Day 1: Gates 0–4

### Pre-work (on the Mac)

Platform repo built at `~/Documents/claude/platform`, pushed to
`github.com/amdslancelot/platform`; node syncs by manual `git pull`. Key design
inputs settled beforehand: DNS delegated Spaceship→Cloudflare (free), wildcard
cert via DNS-01, www→apex done in Traefik (grey-cloud Cloudflare rules can't
fire), snoopy stays zero-inbound (no subdomain), my_website keeps push-to-main.

*事前在 Mac 上完成:platform repo 建好並推上 GitHub,節點用手動 `git pull` 同步。
關鍵設計已定:DNS 從 Spaceship 委派到 Cloudflare(免費)、wildcard 憑證走 DNS-01、
www→apex 在 Traefik 做(灰雲下 Cloudflare rule 不會觸發)、snoopy 維持零入站、
my_website 維持 push-to-main。*

### Gate 0+1 — bootstrap-node.sh(重新啟用 Traefik)

```bash
sudo bash bootstrap/bootstrap-node.sh
```

Result: packages upgraded (12 RPMs incl. selinux-policy, openssl); k3s installer
re-ran (`v1.36.2+k3s1`, binary unchanged, unit file **rewritten without the
`--disable traefik --disable servicelb` flags** that snoopy's original runbook
had used), k3s restarted.

*結果:12 個 RPM 升級;k3s installer 重跑(版本不變,但 systemd unit 重寫、
**拿掉了 snoopy 原始 runbook 的 `--disable traefik --disable servicelb`**),
k3s 重啟。*

**問題 1:`deployments.apps "traefik" not found` WARNING。**
The script checked `rollout status` immediately after node Ready, but k3s
deploys Traefik asynchronously via its helm-controller (~30-90s later) —
`rollout status` errors NotFound instead of waiting. Not a real failure, a race
in the script. **Fix:** wait-loop for the Deployment to exist before rollout
check → commit `769b3f6`.

*腳本在節點 Ready 後立刻查 rollout,但 Traefik 是 helm-controller 非同步部署的
(慢 30-90 秒),NotFound 只是競態不是失敗。修法:先等 Deployment 存在再查
rollout(commit `769b3f6`)。*

**問題 2:`opc` 跑 kubectl 全部 permission denied**(`Unable to read
/etc/rancher/k3s/k3s.yaml`)。
Root cause: bootstrap-node.sh had blindly carried over `chmod 600
/etc/rancher/k3s/k3s.yaml` from gelp's root-centric `setup-server.sh` — but
this node deliberately runs `--write-kubeconfig-mode 644` so opc (and snoopy's
CI over SSH) can run bare kubectl. The chmod undid the installer's 644.
**Fix:** one-off `sudo chmod 644 /etc/rancher/k3s/k3s.yaml` on the node;
removed the chmod from the script → commit `c942415`.

*根因:腳本從 gelp 的 root 中心設計盲搬了 `chmod 600`,跟本節點刻意的
`--write-kubeconfig-mode 644`(opc/CI 直接跑 kubectl)互相矛盾。節點上一次性
`chmod 644` 復原,腳本刪掉該行(commit `c942415`)。*

Verification (all green):

```
$ grep -c "disable" /etc/systemd/system/k3s.service   → 0
$ kubectl -n kube-system get jobs
helm-install-traefik       Complete   1/1
helm-install-traefik-crd   Complete   1/1
$ kubectl -n kube-system get deploy traefik           → 1/1 Available
$ kubectl -n kube-system get svc traefik
traefik  LoadBalancer  10.43.110.46  10.0.0.240  80:31454/TCP,443:31562/TCP
$ kubectl -n kube-system get pods | grep -E "traefik|svclb"
svclb-traefik-...   2/2 Running     ← servicelb 綁節點 80/443
traefik-...         1/1 Running
$ kubectl -n snoopy get pods   → snoopy Running, AGE 29h(k3s 重啟完全沒動到)
$ kubectl -n data get pods     → postgres Running, AGE 31h
```

Note: `EXTERNAL-IP 10.0.0.240` is the VCN private IP — normal on OCI, the
public IP is 1:1 NAT at the VNIC; the node never sees it.

*註:EXTERNAL-IP 顯示私有 IP 是 OCI 正常現象,public IP 在 VNIC 層做 1:1 NAT。*

### Gate 2 — OCI security list

Opened ingress TCP 80/443/9000 in the console. Verified from the Mac:

```
$ curl -sk https://92.5.135.46 -o /dev/null -w "%{http_code}\n"   → 404
```

404 = internet → security list → svclb → Traefik 全線通(此時還是 Traefik
自簽佔位憑證,所以需要 `-k`)。

### Gate 3 — Postgres no-op 擁有權交接

```
$ kubectl diff -f cluster/data-postgres/postgres.yaml && echo "NO-OP CONFIRMED"
NO-OP CONFIRMED          ← diff 零輸出
$ kubectl apply -f cluster/data-postgres/postgres.yaml
namespace/data unchanged
persistentvolumeclaim/postgres-data unchanged
deployment.apps/postgres unchanged
service/postgres unchanged
```

Textbook handover: platform is now the applier of record; data untouched
(spec was verified byte-identical before ever touching the node).

*教科書級交接:apply 四項全 unchanged,platform 正式成為單一真相,資料零變動。*

### Gate 4 — TLS 全鏈

cert-manager v1.15.3 installed cleanly (`bash cluster/cert-manager/install.sh`,
all 3 deployments Available). Then the token/issuer/cert chain — where the two
real problems of the day happened.

*cert-manager 裝好無事。接下來 token→issuer→憑證這段出了今天兩個真正的問題。*

**問題 3:憑證卡 READY False,cert-manager log 報
`6003/6111: Invalid format for Authorization header`。**
Diagnosis: the stored token was malformed at the HTTP-header level (Cloudflare
rejected before even checking validity):

```
$ kubectl -n cert-manager get secret cloudflare-api-token \
    -o jsonpath='{.data.api-token}' | base64 -d | wc -c    → 25   (真 token 應為 40)
$ ... | base64 -d | od -c | tail -2                        → ... 346 212 212 t o k e n >
```

The secret literally contained the placeholder string `<你的token>` — the
create-secret command had been run without substituting the real token.
**Fix + lesson:** always verify the token against Cloudflare BEFORE storing:

```bash
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify    → "success":true
```

then recreate the secret and `rollout restart` cert-manager.

*secret 裡存的竟是佔位符字串本身(25 bytes,od 解出 `<你的token>`)——當初跑指令
時沒把佔位符換成真值。教訓:token 一律先打 `/user/tokens/verify` 驗證再入庫。*

**問題 4:token 修好後,challenge 轉 `valid` 但憑證仍卡 False;log 改報
`DELETE /zones//dns_records/... 7003 Could not route`(zone ID 是空的)。**
Root cause: we had `rollout restart`ed cert-manager **mid-challenge**(修問題 3
時), wiping its in-memory zone cache; the post-validation TXT-record cleanup
then looped forever with an empty zone ID, blocking the second same-domain
challenge (apex and wildcard both validate at `_acme-challenge.lans-h.cc`,
serially). **Fix:** scrap the half-done attempt and let a clean one run
end-to-end with the good token:

```bash
kubectl -n platform delete certificaterequest lans-h-cc-1
# → fresh order/challenge auto-created; pending → valid → cleanup OK → 2nd
#   challenge → valid
$ kubectl -n platform get certificate lans-h-cc
lans-h-cc   True   lans-h-cc-tls   31m        ← READY True
```

*根因:修問題 3 時在 challenge 進行中重啟了 cert-manager,洗掉記憶體裡的 zone
快取 → 驗證後的 TXT 清理帶著空 zone ID 無限重試,卡死同網域的第二個 challenge。
解法:刪掉 CertificateRequest 讓它整輪重來,一氣呵成就過了。教訓:**不要在
challenge 進行中重啟 cert-manager**;要重試就砍 CertificateRequest 重來。*

Applied the last two pieces and verified from the Mac (no `-k` — that IS the
acceptance test):

```bash
kubectl apply -f cluster/traefik/tlsstore-default.yaml
kubectl apply -f cluster/traefik/www-redirect.yaml
```

```
$ curl -sI https://test.lans-h.cc | head -1    → HTTP/2 404   (有效憑證,乾淨 404)
$ curl -sI https://www.lans-h.cc/abc | ...     → HTTP/2 301 + location: https://lans-h.cc/abc
$ curl -sI https://lans-h.cc | head -1         → HTTP/2 404
```

Gate 4 done: every `*.lans-h.cc` name now has valid HTTPS automatically;
unrouted subdomains get a clean 404 (the original "snoopy.lans-h.cc 404" ask,
delivered); www 301s to apex at the Traefik layer; renewal is automatic.

*Gate 4 完成:所有子網域自動有效 HTTPS、未路由的乾淨 404、www 在 Traefik 層
301 回 apex、續簽全自動。*

### Day 1 stopping point / 今日收工點

Next session picks up at **Gate 5**(webhook listener):generate the two
webhook secrets (→ password manager), `sudo GELP_WEBHOOK_SECRET=...
TRANSIGEN_WEBHOOK_SECRET=... bash bootstrap/install-webhook.sh`, verify
`:9000` locally + from the internet, then Gate 6 app onboarding (gelp first).

*下次從 **Gate 5** 接手:產生兩把 webhook secret(存密碼管理器)→ 跑
install-webhook.sh → 本機+外網驗證 :9000 → 進 Gate 6 app 上車(gelp 先)。*

---

## 2026-07-25 — Day 2: Gate 5

```bash
sudo GELP_WEBHOOK_SECRET="$GELP_WH" TRANSIGEN_WEBHOOK_SECRET="$TRAN_WH" \
  bash bootstrap/install-webhook.sh
```

```
==> Installing adnanh/webhook 2.8.3
==> Rendering /etc/webhook/hooks.json from .../webhook/hooks.json
Created symlink .../webhook.service → ...
==> webhook listener ready on :9000 (hooks: deploy, deploy-transigen)
```

`systemctl status webhook` → active (running), enabled. Local check:

```
$ curl -s http://localhost:9000/hooks/deploy
Hook rules were not satisfied.
```

External check (from the Mac):

```
$ curl -s -o /dev/null -w "HTTP %{http_code}\n" http://92.5.135.46:9000/hooks/deploy   → HTTP 200
$ curl -s http://92.5.135.46:9000/hooks/deploy                                          → Hook rules were not satisfied.
```

"Hook rules were not satisfied" is the CORRECT response for a request with no
valid HMAC signature — it proves the listener is up and evaluating rules, not
just reachable. Full path verified: internet → OCI security list :9000 →
servicelb → webhook daemon. No problems this gate. Secrets were exported only
into the sudo env var for the one command, then `unset` immediately after —
never written to shell history or disk.

*「Hook rules were not satisfied」是沒帶正確 HMAC 簽章時的正確回應——證明
listener 不只是「打得通」,而是真的有在跑規則判斷。全路徑已驗證:外網 → OCI
security list :9000 → servicelb → webhook daemon。這個 Gate 沒有遇到問題。
secret 只在單一指令的 sudo 環境變數內短暫存在,指令結束立刻 `unset`,沒有
落地到 shell history 或磁碟。*

Next: **Gate 6** — app onboarding, gelp first (clone into `/opt/gelp`,
provision its DB via `PROVISION_APPS="gelp"`, point its Ingress at
`gelp.lans-h.cc`, drop its own clusterissuer/cert-manager annotations since
the platform wildcard now covers it, register the GitHub webhook with
`GELP_WEBHOOK_SECRET`).

### Follow-up (same day) — hook-id consistency fix

Before gelp's real GitHub webhook existed, caught that its hook id was bare
`deploy` (a leftover from when it was the only app) while transigen's was
`deploy-transigen` — inconsistent. Renamed to `deploy-gelp` in
`webhook/hooks.json` (commit `a0463d3`), re-ran `install-webhook.sh` on the
node, verified externally: `/hooks/deploy-gelp` → 200 + rules-not-satisfied,
`/hooks/deploy` → 404 (gone), `/hooks/deploy-transigen` → unaffected. Also
gelp's own `deploy/deploy.sh` + prod overlay were cleaned up (dropped the
per-app cert-manager install and ClusterIssuer, since platform now owns TLS
for the whole node; host hardcoded to `gelp.lans-h.cc`) — pending commit in
the gelp repo. GitHub webhook Payload URL convention going forward: DNS name,
not IP — `http://deploy.lans-h.cc:9000/hooks/deploy-<app>` (the existing
`*.lans-h.cc` wildcard already resolves it, no new Cloudflare record needed).

*同一天的後續修正 —— hook id 一致性:趁 gelp 還沒接上真的 GitHub webhook,
發現它的 hook id 是裸的 `deploy`(舊時唯一 app 留下的),跟 transigen 的
`deploy-transigen` 不一致。改成 `deploy-gelp`(commit `a0463d3`),節點重跑
install-webhook.sh,外網驗證:新路徑通、舊路徑 404、transigen 路徑不受影響。
順便清了 gelp 自己的 `deploy/deploy.sh` 跟 prod overlay(拿掉自己的
cert-manager 安裝跟 ClusterIssuer,host 寫死 `gelp.lans-h.cc`)——gelp repo
那邊還沒 commit。以後 GitHub webhook Payload URL 一律用網域名稱不用 IP:
`http://deploy.lans-h.cc:9000/hooks/deploy-<app>`,靠既有 wildcard 解析,
不用加新 Cloudflare 記錄。*

*下一步:**Gate 6** —— app 上車,gelp 先。clone 進 `/opt/gelp`、用
`PROVISION_APPS="gelp"` 開通它的 DB、Ingress 指到 `gelp.lans-h.cc`、拔掉它
自己的 clusterissuer/cert-manager 註記(平台的 wildcard 已經涵蓋)、用
`GELP_WEBHOOK_SECRET` 在 GitHub 設定 webhook。*

---

## 2026-07-25 — Day 2 continued: gelp/transigen deploy cleanup, GitHub webhooks live

Extended the Gate-5 follow-up (hook-id rename) into a full cleanup pass on
both app repos, then the user configured both GitHub webhooks for real.

*把 Gate 5 後續(hook id 改名)延伸成兩個 app repo 的完整清理,使用者接著把
兩邊的 GitHub webhook 都設定好了。*

**transigen got the same treatment gelp already had:**
`deploy/deploy.sh` dropped its `letsencrypt-prod` ClusterIssuer check (that
issuer never existed on this fresh node — it was gelp's old per-host one) and
its hard dependency on `TRANSIGEN_HOST`/`/opt/transigen/deploy.env` (kubectl
already works via the platform bootstrap's `/root/.kube/config` symlink for
root, which is who the webhook service runs as). Prod overlay: dropped the
cert-manager annotation + `tls:` patch, host hardcoded to
`transigen.lans-h.cc`. `env.prod.example`: baked in the literal host instead
of a now-unused `${TRANSIGEN_HOST}` placeholder.

*transigen 補做跟 gelp 一樣的手術:deploy.sh 拿掉 `letsencrypt-prod`
ClusterIssuer 檢查(這台新節點上根本沒有這個 issuer)跟對
`TRANSIGEN_HOST`/deploy.env 的硬依賴;overlay 拿掉 cert-manager 註記跟 tls
patch,host 寫死;env.prod.example 的 host 佔位符也改成寫死。*

**Branch-hygiene wrinkle:** the transigen repo was checked out on
`webaudio-playback` (a local-only feature branch, no remote tracking,
branched exactly at `main`'s tip) when the deploy commit landed there by
accident. User wanted the deploy fix on `main` and `webaudio-playback` kept
pure for feature work. Fixed with cherry-pick, not a rewrite of shared
history (branch was never pushed, so this was safe):
```
git checkout main && git cherry-pick c60619a9        # → main gets c3319b68
git checkout webaudio-playback && git reset --soft HEAD~1
git restore --source=HEAD --staged --worktree -- deploy/deploy.sh \
  deploy/env.prod.example deploy/k8s/overlays/prod/kustomization.yaml
```
The last `restore` step only touched the 3 deploy files, leaving the
branch's real (uncommitted) audio-feature WIP completely untouched. Also
caught mid-flow: transigen's working tree had a pile of unrelated in-progress
audio-feature changes (`.gitignore`, `README.md`, several `src/` files,
`worker/worker.py`, new `src/app/api/audio/` etc.) — staged and committed
`deploy.sh`/`env.prod.example`/`kustomization.yaml` **by explicit filename
only**, never `git add -A`, so none of that WIP got swept into the deploy
commit.

*transigen 那時 checkout 在本機專屬的 `webaudio-playback` feature branch 上
(沒推遠端,從 main tip 分出來),deploy fix commit 不小心進了這個 branch。
使用者要的是 fix 進 main、`webaudio-playback` 保持乾淨。用 cherry-pick 解決
(branch 沒推過遠端,改寫安全):main 上 cherry-pick 拿到新 commit,
`webaudio-playback` 用 soft reset 退回再單獨 restore 那三個 deploy 檔案,
其餘 audio 功能的未 commit 更動完全沒被動到。過程中也注意到 transigen
working tree 有一堆跟這次改動無關的 audio 功能開發中變更,commit 時是
**明確指定檔名**,不是 `git add -A`,確保不會誤把別人的 WIP 一起 commit 進去。*

**Tag-gate flip question raised, deliberately deferred again.** User asked
"不是所有 repo 都要 tag 才觸發部署嗎?" — confirmed that's still the target
end-state (snoopy already tag-gated; gelp/transigen are not yet), but
explicitly chose to get gelp/transigen running on their current
push-to-main trigger first (verify the whole path end-to-end on the new
node), and do the tag-gate flip as a separate, later, deliberate step —
consistent with the original decision recorded in `docs/runbook.md`'s
"Deferred" section.

*使用者問起 tag-gate 的事,確認這仍是目標架構(snoopy 已經是,gelp/transigen
還不是),但明確選擇先讓 gelp/transigen 用現有的 push-to-main 觸發方式跑通
整條路,tag-gate flip 留到之後再單獨處理——跟 runbook 裡「Deferred」那段原本
的決定一致。*

**GitHub webhooks configured on both repos (live).** Payload URLs use the
DNS-name convention from the prior turn:
`http://deploy.lans-h.cc:9000/hooks/deploy-gelp` and
`http://deploy.lans-h.cc:9000/hooks/deploy-transigen`, still `refs/heads/main`
gated (per the tag-gate deferral above). **Not yet safe to actually push**
to either repo's main: `/opt/gelp` and `/opt/transigen` don't exist on the
node yet, so a live push would fire the webhook and `deploy.sh` would fail
on a missing working directory (harmless — just a failed CI run, nothing
gets corrupted).

*兩邊 GitHub webhook 都設定好了,Payload URL 用網域名稱、仍是 push-to-main
觸發。但現在還不能真的 push 到任一邊的 main——節點上 `/opt/gelp`、
`/opt/transigen` 都還沒 clone,webhook 觸發後 `deploy.sh` 會因為工作目錄不
存在而失敗(無害,只是 CI 失敗,不會弄壞任何東西)。*

### Day 2 stopping point / 今日收工點

Three repos have local commits not yet pushed (`platform`, `gelp`,
`transigen` — see the Outstanding checklist at the top). Gate 6 itself has
not started executing: next session picks up with the actual app onboarding
sequence per app — clone into `/opt/<app>`, provision its DB via
`cluster/data-postgres/provision-db.sh`, write its `.env.prod`/`env.prod`,
run `deploy/deploy.sh` by hand once to verify end-to-end before trusting the
already-configured webhook, then confirm `https://gelp.lans-h.cc` /
`https://transigen.lans-h.cc` serve with valid TLS.

*三個 repo 都有本機 commit 還沒 push(見檔案最上面的 Outstanding 清單)。Gate 6
本身還沒開始執行:下次從實際上車開始——clone 進 `/opt/<app>`、用
provision-db.sh 開通 DB、寫 `.env.prod`/`env.prod`、手動跑一次 deploy.sh
驗證整條路,再信任已經設定好的 webhook,最後確認兩個網域憑證有效、服務正常。*

---

## 2026-07-25 — Day 3: Gate 6 gelp onboarded (LIVE)

gelp is live at `https://gelp.lans-h.cc` — valid wildcard TLS, pod Running
1/1, 70 lists of real data, push-to-deploy proven end-to-end. Confirmed all
three repos were already pushed (checked with a real `git fetch`, not just
cached tracking refs; the Day-2 "unpushed" note was stale).

*gelp 上線:憑證有效、pod 正常、70 個清單的真實資料都在、push 自動部署整條
路跑通。三個 repo 先前其實都已 push(用 `git fetch` 實查確認,Day 2 記的
「未 push」是過時的)。*

### Onboarding sequence / 上車步驟

- **Clone, not `setup-server.sh`.** Plain `git clone` into `/opt/gelp`. gelp's
  old `deploy/setup-server.sh` is the from-zero node builder (installs k3s,
  webhook.service) — running it now would collide with what the platform repo
  already owns. It's Gate-7 retirement fodder.
- **Root needs its own GitHub deploy key.** `sudo git clone` runs as root, and
  root had no GitHub key → `Permission denied (publickey)`. Fix (per-app,
  least-privilege, matching the project's per-app-secret style): generate
  `/root/.ssh/gelp_deploy_key`, add the pubkey as a **read-only Deploy key** on
  the gelp repo, clone with `GIT_SSH_COMMAND`, then pin it for future
  webhook-triggered pulls with `git -C /opt/gelp config core.sshCommand`.
- **DB provision — role already existed.** `provision-db.sh PROVISION_APPS=gelp`
  reported `exists: role 'gelp_rw' — password untouched`. The prod `gelp_rw`
  pre-existed, so the password we passed was NOT applied. Re-ran with
  **`ROTATE=1`** to set it to the `.env.prod` value — safe because nothing was
  using the prod role yet (staging is a separate minikube Postgres). Used a
  fresh `openssl rand -hex 24` password to sidestep URL-encoding in
  `DATABASE_URL`.

*clone 不要用 setup-server.sh(那是從零建節點的舊腳本,會跟 platform 打
架,是 Gate 7 要退休的);root 要自己的 GitHub deploy key(`sudo git` 以 root
身分跑,root 沒 key → publickey denied,解法是 per-app read-only deploy key +
`core.sshCommand`);DB provision 時發現 prod `gelp_rw` 角色早就存在,密碼沒被
套用,要用 `ROTATE=1` 改成 `.env.prod` 的值(安全,prod 角色還沒人在用),密碼
用純 hex 避開 `DATABASE_URL` 的 URL-encoding 坑。*

### Three gelp-only `deploy.sh` bugs (all already fixed in transigen)

gelp's deploy script predated fixes transigen already had. The first manual
`sudo bash deploy/deploy.sh` surfaced them one by one:

1. **`sudo` secure_path.** `deploy.sh: line 61: k3s: command not found`. k3s
   installs into `/usr/local/bin`, which is on the PATH for an interactive
   login and for the webhook's systemd service — but `sudo` replaces PATH with
   its `secure_path` (`/sbin:/bin:/usr/sbin:/usr/bin` on OL9), which excludes
   `/usr/local/bin`. So bare `k3s`/`kubectl` fail under `sudo bash deploy.sh`
   (a webhook run is fine). Fix: `export PATH="/usr/local/bin:$PATH"` at the
   top of deploy.sh (commit `f002c33`). Same trap hits interactive
   `sudo k3s ctr ...` — use the full path `sudo /usr/local/bin/k3s`.
2. **image name mismatch → ImagePull.** Pod stuck "trying and failing to pull
   image". podman builds an unqualified tag as `localhost/gelp:latest`, but the
   pod spec's bare `gelp:latest` is normalized by containerd to
   `docker.io/library/gelp:latest` — not found locally → registry pull attempt
   → fail. First fix retagged to `docker.io/library/gelp:latest` (what
   transigen does), but that name is **misleading** for a locally-built image.
   Final fix: name the prod image **`localhost/gelp`** via the prod overlay's
   `images:` transformer (`newName: localhost/gelp`) — honest ("local, no
   registry"; containerd treats `localhost` as the registry host and never
   pulls) and needs no retag in deploy.sh (commit `396fe8a`). Staging untouched
   (its minikube `image load` path tolerates the bare name).
3. **data seed via Takeout re-upload, not pg_dump.** gelp's TODO planned a
   `pg_dump` from a preserved `gelp-pgdata` podman volume + re-pointing every
   `user_id` to a hardcoded UUID. That volume is gone and gelp was never really
   on prod before, so instead: log in to prod, **re-upload the Google Takeout
   zip** through the app's own `/import` flow, which auto-scopes the import to
   the logged-in user (`session.user.id`). Zero DB surgery. Verified:
   **70 lists / 5469 places / 5469 enriched / 5350 cached** — full Places-API
   enrichment worked. (prod user UUID is `ee55ef4e-…`, ≠ the stale
   `d79ce418-…` in the TODO.)

*三個 gelp 專屬的 deploy.sh bug(transigen 早就修好、gelp 腳本比較舊沒有):
(1) sudo 的 secure_path 不含 /usr/local/bin → 裸 `k3s`/`kubectl` 在
`sudo bash` 下 command not found(webhook 走 systemd PATH 沒事),修法是腳本頂
端 `export PATH`;手打 sudo 也要用全路徑。(2) podman build 出 `localhost/gelp`
但 pod spec 的裸 `gelp:latest` 被 containerd 正規化成 `docker.io/library/…`→
找不到→試著 registry pull 失敗;最終用 overlay 的 `newName: localhost/gelp`
誠實命名(不用誤導的 docker.io/library retag)。(3) 資料 seed 改用 app 自己的
`/import` 重傳 Takeout zip(自動歸給登入者),不做 pg_dump/改 UUID 的手術;結果
70 清單 / 5469 地點全數 enrich。*

### Command transcript / 指令實錄

Verbatim, in execution order on the node (`opc@louis2`), Mac-side git ops
noted where they interleave.

**1. Clone as root fails — no GitHub key for root:**

```
$ sudo git clone --branch main git@github.com:amdslancelot/gelp.git /opt/gelp
Cloning into '/opt/gelp'...
The authenticity of host 'github.com (140.82.121.4)' can't be established.
...
git@github.com: Permission denied (publickey).
fatal: Could not read from remote repository.
```

Fix — per-app read-only deploy key for root, then clone with it and pin it for
future webhook pulls:

```
$ sudo ssh-keygen -t ed25519 -f /root/.ssh/gelp_deploy_key -N "" -C "louis2-gelp-deploy"
$ sudo cat /root/.ssh/gelp_deploy_key.pub          # → add as a read-only Deploy key on the gelp repo
$ sudo GIT_SSH_COMMAND="ssh -i /root/.ssh/gelp_deploy_key -o IdentitiesOnly=yes" \
    git clone --branch main git@github.com:amdslancelot/gelp.git /opt/gelp
$ sudo git -C /opt/gelp config core.sshCommand "ssh -i /root/.ssh/gelp_deploy_key -o IdentitiesOnly=yes"
```

**2. Provision the DB — role already existed (password NOT applied):**

```
$ kubectl -n data exec -i deploy/postgres -- \
    env PROVISION_APPS="gelp" GELP_DB_PASSWORD="$GELP_DB_PASSWORD" \
    bash -s < cluster/data-postgres/provision-db.sh
REVOKE
REVOKE
exists: role 'gelp_rw' — password untouched (set ROTATE=1 to rotate)
REVOKE
GRANT
provisioned: database 'gelp' owned by role 'gelp_rw'
app provisioning complete: gelp
```

Re-run with `ROTATE=1` to set the password to the `.env.prod` (hex) value:

```
$ kubectl -n data exec -i deploy/postgres -- \
    env PROVISION_APPS="gelp" ROTATE=1 GELP_DB_PASSWORD="$GELP_DB_PASSWORD" \
    bash -s < cluster/data-postgres/provision-db.sh
...
ALTER ROLE
rotated: password for existing role 'gelp_rw'
...
app provisioning complete: gelp
```

**3. First manual deploy — builds, then bug #1 (secure_path):**

```
$ cd /opt/gelp && sudo bash deploy/deploy.sh
==> Deploying Gelp from /opt/gelp
==> Pulling latest changes (git pull --ff-only)
Already up to date.
==> Building gelp:latest with podman
[1/2] STEP 1/7: FROM node:22-alpine AS builder
   ... (image build, npm ci, next build — succeeds) ...
Successfully tagged localhost/gelp:latest
==> Importing gelp:latest into k3s containerd
deploy/deploy.sh: line 61: k3s: command not found
```

Fixed on the Mac (`export PATH="/usr/local/bin:$PATH"` at top of deploy.sh),
commit `f002c33`, `git push` → webhook redeploy.

**4. Pod won't start — bug #2 (image name → ImagePull):**

```
$ kubectl -n gelp logs deploy/gelp
Found 2 pods, using pod/gelp-56d9ffd5c8-s2j6p
Error from server (BadRequest): container "gelp" in pod "gelp-56d9ffd5c8-s2j6p" is waiting to start: trying and failing to pull image
```

Fixed on the Mac (prod overlay `newName: localhost/gelp`), commit `396fe8a`,
`git push` → webhook redeploy.

**5. Verify — bug #1 also bites the interactive command; use the full path:**

```
$ sudo k3s ctr images ls | grep gelp
sudo: k3s: command not found
$ sudo /usr/local/bin/k3s ctr images ls | grep gelp
docker.io/library/gelp:latest   ...  sha256:aea61c5f...  214.4 MiB  linux/arm64  ...
localhost/gelp:latest           ...  sha256:aea61c5f...  214.4 MiB  linux/arm64  ...

$ kubectl -n gelp get pods
NAME                    READY   STATUS    RESTARTS   AGE
gelp-79c8dbfb86-bqlcg   1/1     Running   0          7m36s

$ curl -sI https://gelp.lans-h.cc | head -1
HTTP/2 302
$ curl -sI https://gelp.lans-h.cc | grep -i location
location: https://gelp.lans-h.cc/login

$ sudo /usr/local/bin/k3s ctr images rm docker.io/library/gelp:latest   # prune the debug leftover
docker.io/library/gelp:latest
```

**6. Data seed — Takeout re-upload via the app's `/import`, then verify in DB:**

```
$ kubectl -n data exec -i deploy/postgres -- \
    psql -U postgres -d gelp -c "select id, email, google_sub from users;" \
    -c "select count(*) as lists from lists;" -c "select count(*) as places from places;"
                  id                  |        email        |      google_sub
--------------------------------------+---------------------+-----------------------
 ee55ef4e-0800-4af9-9a5f-66764d45ee9b | lansoulot@gmail.com | 108579144711269239719
(1 row)
 lists  = 0        # before upload
 places = 0

# ... upload the Takeout zip at https://gelp.lans-h.cc/import (logged in) ...

$ kubectl -n data exec -i deploy/postgres -- psql -U postgres -d gelp \
    -c "select count(*) from lists;"  -c "select count(*) from places;" \
    -c "select count(*) from places where cache_key is not null;" \
    -c "select count(*) from place_cache;"
 lists         = 70
 places        = 5469
 enriched      = 5469     # every place resolved via Places API
 cached_places = 5350     # place_cache dedupes identical real-world places
```

*節點上按執行順序的逐字實錄(Mac 端的 git 操作在對應處註明):(1) root clone
失敗→per-app 唯讀 deploy key 修好;(2) provision 發現角色已存在、密碼沒套用→
`ROTATE=1` 重跑;(3) 首次手動 deploy 建置成功但踩 secure_path(line 61 k3s not
found);(4) pod ImagePull(image 命名);(5) 驗證時互動指令也踩同一坑,改用全路
徑,pod Running、curl 302→/login、清掉 debug 殘留映像;(6) 用 app 的 `/import`
重傳 Takeout,DB 驗證 70/5469/5469/5350。*

### Concepts / questions raised (學到的觀念 · 問過的問題)

Conceptual questions that came up while onboarding gelp, with the answer
essence — kept because the *why* is the reusable part, and one of them (#9)
directly drove a design decision.

1. **Why does gelp's `postgres-shared-cluster` branch exist, and why is its
   content already in `main`?** It was the feature branch for the
   SQLite→Postgres + shared-cluster-deploy work. `main` fast-forwarded past its
   tip (linear history, no merge commit), so the branch is now a stale bookmark
   fully contained in `main` — safe to `git branch -d`.
2. **Can `GELP_DB_PASSWORD` just be the value in `.env.prod`?** Yes — they
   *must* be identical: `provision-db.sh` CREATEs the role with it, and
   `.env.prod`'s `DATABASE_URL` authenticates as that role. Caveat: the URL
   needs special chars **percent-encoded** while the provision env var takes the
   **raw** value — so a special-char password has two different spellings and is
   easy to mismatch. Using pure `hex` avoids the whole trap.
3. **What are `AUTH_SECRET` / `CRON_SECRET` / `DRIVE_FOLDER_ID` for?**
   `AUTH_SECRET` = Auth.js session/JWT signing key (leak ⇒ forge any user's
   login). `CRON_SECRET` = bearer token guarding the nightly `/api/cron/import`
   endpoint so only the CronJob can call it. `DRIVE_FOLDER_ID` = the Drive
   folder id the nightly sync pulls the newest Takeout from (an id, not a
   secret).
4. **Why can't `AUTH_SECRET` reuse the dev/staging one?** It's a *symmetric*
   key — whoever holds it can forge sessions, so its blast radius is every place
   it exists. dev/staging is lower-protection (shared `.env`, screenshots,
   backups); sharing means a dev leak forges **prod** sessions, and you lose
   independent rotation. Same logic as the project's per-app secrets, applied
   per-environment.
5. **Isn't `DRIVE_FOLDER_ID` supposed to be per-user?** The main app *is*
   multi-user (lists/places scoped to `session.user.id`; manual upload is
   per-user and uses no `DRIVE_FOLDER_ID`). `DRIVE_FOLDER_ID` belongs only to
   the headless nightly CronJob, which has no session → single service account +
   single folder + `allowedEmails()[0]`. It's a single-tenant convenience
   feature sitting *beside* multi-user login, not a gap in it. (I first
   over-stated "gelp's import is single-user"; the user pushed back and I
   corrected it — hence the new per-user-Drive-sync item in gelp's `TODO.md`.)
6. **What is `AUTH_TRUST_HOST`, and which "host"?** The incoming request's
   `Host` / `X-Forwarded-Host` header — the domain the client claims to be
   reaching (`gelp.lans-h.cc`). Auth.js uses it to build absolute callback URLs
   and, in production, distrusts it by default (host-header injection could
   redirect the OAuth callback — with its token — to an attacker's domain).
   Behind Traefik you set it `true` because the proxy, which *you* control,
   overwrites that header.
7. **Whose API key is `GOOGLE_MAPS_API_KEY`?** Not any end-user's — a
   server-side API key created in *your* Google Cloud project, billed to you,
   used by the server for every enrichment call regardless of who's logged in.
   Distinct from the OAuth client (`AUTH_GOOGLE_*`, user identity) and the
   service account (`GOOGLE_SERVICE_ACCOUNT_KEY_BASE64`, Drive).
8. **Why `docker.io`?** It's the default registry in image-reference
   normalization: a bare `gelp:latest` expands to `docker.io/library/gelp:latest`
   (registry `docker.io`, namespace `library`, tag `latest`), and that's the
   fully-qualified name containerd actually looks up.
9. **"I don't want `docker.io/library/` — it feels misleading."** Correct — the
   image is built locally and never comes from Docker Hub. This objection is
   what drove the **final** fix: name the prod image `localhost/gelp` instead
   (honest "local, no registry"; containerd treats `localhost` as the registry
   host so it never normalizes to docker.io and never pulls), superseding the
   docker.io/library retag (commit `396fe8a`).
10. **Why isn't `/usr/local/bin` in the sudo environment?** It *is* on the PATH
    for an interactive login and for systemd services — but `sudo` deliberately
    replaces PATH with its own `secure_path` (a trusted minimal list) to prevent
    PATH-injection privilege escalation, and on OL9 that list excludes
    `/usr/local/bin` (FHS: locally-installed, not distro-managed). Hence the
    full-path / PATH-prepend workarounds.
11. **What does `-C` do (ssh-keygen)?** Sets the key's *comment* — a
    human-readable label appended to the `.pub` (e.g. `louis2-gelp-deploy`) to
    tell keys apart in GitHub's Deploy-keys list; no effect on security or
    function.

Earlier days' conceptual Q&A, recorded here for completeness: **k3s reinstall
didn't disrupt Postgres/app** because the containerd-shim decouples running
containers from the daemon lifecycle (kubelet reconciles, doesn't recreate);
**the node runs SQLite, not etcd** (single-node k3s default; etcd is only for
HA multi-server quorum and CPU is the binding resource here); **the `deploy` in
`deploy.lans-h.cc` is semantically meaningless** (the `*.lans-h.cc` wildcard maps
any label to the node IP — the label is human legibility only); **adnanh/webhook
does not route by `Host` header** (one `:9000` listener, routing purely by URL
path `/hooks/<id>`, so ids must be globally unique).

*上車 gelp 過程中冒出的概念問題,記下答案精華——「為什麼」才是能重用的部分,
其中 #9 還直接驅動了一個設計決定。*

*(1) `postgres-shared-cluster` 是 SQLite→Postgres + 共用叢集部署的 feature
branch,main 已 fast-forward 越過它、線性含入,所以它是能安全刪的過時書籤。
(2) `GELP_DB_PASSWORD` 必須跟 `.env.prod` 一致(provision 建角色、URL 用它認
證);特殊字元在 URL 要 percent-encode、給 provision 要原始值,兩種寫法容易對不
上,用 hex 免煩惱。(3) `AUTH_SECRET`=Auth.js 簽 session 的鑰(外洩=偽造任何人
登入)、`CRON_SECRET`=守夜間匯入端點的 bearer token、`DRIVE_FOLDER_ID`=夜間同
步要抓的 Drive 資料夾 id(是 id 不是密鑰)。(4) `AUTH_SECRET` 是對稱鑰,爆炸半
徑=它存在的所有地方,dev 那份保護弱,共用等於 dev 外洩就能偽造 prod session,
還沒法獨立輪替。(5) 主 app 是多人的(lists/places 綁 session、手動上傳 per-user
且不用 `DRIVE_FOLDER_ID`);`DRIVE_FOLDER_ID` 只屬於無 session 的夜間 CronJob,
那是單租戶便利功能,不是多人登入的缺口(我一開始講太滿說「匯入是單人」,你反駁
後修正,也因此在 TODO 加了 per-user Drive 同步的功能項)。(6) `AUTH_TRUST_HOST`
的 host = 請求的 `Host`/`X-Forwarded-Host`(客戶端聲稱的網域);prod 預設不信任
以防 host-header 注入把 OAuth 回呼導去惡意網域,在 Traefik 後面因為 header 是你
自己的代理覆寫的所以設 true。(7) `GOOGLE_MAPS_API_KEY` 不是使用者的,是你
Google Cloud 專案裡的 server 端 key,記你帳、所有 enrichment 共用,跟 OAuth
client、service account 是三種不同東西。(8) `docker.io` 是映像名正規化的預設
registry:裸 `gelp:latest`→`docker.io/library/gelp:latest`,那才是 containerd
去找的全名。(9)「不想用 docker.io/library、覺得誤導」——對,本地映像根本不從
Docker Hub 來;這個反對驅動了最終改用 `localhost/gelp` 的命名(誠實、containerd
把 localhost 當 registry host 永不 pull),取代 docker.io retag。(10)
`/usr/local/bin` 其實有在一般/systemd PATH 裡,是 sudo 刻意用自己的 secure_path
(受信任精簡清單,防 PATH 注入提權)取代掉,OL9 那份剛好不含它。(11) ssh-keygen
的 `-C` 是設 key 的 comment(給人看的標籤),不影響安全或功能。更早幾天的概念問
答:k3s 重裝不影響 Postgres/app 是因為 containerd-shim 讓執行中容器與 daemon 生
命週期解耦(kubelet 對帳而非重建);節點用 SQLite 非 etcd(單節點預設,etcd 只
為多 server HA,而這裡 CPU 是瓶頸);`deploy.lans-h.cc` 的 `deploy` 語意上無意義
(wildcard 把任何 label 都解到節點 IP,純為好認);adnanh/webhook 不看 Host
header(單一 :9000 listener,只靠路徑 `/hooks/<id>` 路由,故 id 要全域唯一)。*

### Follow-ups / 待辦

- Optional hardening: `shred -u /opt/gelp/.env.prod` (deploy.sh's "secret
  exists → leave as-is" branch runs fine without it after first deploy).
- Next: **transigen** onboarding (same shape; its deploy.sh already handles
  the image name — verify it also has the PATH fix), then **my_website**.
- Cleanup leftover from the debug: the intermediate
  `docker.io/library/gelp:latest` image was pruned from containerd
  (`k3s ctr images rm`).

*可選加固:shred 掉 `.env.prod`;下一步 transigen(同套路,它 deploy.sh 已處理
image 命名,確認有沒有 PATH fix),再 my_website;debug 過程留下的
`docker.io/library/gelp:latest` 中間映像已從 containerd 清掉。*
