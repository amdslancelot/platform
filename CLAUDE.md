# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.
See `README.md` for the fleet table and layout; this file adds the operational
knowledge and gotchas that aren't obvious from the tree.

## What this repo is

`platform` is the single source of truth for **shared infrastructure** under the
fleet: one OCI A1.Flex node (`louis2`, public IP 92.5.135.46) running single-node
**k3s**, one shared **Postgres**, one domain (`lans-h.cc`, DNS on Cloudflare,
registration on Spaceship), one `*.lans-h.cc` **wildcard cert**, one **webhook
listener** (`:9000`). App repos own their own build + deploy; this repo owns
everything two or more apps stand on.

**The apps live in sibling repos**, not here: `snoopy_home`, `gelp`,
`transigen`, `my_website` (all under `~/Documents/claude/`, except transigen at
`~/Documents/Cursor/transigen`). This repo never contains app code — only
node/cluster/shared-infra.

## The node

- OL9 (Oracle Linux 9), arm64, single-node k3s installed **without**
  `--disable traefik --disable servicelb` (Traefik serves 80/443; the old
  snoopy-only era disabled them — re-enabled in Gate 1).
- kubeconfig is mode **644** (`--write-kubeconfig-mode 644`): the login user
  `opc` runs bare `kubectl` **without sudo**. `sudo kubectl` both is unnecessary
  and FAILS (see secure_path below).
- The platform checkout on the node is at **`~opc/platform`** (`/home/opc/platform`),
  NOT `/opt/platform`. App repos are cloned to `/opt/<app>` (root, via per-app
  read-only deploy keys at `/root/.ssh/<app>_deploy_key`).
- No image registry: images are built **on the node** with podman and imported
  into k3s's containerd; Deployments use `imagePullPolicy: Never` /
  `IfNotPresent` with `localhost/<app>` image names.

## Deploy mechanisms (per-app trigger, NOT unified — by choice)

| App | How a deploy is triggered | Gate |
|---|---|---|
| snoopy | GitHub Actions → SSH into node → build+rollout (`appleboy/ssh-action`) | `v*` tag + pytest (in Actions) |
| gelp | push main → **Actions `next build`** → HMAC-`curl` `:9000/hooks/deploy-gelp` | build must pass (route A) |
| transigen | push main → **Actions `next build`** → HMAC-`curl` `:9000/hooks/deploy-transigen` | build must pass (route A) |
| my_website | push main → **native GitHub webhook** → `:9000/hooks/deploy-my_website` | none (static site) |

All four ultimately run a per-app `deploy.sh`/`deploy-<app>.sh` on the node that
does: git fetch/reset → podman build → import into containerd → `kubectl rollout`.
The `:9000` listener is shared; gelp/transigen just put a CI build-gate in front
(the Actions job is the caller instead of GitHub's native push event). See
`webhook/hooks.json` + `bootstrap/install-webhook.sh`.

**Two orthogonal axes** (don't conflate): *test gate* (build/tests must pass —
route A gives gelp/transigen this) vs *release gate* (`v*` tag only — snoopy has
this; gelp/transigen do not, "tag-gate flip" is deferred/optional).

## Key constraints & gotchas (hard-won)

- **`install-webhook.sh` renders `/etc/webhook/hooks.json` WHOLESALE** from
  `webhook/hooks.json`. Every `{{APP_WEBHOOK_SECRET}}` it references must be
  supplied on **every** run — re-running to add one app means passing ALL app
  secrets (`GELP_`/`TRANSIGEN_`/`MY_WEBSITE_WEBHOOK_SECRET`), or the required-vars
  check fails and the others drop.
- **sudo `secure_path`** excludes `/usr/local/bin` (where k3s/kubectl/webhook
  live), so bare `k3s`/`kubectl` fail under `sudo` but work under systemd/login.
  Use full paths (`/usr/local/bin/k3s`) or prepend PATH in scripts. Corollary:
  `kubectl` needs NO sudo here (644 kubeconfig).
- **Image naming**: podman tags unqualified names as `localhost/<x>`; a bare
  `x:latest` in a pod spec normalizes to `docker.io/library/x:latest` → containerd
  attempts a (failing) registry pull. Always name images `localhost/<app>` so
  the imported local image is used and never pulled.
- **Wildcard cert is Traefik's default cert**: app Ingresses carry no `tls:`
  block and no cert-manager annotation — a `Host(...)` rule is all an app needs.
- **`:9000` webhook is plain `http`** (not behind Traefik/TLS). Security is the
  **HMAC secret** (`X-Hub-Signature-256`), never TLS. When an Actions job signs
  its own delivery, use `printf '%s'` (no trailing newline) so the signed bytes
  match `curl --data` exactly, else the hook rejects "rules not satisfied".
- **DB provisioning is additive**: `cluster/data-postgres/provision-db.sh` takes
  `PROVISION_APPS` (only the apps being touched); existing roles' passwords are
  never changed without `ROTATE=1`.
- **Postgres runs with no TLS by design** — DB traffic never leaves the trusted
  cluster/local network; don't flag missing `sslmode`. (Also noted in each app
  repo's env docs.)
- **cert-manager mid-challenge restart** corrupts its in-memory zone cache and
  loops the DNS-01 cleanup forever — if a wildcard re-issue is stuck, delete the
  `CertificateRequest` to force a fresh order (don't `rollout restart`
  cert-manager mid-challenge).

## Where state lives

- **Gate-by-gate migration/cutover runbook**: `docs/runbook.md` (7 gates + the
  bilingual command-led steps).
- **Full narrative migration log** (Day 1–5, every command + problem/fix):
  `learning/platform-migration-2026-07-24.md` — this is the primary record; read
  it before touching a gate.
- **OCI security list** (80/443/9000): `docs/security-list.md`.
- **Cloudflare DNS inventory**: `dns/records.md`.

## Outstanding

Cloudflare API token roll (it appeared plaintext in an earlier chat) + prune
leftover `_acme-challenge` TXT; optional tag-gate flip for gelp/transigen;
optional `shred -u /opt/<app>/.env.prod`. Tracked in `docs/runbook.md` and the
migration log's Outstanding table.

**Gate 7 done (2026-07-26)** — retired the app repos' prod node-level scripts:
gelp `setup-server.sh` gutted to app-onboarding + `deploy/webhook/` deleted;
transigen setup-app.sh's DB-provision/webhook steps dropped + `deploy/webhook/`
deleted; snoopy `prod-k3s-runbook.md` got platform-handover pointers. **Kept, not
deleted** (the plan said delete): gelp/transigen `provision-db.sh` and snoopy
`deploy/k8s/postgres.yaml` — each still backs that app's local **minikube**
dev/staging, which platform (prod-only) never touches. my_website was already
clean from Gate 6.

## Conventions

Docs are bilingual (English + Taiwan Chinese per paragraph); runbook/migration
logs use the command-led format (Goal → annotated command block → Expect, with
terse 問題/解法 on failures). `worklog.md` is gitignored. These are user-wide —
see `~/.claude/CLAUDE.md`.
