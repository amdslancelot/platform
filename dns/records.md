# DNS — lans-h.cc

Registration stays at **Spaceship** (yearly fee unchanged); nameservers are
delegated to **Cloudflare** (free plan). Cloudflare was chosen because it is a
first-class cert-manager DNS-01 solver, which is what makes the automated
wildcard certificate possible — Spaceship has no such integration.

*註冊維持在 **Spaceship**(年費照舊);nameserver 委派給 **Cloudflare**(免費
方案)。選 Cloudflare 是因為它是 cert-manager 一等公民的 DNS-01 solver,
自動化 wildcard 憑證靠它才成立——Spaceship 沒有這種整合。*

## Records (Cloudflare zone)

| Name | Type | Content | Proxy |
|---|---|---|---|
| `lans-h.cc` (`@`) | A | <node public IP> | **DNS only (grey)** |
| `*` | A | <node public IP> | **DNS only (grey)** |

Everything must stay **grey-cloud (DNS only)**. Orange-cloud proxying would put
Cloudflare in front of Traefik, fight our TLS termination, and break the
grey-cloud assumption the www redirect design rests on. `www` needs no record
of its own — the `*` wildcard resolves it; the 301 to apex is done by Traefik
(`cluster/traefik/www-redirect.yaml`), NOT by a Cloudflare rule (grey-cloud
traffic never passes through Cloudflare, so its Redirect Rules cannot fire).

*所有記錄必須維持**灰雲(DNS only)**。開橘雲代理會讓 Cloudflare 擋在 Traefik
前面、跟我們的 TLS 終結打架。`www` 不需要自己的記錄——由 `*` wildcard 解析;
301 轉 apex 由 Traefik 做(`cluster/traefik/www-redirect.yaml`),不是 Cloudflare
rule(灰雲流量不經過 Cloudflare,它的 Redirect Rule 根本不會觸發)。*

## API token (cert-manager DNS-01)

One token, created at dash.cloudflare.com → My Profile → API Tokens → template
"Edit zone DNS": permissions `Zone→DNS→Edit` + `Zone→Zone→Read`, zone scope
**lans-h.cc only**. It lives ONLY as the `cloudflare-api-token` Secret in the
`cert-manager` namespace (see `cluster/cert-manager/install.sh`) — never in git.

*一把 token(範本「Edit zone DNS」:權限 DNS:Edit + Zone:Read,只限 lans-h.cc
這個 zone)。它只以 `cert-manager` namespace 裡的 `cloudflare-api-token` Secret
存在——絕不進 git。*

## Retired

`lans-h.ai` (my_website's old apex) is fully replaced by `lans-h.cc` — no
dual-run, no redirect. my_website's Ingress host must be updated accordingly.

*`lans-h.ai`(my_website 的舊 apex)由 `lans-h.cc` 完全取代——不並存、不轉址。
my_website 的 Ingress host 要跟著改。*
