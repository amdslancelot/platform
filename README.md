# platform

Single source of truth for the shared infrastructure under the fleet: one OCI
A1.Flex node running single-node Kubernetes, one shared Postgres, one domain
(`lans-h.cc`, DNS on Cloudflare, registration on Spaceship), one wildcard
certificate, one webhook listener. App repos own their own build + deploy;
this repo owns everything two or more apps stand on.

*整個機隊共用基礎設施的單一真相:一台 OCI A1.Flex 跑 single-node Kubernetes、一個共用
Postgres、一個網域(`lans-h.cc`,DNS 在 Cloudflare、註冊在 Spaceship)、一張
wildcard 憑證、一個 webhook listener。App repo 各自擁有自己的 build 與部署;
凡是兩個以上 app 共同踩著的東西,歸這個 repo 管。*

## Fleet

| App | Repo | Trigger | Gate → prod | URL |
|---|---|---|---|---|
| snoopy | `snoopy_home` | GitHub Actions SSH-pull | `v*` tag | none — zero-inbound bot |
| gelp | `gelp` | CI (`next build`) → webhook (`:9000`) | build must pass (route A) | `gelp.lans-h.cc` |
| transigen | `transigen` | CI (`next build`) → webhook (`:9000`) | build must pass (route A) | `transigen.lans-h.cc` |
| my_website | `my_website` | webhook push (`:9000`) | push-to-main | `lans-h.cc` (+`www` 301) |

## Layout

```
bootstrap/            node-level: OL9 → Kubernetes (Traefik ENABLED), webhook listener
node/                 recurring node maintenance: daily image prune (systemd timer)
webhook/hooks.json    the ONE hooks file for all apps (rendered on the node)
cluster/
  namespaces.yaml     platform / snoopy / gelp / transigen
  data-postgres/      shared Postgres (`data` ns) + multi-app DB provisioning
  cert-manager/       install pin, Cloudflare DNS-01 issuer, *.lans-h.cc wildcard
  traefik/            default TLSStore (wildcard) + www→apex redirect
dns/records.md        Cloudflare record inventory
docs/                 runbook (migration/cutover), OCI security list
```

## Design rules

- Apps never install cluster-wide things (cert-manager, issuers, Postgres,
  hook listeners). If a second app would need it, it lives here.
- The wildcard cert is Traefik's default: app Ingresses carry no `tls:` block
  and no cert-manager annotation — a `Host(...)` rule is all an app declares.
- DB provisioning is centralized and additive: `PROVISION_APPS` lists only the
  apps being touched; existing roles' passwords are never changed without
  `ROTATE=1`. See `cluster/data-postgres/provision-db.sh`.
- Image-store hygiene is node-level, not per-app. All four deploy paths build
  with podman and import into containerd, and none of them clean up — so the
  prune runs once on the node (`node/prune-images.sh`, daily timer) instead of
  being copied into four pipelines that would still miss a manual build. With
  no registry here, it never deletes an image a live workload spec names, and
  keeps the newest `KEEP` (default 2) *distinct* images per `localhost/*` repo
  so a rollback target survives.
- Migration state and pending steps: `docs/runbook.md`.

*設計規則:app 永遠不安裝叢集級的東西(cert-manager、issuer、Postgres、hook
listener)——第二個 app 也會用到的,就放這裡。wildcard 憑證是 Traefik 的預設:
app 的 Ingress 不帶 `tls:` 區塊、不帶 cert-manager 註解,只宣告自己的
`Host(...)` 規則。DB 開通是集中式且只做加法:`PROVISION_APPS` 只列這次要動的
app;既有 role 的密碼沒有 `ROTATE=1` 絕不變更。image 清理屬於節點層而非各
app:四條部署路徑都是 podman build 後匯入 containerd 且都不清理,所以清理在
節點上做一次(`node/prune-images.sh`,每日 timer),而不是複製到四條 pipeline
還漏掉手動 build。本節點沒有 registry,因此絕不刪除 live workload spec 指名
的 image,並保留每個 `localhost/*` repo 最新 `KEEP`(預設 2)個**不同的**
image 當回滾點。遷移狀態與待辦見 `docs/runbook.md`。*
