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
| 6 | app 上車(gelp → transigen → my_website) | ⬜ | — |
| 7 | 清理各 app repo 舊副本 | ⬜ | — |

**Outstanding / 未結事項**
- [ ] Cloudflare API token 曾在對話中以明文出現 → 全部完成後去 Cloudflare **Roll**
      一把新值並更新 `cloudflare-api-token` Secret。
- [ ] Cloudflare 殘留的 `_acme-challenge` TXT 記錄順手清掉(無害,純衛生)。
- [x] Gate 5 需產生 `GELP_WEBHOOK_SECRET` / `TRANSIGEN_WEBHOOK_SECRET` 並存入密碼
      管理器(Gate 6 在 GitHub 設 webhook 要用同一把)——密碼已由使用者存放,
      同一把值 Gate 6 設定 GitHub webhook 時要重用。

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
