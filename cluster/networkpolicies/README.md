# NetworkPolicies — per-namespace isolation

*每個 namespace 的網路隔離*

Audit finding #4 (`docs/security-posture-audit.md`) — the pod network was flat:
any app pod could open TCP to any other app, to Postgres, to the kubelet on
`:10250` and to the API server on `:6443`. The per-app database roles were real
isolation but they were the *only* layer.

*稽核報告第 4 項 —— pod 網路原本是扁平的:任何 app pod 都能對其他 app、Postgres、
kubelet 的 `:10250`、API server 的 `:6443` 開 TCP。每個 app 的資料庫 role 是真的隔離,
但它是**唯一**一層。*

These policies turn *isolated by credentials* into *isolated by credentials **and**
reachability*.

*這些政策把「靠憑證隔離」變成「靠憑證**加上**可達性隔離」。*

## Networks these rules are written against

*規則所依據的網段*

| Network / 網段 | CIDR | Why it matters / 為什麼重要 |
|---|---|---|
| Pod network | `10.42.0.0/16` | pod-to-pod lateral movement *pod 之間的橫向移動* |
| Service network | `10.43.0.0/16` | kube-dns `10.43.0.10`, API server `10.43.0.1` |
| Node / VCN subnet | `10.0.0.0/24` | node is `10.0.0.240` — **kubelet `:10250` and API `:6443` live here** *kubelet 與 API server 在這裡* |

All three must appear in every egress `ipBlock.except`. Omitting the node subnet
leaves `10.0.0.240:10250` and `10.0.0.240:6443` reachable — which is exactly what
finding #4 sets out to block. See `docs/security-posture-audit-remediation-plan.md` §5.2.

*三個網段都必須出現在每一條 egress 的 `ipBlock.except` 裡。漏掉節點子網就等於讓
`10.0.0.240:10250` 與 `10.0.0.240:6443` 仍然可達 —— 而那正是第 4 項要擋的東西。*

## Two things that will break a namespace if forgotten

*兩件忘記就會弄壞 namespace 的事*

1. **DNS.** Without an explicit allowance to `kube-dns:53`, an app cannot resolve
   `postgres.data.svc` and everything fails. This is the most common way to take
   a cluster down with a NetworkPolicy.
   *沒有明確放行 `kube-dns:53`,app 連 `postgres.data.svc` 都解析不出來,全部會壞。*
2. **kubelet health probes.** `gelp`, `transigen` and `snoopy` use `httpGet`
   probes, which the kubelet issues **from the node**. Ingress default-deny blocks
   them, the pod is marked unready and is dropped from its Service endpoints —
   the site goes down even though the container is healthy. Hence the
   `10.0.0.240/32` ingress rule in each app policy.
   *`gelp`、`transigen`、`snoopy` 用 `httpGet` 探針,是 kubelet **從節點**發起的。
   ingress default-deny 會擋掉它,pod 被判 unready 並從 Service endpoints 移除 ——
   容器明明健康,網站卻掛了。所以每個 app 政策都有那條 `10.0.0.240/32` 的 ingress。*

   `postgres` uses `exec` probes (`pg_isready`), which run inside the container
   and involve no network — unaffected.
   *`postgres` 用的是 `exec` 探針,在容器內執行、不走網路,不受影響。*

## Apply order

*套用順序*

One namespace at a time, verify, then proceed. Rollback is instant:
`kubectl delete netpol -n <ns> --all`.

*一次一個 namespace,驗證過再進下一個。回滾是 `kubectl delete netpol -n <ns> --all`,
立即生效。*

| Order | File | Verify by / 驗證方式 |
|---|---|---|
| 1 | `web.yaml` | `curl -I https://lans-h.cc` |
| 2 | `snoopy.yaml` | say something in Discord, check it replies *在 Discord 說話看它回不回* |
| 3 | `gelp.yaml` | log in at `gelp.lans-h.cc` *實際登入* |
| 4 | `transigen.yaml` | log in at `transigen.lans-h.cc` *實際登入* |
| 5 | `data.yaml` | all three apps still reach the DB *三個 app 都還連得到 DB* |

## Known gap left for a follow-up

*留給後續的已知缺口*

`data.yaml` policies **ingress only**. Postgres egress is deliberately left
unrestricted in this pass: it is the shared dependency for three apps, so a
mistake there has the largest blast radius. Restricting it (a compromised
Postgres should not be able to make outbound connections) is worth doing as a
separate, independently-verifiable change.

*`data.yaml` 只管 **ingress**。這一輪刻意不限制 Postgres 的 egress:它是三個 app 的
共用依賴,在那裡出錯影響半徑最大。限制它(被攻陷的 Postgres 不該能對外連線)值得做,
但應該獨立成一次可單獨驗證的變更。*
