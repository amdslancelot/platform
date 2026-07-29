# Security Posture Audit — louis2 / lans-h.cc fleet

*資安態勢稽核 — louis2 / lans-h.cc 機隊*

**Date / 日期:** 2026-07-27  **Scope / 範圍:** the single OCI A1.Flex node `louis2`
(2 OCPU / 12 GB, Oracle Linux 9, aarch64) and the single-node k3s cluster on it,
serving snoopy / gelp / transigen / my_website.
**Method / 方法:** read-only inspection of the live node and cluster; no changes
were made during the audit.

*範圍是那一台 OCI A1.Flex 節點 `louis2`(2 OCPU / 12 GB、Oracle Linux 9、aarch64)
與其上的單節點 k3s,承載 snoopy / gelp / transigen / my_website。方法是對線上節點
與叢集做唯讀檢查;稽核過程沒有做任何變更。*

This document is the ranked findings list. The fixes themselves are tracked in
`docs/runbook.md` once applied.

*本文件是排序後的發現清單。修復動作實際套用後,記錄在 `docs/runbook.md`。*

---

## 0. Summary

*結論摘要*

The **data layer is genuinely isolated** — per-app database, per-app LOGIN-only
role, `REVOKE CONNECT … FROM PUBLIC`, and a provisioning script that ends by
proving the isolation holds. Delivery is authenticated by HMAC rather than
trusted by origin. TLS and SSH are in good shape.

*資料層的隔離是真的 —— 每個 app 一個資料庫、一個 LOGIN-only role、
`REVOKE CONNECT … FROM PUBLIC`,而且開通腳本最後會實際驗證隔離成立。部署通道靠
HMAC 驗證而非信任來源。TLS 與 SSH 的狀態良好。*

**Everything above the data layer is upstream defaults.** No secrets encryption,
no NetworkPolicy, no Pod Security Admission, no audit log, and no workload
hardening on any first-party manifest. The only workloads running with a
`securityContext` are third-party charts (cert-manager, Traefik, CoreDNS) that
shipped hardened; every manifest written in-house runs as root with the default
ServiceAccount.

***資料層以上,全部是上游預設值。*** *沒有 secrets 加密、沒有 NetworkPolicy、沒有
Pod Security Admission、沒有 audit log,自有的 manifest 一律沒有 workload 加固。
唯一帶 `securityContext` 的 workload 是本來就出廠加固的第三方 chart
(cert-manager、Traefik、CoreDNS);所有自己寫的 manifest 都以 root 執行、用 default
ServiceAccount。*

| # | Finding / 發現 | Severity |
|---|---|---|
| 1 | Kubernetes Secrets stored unencrypted | High |
| 2 | cluster-admin kubeconfig is world-readable (mode 644) | High |
| 3 | First-party workloads run as root with no `securityContext` | High |
| 4 | No NetworkPolicy anywhere — flat pod network | High |
| 5 | No Pod Security Admission on any namespace | High |
| 6 | No API-server audit logging | Medium |
| 7 | `rpcbind` listening on `0.0.0.0:111` | Medium |
| 8 | API server (6443) and kubelet (10250) bound to `0.0.0.0`, no host firewall | Medium |
| 9 | `NOPASSWD` sudo on `/usr/local/bin/k3s` is effectively passwordless root | Medium |
| 10 | No resource limits on postgres / my_website / Traefik / cert-manager | Medium |
| 11 | 61 pending security errata (1 Critical) | Medium |

---

## 1. Kubernetes Secrets stored unencrypted — High

*Kubernetes Secret 未加密儲存 — 高*

**Evidence / 證據**

```sh
sudo /usr/local/bin/k3s secrets-encrypt status   # 查詢 k3s 的 secrets 加密狀態
# → Encryption Status: Disabled, no configuration file found
```

**Impact / 影響** — every app database password, the Cloudflare API token, the
webhook HMAC secrets, the Google OAuth client secret and the Gemini API key sit
in the k3s datastore as base64, which is an encoding, not encryption. Anyone who
can read the datastore file — or restore a backup of it — reads every credential
in the fleet in plaintext.

*機隊裡每個 app 的資料庫密碼、Cloudflare API token、webhook HMAC secret、Google
OAuth client secret、Gemini API key,全都以 base64 存在 k3s 的資料存放區裡 ——
base64 是編碼,不是加密。任何能讀到那個檔案(或還原它的備份)的人,就能拿到機隊全部
憑證的明文。*

**Fix / 修法** — enable `--secrets-encryption` on the k3s server and rotate the
key afterwards. Requires a k3s restart (brief interruption for all four apps);
back up the datastore first. Verify the same way staging was verified: plant a
marker string in a Secret and grep the raw datastore for it.

*在 k3s server 加上 `--secrets-encryption` 並在之後輪替金鑰。需要重啟 k3s(四個
app 會短暫中斷),事前先備份資料存放區。驗證方式沿用 staging 那套:在 Secret 裡種
一個標記字串,再對底層資料檔 grep 它。*

> Note: the staging minikube cluster (owned by `snoopy_home`) has had AES-CBC
> encryption-at-rest enabled and verified at the byte level since
> `snoopy_home/learning/encryption-at-rest-journey.md`. Production never got it.
>
> *註:staging 的 minikube(由 `snoopy_home` 擁有)早就啟用並在位元組層級驗證過
> AES-CBC 加密,見該 repo 的 `learning/encryption-at-rest-journey.md`。正式環境
> 從來沒有跟上。*

---

## 2. cluster-admin kubeconfig is world-readable — High

*cluster-admin kubeconfig 全世界可讀 — 高*

**Evidence / 證據**

```sh
ls -l /etc/rancher/k3s/k3s.yaml                  # 檢查 kubeconfig 權限
# → -rw-r--r--. 1 root root 2941 ... /etc/rancher/k3s/k3s.yaml
```

**Impact / 影響** — that file holds cluster-admin client credentials. Mode 644
means *any* local user, and any process running as any user on the node, reads
it and becomes cluster-admin. It is the escalation step that turns a foothold in
one container into control of the whole cluster.

*那個檔案裡是 cluster-admin 的用戶端憑證。644 代表節點上**任何**本機使用者、任何
以任何身分執行的行程,都能讀走它並取得 cluster-admin。它就是把「某個容器裡的立足
點」升級成「整個叢集的控制權」的那一步。*

This is a **deliberate decision** recorded in `bootstrap/bootstrap-node.sh` — the
non-root SSH user `opc` runs bare `kubectl`, and snoopy's CI depends on it. The
decision is understandable; the blast radius was not stated alongside it.

*這是 `bootstrap/bootstrap-node.sh` 裡**刻意**的決定 —— 非 root 的 SSH 使用者
`opc` 要能直接跑 `kubectl`,snoopy 的 CI 也依賴它。這個取捨可以理解,但當初沒有把
影響半徑一併寫下來。*

**Fix / 修法** — restore `0600` root-only, and give `opc` a *separate* kubeconfig
bound to a ServiceAccount with only the RBAC verbs its deploys actually need
(`get`/`patch` on the app Deployments, `create` on Secrets in its own namespace).
That satisfies the same workflow without handing out cluster-admin.

*改回 `0600` 只有 root 可讀,另外給 `opc` 一份**獨立的** kubeconfig,綁在一個
ServiceAccount 上,只授予部署真正需要的 RBAC 動詞(對 app Deployment 的
`get`/`patch`、對自己 namespace 內 Secret 的 `create`)。同樣的工作流程做得到,但
不必發出 cluster-admin。*

---

## 3. First-party workloads run as root with no securityContext — High

*自有 workload 以 root 執行且無 securityContext — 高*

**Evidence / 證據**

```sh
# 列出所有 workload 的安全設定與 ServiceAccount
kubectl get deploy,sts -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} runAsNonRoot={.spec.template.spec.securityContext.runAsNonRoot} privesc={.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation} ro-root={.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem} sa={.spec.template.spec.serviceAccountName}{"\n"}{end}'
```

```
cert-manager/cert-manager   runAsNonRoot=true privesc=false ro-root=true sa=cert-manager
kube-system/traefik         runAsNonRoot=true privesc=false ro-root=true sa=traefik
kube-system/coredns         runAsNonRoot=     privesc=false ro-root=true sa=coredns
data/postgres               runAsNonRoot=     privesc=      ro-root=     sa=
gelp/gelp                   runAsNonRoot=     privesc=      ro-root=     sa=
snoopy/snoopy               runAsNonRoot=     privesc=      ro-root=     sa=
transigen/transigen         runAsNonRoot=     privesc=      ro-root=     sa=
web/lans-h-site             runAsNonRoot=     privesc=      ro-root=     sa=
```

**Impact / 影響** — the only hardened workloads are the ones someone else
hardened. Every in-house app runs as uid 0 inside its container, with privilege
escalation permitted, a writable root filesystem, all default capabilities, and
the namespace `default` ServiceAccount — whose token is auto-mounted into the
pod and can be used against the API server.

*唯三加固過的 workload,都是別人幫忙加固的。所有自有 app 在容器內以 uid 0 執行、
允許權限提升、root 檔案系統可寫、保留全部預設 capabilities,並使用 namespace 的
`default` ServiceAccount —— 它的 token 會自動掛進 pod,可以拿去對 API server 用。*

**Fix / 修法** — add to every first-party pod spec: `runAsNonRoot: true`,
`runAsUser`/`runAsGroup`, `allowPrivilegeEscalation: false`,
`readOnlyRootFilesystem: true` (with `emptyDir` for anything that must write),
`capabilities: { drop: [ALL] }`, `seccompProfile: RuntimeDefault`, and
`automountServiceAccountToken: false` for the apps that never call the API.

*在每個自有 pod spec 加上:`runAsNonRoot: true`、`runAsUser`/`runAsGroup`、
`allowPrivilegeEscalation: false`、`readOnlyRootFilesystem: true`(需要寫入的路徑
掛 `emptyDir`)、`capabilities: { drop: [ALL] }`、`seccompProfile: RuntimeDefault`,
以及對不呼叫 API 的 app 設 `automountServiceAccountToken: false`。*

---

## 4. No NetworkPolicy anywhere — High

*完全沒有 NetworkPolicy — 高*

**Evidence / 證據**

```sh
kubectl get netpol -A                            # 列出所有 NetworkPolicy
# → No resources found
```

**Impact / 影響** — the pod network is flat. gelp's pod can open a TCP connection
to Postgres, to snoopy, to transigen, to the kubelet on `:10250`, and to the API
server on `:6443`. The per-app database isolation (roles and grants) is real, but
it is the *only* layer: nothing at the network layer stops one compromised app
from reaching another app's data plane and attempting its credentials.

*Pod 網路是扁平的。gelp 的 pod 可以直接對 Postgres、snoopy、transigen、kubelet 的
`:10250`、API server 的 `:6443` 開 TCP 連線。每個 app 的資料庫隔離(role 與 grant)
是真的,但它是**唯一**一層:網路層沒有任何東西阻止一個被攻陷的 app 連到另一個 app
的資料平面去嘗試憑證。*

**Fix / 修ath** — default-deny ingress and egress per app namespace, then allow
exactly: Traefik → app, app → `postgres.data.svc:5432`, app → DNS. This is the
layer that turns "isolated by credentials" into "isolated by credentials *and*
reachability".

*每個 app namespace 先 default-deny ingress 與 egress,再明確放行:Traefik → app、
app → `postgres.data.svc:5432`、app → DNS。這一層才把「靠憑證隔離」變成「靠憑證
**加上**可達性隔離」。*

---

## 5. No Pod Security Admission — High

*沒有 Pod Security Admission — 高*

**Evidence / 證據**

```sh
# 檢查每個 namespace 的 PSA enforce 標籤
kubectl get ns -o custom-columns=NS:.metadata.name,ENFORCE:.metadata.labels.'pod-security\.kubernetes\.io/enforce'
# → 11 namespaces, ENFORCE=<none> on all of them
```

**Impact / 影響** — nothing prevents a pod from requesting `privileged: true`,
`hostNetwork`, `hostPID`, or a `hostPath` mount of `/`. Any path that can create
a pod — a compromised CI credential, a mis-scoped RBAC role — can escape to the
host in one step.

*沒有任何東西阻止一個 pod 要求 `privileged: true`、`hostNetwork`、`hostPID`,或
`hostPath` 掛載 `/`。任何能建立 pod 的路徑(被盜的 CI 憑證、範圍過寬的 RBAC role)
都能一步逃逸到主機。*

**Fix / 修法** — label app namespaces `pod-security.kubernetes.io/enforce=restricted`
(warn/audit first to catch what breaks), and `baseline` for `kube-system` and
`data` where the workloads legitimately need more.

*把 app 的 namespace 標上 `pod-security.kubernetes.io/enforce=restricted`(先用
warn/audit 觀察會壞掉什麼),`kube-system` 與 `data` 這些 workload 確實需要較多權限
的則用 `baseline`。*

---

## 6. No API-server audit logging — Medium

*API server 沒有 audit log — 中*

```sh
sudo grep -cE 'kube-apiserver-arg|admission' /etc/systemd/system/k3s.service
# → 0
```

There is no record of who did what against the cluster API. After an incident
there would be nothing to reconstruct from. Fix: `--kube-apiserver-arg` with an
audit policy and log path, at `Metadata` level to keep the volume sane on a
2-core node.

*叢集 API 上誰做了什麼,沒有任何紀錄。事故之後沒有東西可以回溯。修法:用
`--kube-apiserver-arg` 指定 audit policy 與 log 路徑,層級用 `Metadata` 以免在兩核
的機器上產生過大的量。*

---

## 7. `rpcbind` listening on `0.0.0.0:111` — Medium

*`rpcbind` 對外監聽 `0.0.0.0:111` — 中*

```sh
sudo ss -tlnp | grep -v '127.0.0.1\|::1'         # 列出非本機的監聽通訊埠
# → LISTEN 0.0.0.0:111  users:(("rpcbind",...))
```

Nothing on this node uses NFS or any RPC service. It is attack surface with no
compensating benefit, and historically a source of amplification abuse and CVEs.
Fix: `systemctl disable --now rpcbind.socket rpcbind`.

*這台機器沒有任何東西用到 NFS 或 RPC 服務。它是純粹多出來的攻擊面,沒有任何對應的
好處,而且歷史上是放大攻擊與 CVE 的來源。修法:
`systemctl disable --now rpcbind.socket rpcbind`。*

---

## 8. API server and kubelet bound to `0.0.0.0` with no host firewall — Medium

*API server 與 kubelet 綁在 `0.0.0.0` 且主機無防火牆 — 中*

```sh
sudo systemctl is-active firewalld               # → inactive
sudo iptables -S INPUT | head -1                 # → -P INPUT ACCEPT
sudo ss -tlnp | grep -E ':6443|:10250'           # 兩者都綁在 *:port
```

`firewalld` is disabled on purpose (`bootstrap-node.sh` §3: "the OCI security
list is the packet filter"). That is defensible, but it makes a **single cloud
console rule the only thing** between the internet and the Kubernetes API and
the kubelet. There is no second layer if that rule is ever edited wrongly.

*`firewalld` 是刻意關掉的(`bootstrap-node.sh` 第 3 節:「OCI security list 就是封包
過濾器」)。這個取捨說得通,但它讓**雲端 console 的一條規則成為唯一屏障**,擋在網際
網路與 Kubernetes API、kubelet 之間。那條規則哪天被改錯,就沒有第二層了。*

Fix: keep the security list as the primary control, and add a host-level
`nftables`/`firewalld` rule allowing 6443/10250 only from the node itself and the
pod CIDR — defence in depth for two ports, not a general firewall re-enable.

*修法:security list 仍是主要控制,另外加一條主機層 `nftables`/`firewalld` 規則,只
允許節點自己與 pod CIDR 存取 6443/10250 —— 是為兩個通訊埠加縱深,不是把防火牆整個
重新打開。*

---

## 9. `NOPASSWD` sudo on `k3s` is effectively root — Medium

*對 `k3s` 的 `NOPASSWD` sudo 實質等於 root — 中*

```sh
sudo cat /etc/sudoers.d/k3s-ctr
# → opc ALL=(ALL) NOPASSWD: /usr/local/bin/k3s
```

The rule was added for one narrow purpose — `sudo k3s ctr images import` in
snoopy's CI. But the `k3s` binary is a multi-tool: `k3s ctr run --privileged`
with a host mount is a one-liner to root. The grant is far wider than the intent.

*這條規則是為了一個很窄的用途加的 —— snoopy CI 裡的 `sudo k3s ctr images import`。
但 `k3s` 這個 binary 是多合一工具:`k3s ctr run --privileged` 搭配主機掛載,一行就是
root。授權範圍遠大於當初的意圖。*

Fix: narrow the sudoers entry to the exact `ctr -n k8s.io images import` argument
form, or move image import to a path that does not need sudo at all.

*修法:把 sudoers 條目收窄到 `ctr -n k8s.io images import` 這個精確的參數形式,或
把 image import 改成完全不需要 sudo 的路徑。*

---

## 10. Missing resource limits — Medium

*缺少 resource limits — 中*

`data/postgres`, `web/lans-h-site`, `kube-system/traefik` and the cert-manager
deployments carry no CPU/memory limits. On a 2-core / 12 GB node shared by four
apps plus the control plane, one runaway workload starves everything else. This
is an availability control, and on this node it is a realistic one.

*`data/postgres`、`web/lans-h-site`、`kube-system/traefik` 與 cert-manager 的
deployment 都沒有 CPU/記憶體上限。在一台兩核 12 GB、由四個 app 加控制平面共用的機器
上,單一失控的 workload 就能餓死其他所有東西。這是可用性控制,而且在這台機器上是很
實際的風險。*

---

## 11. 61 pending security errata — Medium

*61 個未套用的安全公告 — 中*

```sh
dnf updateinfo summary                           # 未套用的公告統計
# → 61 Security notice(s): 1 Critical, 39 Important, 17 Moderate, 4 Low
```

Fix: `sudo dnf update --security`, then keep it current. Ksplice is already
configured on this node for kernel updates without reboot.

*修法:`sudo dnf update --security`,之後保持更新。這台機器已經設定好 Ksplice,核心
更新不需要重開機。*

---

## 12. Attack chain

*攻擊鏈*

Findings 3, 4, 5 and 2 compose into a single path from "one app has a bug" to
"the whole fleet's credentials are readable":

*發現 3、4、5、2 串起來,構成一條從「某個 app 有漏洞」到「整個機隊的憑證都讀得到」
的完整路徑:*

```
RCE in any one app
  → the container is already root, privilege escalation permitted   (#3)
  → no Pod Security Admission blocks a privileged/hostPath pod      (#5)
  → no NetworkPolicy limits lateral reach to other apps or kubelet  (#4)
  → node foothold reads /etc/rancher/k3s/k3s.yaml (mode 644)        (#2)
  → cluster-admin
  → every Secret in every namespace, in plaintext                   (#1)
```

No single finding here is exotic. The chain is short because there is no layer
between the application and cluster-admin.

*這裡沒有任何一項發現是罕見的。這條鏈之所以短,是因為應用程式與 cluster-admin 之間
沒有任何一層。*

---

## 13. What is already in place

*已經到位的部分*

Worth stating explicitly so the fixes above are not read as "nothing was done":

*明確寫出來,免得上面的清單被讀成「什麼都沒做」:*

- **SELinux `Enforcing`** on the node.
- **SSH**: public-key only, `passwordauthentication no`, no empty passwords.
- **Network edge**: only 22 / 80 / 443 / 9000 reachable from the internet.
- **Data isolation**: database per app, LOGIN-only least-privilege role per app,
  `REVOKE CONNECT … FROM PUBLIC`, and `provision-db.sh` ends by *verifying* that
  a peer's database is refused and the role holds no
  superuser/CREATEDB/CREATEROLE.
- **Delivery**: HMAC-signed webhooks (`X-Hub-Signature-256`), per-app read-only
  deploy keys, CI build gate in front of gelp and transigen.
- **TLS**: one wildcard certificate issued by ACME DNS-01, served as Traefik's
  default — no app handles key material.
- **Documented trust boundaries**: where a control was deliberately *not* added
  (in-cluster Postgres without TLS, `:9000` on plain HTTP with HMAC), the
  reasoning is recorded next to the decision in `CLAUDE.md`.

---

## 14. Remediation plan

*修復計畫*

| Phase | Contents | Risk / downtime |
|---|---|---|
| **A** | This document | none |
| **B** | PSA labels, NetworkPolicies, workload `securityContext`, resource limits, disable `rpcbind`, kubeconfig `0600` + scoped RBAC kubeconfig for `opc` | low; NetworkPolicy can break traffic — apply per namespace and verify |
| **C** | `--secrets-encryption` + key rotation, API-server audit log, host firewall for 6443/10250 | **k3s restart — brief interruption for all four apps**; back up the datastore first |
| **D** | Trivy image scanning, gitleaks, Dependabot in CI; apply the 61 security errata | low |

*A 是本文件;B 是零中斷的加固;C 需要重啟 k3s,四個 app 會短暫中斷,事前先備份資料
存放區;D 是 CI 掃描與套用安全更新。*

Verification for phase C mirrors what was done on staging: plant a marker string
in a Secret, grep the raw datastore for it (expect absent), confirm the
ciphertext prefix is present, and read the Secret back through `kubectl` to prove
decryption still works.

*C 階段的驗證沿用 staging 的做法:在 Secret 裡種標記字串、對底層資料檔 grep(預期
找不到)、確認密文前綴存在、再用 `kubectl` 讀回來確認解密仍正常。*
