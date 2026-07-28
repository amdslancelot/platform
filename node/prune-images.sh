#!/usr/bin/env bash
#
# Reclaim the container-image disk the deploy pipeline leaks.
#
# Every deploy on this node does `podman build` then `podman save | ctr images
# import` (there is no registry — see CLAUDE.md). Nothing ever removed the
# previous build, so BOTH stores grew without bound: by 2026-07-28 the podman
# store held 77 dangling images and containerd 36, together ~9GB of a 30GB root
# volume. Four independent deploy paths produce that garbage (gelp, transigen
# and my_website via :9000; snoopy via GitHub Actions SSH), plus any manual
# build — so the cleanup lives HERE, on the node, once, instead of being copied
# into four pipelines that would still miss the manual case.
#
# 前情:本節點每次部署都 podman build 後匯入 containerd,舊 image 從不清理,
# 兩個 store 一起無上限成長。四條部署路徑都會產生垃圾,所以清理集中在節點層
# 做一次,而不是複製到四條 pipeline 裡。
#
# WHAT IT WILL NEVER DELETE — this node has no registry and app Deployments use
# imagePullPolicy: Never/IfNotPresent, so a deleted image cannot be re-pulled;
# it can only be rebuilt. Three guards, in order of how much they matter:
#   1. anything a running container references (crictl refuses anyway);
#   2. anything named in a live workload spec — a Deployment scaled to zero, or
#      a CronJob that only runs at 03:30, still needs its image to exist;
#   3. the newest ${KEEP} tags of each localhost/* repository, so there is at
#      least one rollback target. snoopy tags images by git sha, which is the
#      only app here with a real version history to roll back through.
#
# 絕不刪除的三層保護:執行中容器引用的、live workload spec 指名的(縮到 0 的
# Deployment 或每天才跑一次的 CronJob 也算)、以及每個 localhost/* repo 最新的
# ${KEEP} 個 tag(留回滾點)。沒有 registry,刪掉只能重 build。
#
# Usage:
#   sudo bash prune-images.sh              # prune, KEEP=2
#   sudo KEEP=3 bash prune-images.sh       # keep three tags per repo
#   sudo DRY_RUN=1 bash prune-images.sh    # print the plan, delete nothing
#
# Normally fired by prune-images.timer (daily 03:00). Safe to run by hand at
# any time, including mid-deploy: in-use images are refused, not forced.
set -euo pipefail

# sudo's secure_path excludes /usr/local/bin where k3s/kubectl live (CLAUDE.md).
export PATH="/usr/local/bin:${PATH}"

KEEP="${KEEP:-2}"
DRY_RUN="${DRY_RUN:-0}"
K3S="/usr/local/bin/k3s"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

log() { printf '==> %s\n' "$*"; }
avail() { df -BM --output=avail / | awk 'NR==2{print $1}'; }

BEFORE="$(avail)"
log "root available before: ${BEFORE}"

# --- 1. podman: drop dangling build layers -----------------------------------
# Only dangling. Tagged bases (node:22-alpine, nginx:alpine, ...) stay put —
# they are the build cache, and re-pulling them costs a slow arm64 fetch.
# podman runs nothing on this node; it is purely a build tool.
log "podman: pruning dangling images"
if [ "${DRY_RUN}" = "1" ]; then
  podman images --filter dangling=true --format '  would remove {{.ID}} {{.Size}}' || true
else
  podman image prune -f || log "WARNING: podman prune failed; continuing"
fi

# --- 2/3. containerd: plan the deletions -------------------------------------
# Deliberately NOT `crictl rmi --prune`: that also removes tagged images no
# container currently holds, which on this node means the snoopy rollback tag.
# We compute the plan first so DRY_RUN can show it and so every deletion below
# is visible in the log.
PLAN="$(mktemp)"
trap 'rm -f "${PLAN}"' EXIT

python3 - "${K3S}" "${KEEP}" >"${PLAN}" <<'PYEOF'
import json, subprocess, sys

k3s, keep = sys.argv[1], int(sys.argv[2])


def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def crictl_json(*args):
    out = run(k3s, "crictl", *args, "-o", "json").strip()
    return json.loads(out) if out else {}


images = crictl_json("images").get("images", [])

# Guard 1: images held by a running container.
protected_ids = {
    c.get("imageRef", "") for c in crictl_json("ps").get("containers", [])
}

# Guard 2: image names any live workload spec asks for. A Deployment scaled to
# zero and a CronJob between runs both still need their image on disk.
protected_refs = set()
kinds = "deploy,statefulset,daemonset,cronjob,job"
out = run("kubectl", "get", kinds, "-A", "-o", "json").strip()
for item in (json.loads(out).get("items", []) if out else []):
    spec = item["spec"]
    tpl = spec.get("template") or spec["jobTemplate"]["spec"]["template"]
    for c in tpl["spec"].get("containers", []) + tpl["spec"].get("initContainers", []):
        protected_refs.add(c["image"])


# ref -> manifest digest, read once: `ctr images ls` lists every image, and
# calling it per tag turned this into an O(n^2) walk on a 2-core node.
MANIFESTS = {}
for line in run(k3s, "ctr", "-n", "k8s.io", "images", "ls").splitlines():
    f = line.split()
    if len(f) >= 3 and f[0] != "REF":
        MANIFESTS[f[0]] = f[2]


def created(ref):
    """Image build time, from the config blob in containerd's content store.

    Neither `crictl images` nor `ctr images ls` reports a timestamp, so walk
    ref -> manifest digest -> config digest -> .created. Unknown sorts oldest,
    which makes an unreadable image a prune candidate rather than a permanent
    resident.
    """
    digest = MANIFESTS.get(ref)
    if not digest:
        return ""
    try:
        man = json.loads(run(k3s, "ctr", "-n", "k8s.io", "content", "get", digest))
        cfg = json.loads(
            run(k3s, "ctr", "-n", "k8s.io", "content", "get", man["config"]["digest"])
        )
        return cfg.get("created", "")
    except Exception:
        return ""


# Step 2: untagged images are pure garbage — a tag that moved to a newer build.
for img in images:
    if not img.get("repoTags") and img["id"] not in protected_ids:
        print("ID", img["id"], img.get("size", 0))

# Step 3: per-repository tag retention, localhost/* only. Third-party images
# (postgres, traefik, cert-manager) are pinned by the manifests that install
# them and are re-pullable, so they are left alone entirely.
repos = {}
for img in images:
    for tag in img.get("repoTags", []):
        if tag.startswith("localhost/"):
            repos.setdefault(tag.rsplit(":", 1)[0], []).append((tag, img["id"], img.get("size", 0)))

# Retention counts DISTINCT IMAGES, not tags. snoopy's deploy leaves two tags
# on one image (the release sha and the commit sha), so a tag-counting KEEP=2
# would "keep two" that are the same bytes and delete the only real rollback
# target — which is exactly what the first dry run of this script did.
for repo, tags in repos.items():
    ranked = sorted(tags, key=lambda t: created(t[0]), reverse=True)
    keep_ids = []
    for _, img_id, _ in ranked:
        if img_id not in keep_ids:
            keep_ids.append(img_id)
        if len(keep_ids) == keep:
            break
    for tag, img_id, size in ranked:
        if img_id in keep_ids or img_id in protected_ids or tag in protected_refs:
            continue
        print("REF", tag, size)
PYEOF

if [ ! -s "${PLAN}" ]; then
  log "containerd: nothing to prune"
else
  log "containerd: $(wc -l <"${PLAN}") image(s) to remove"
  while read -r kind target size; do
    human="$(numfmt --to=iec --suffix=B "${size}" 2>/dev/null || echo "${size}")"
    if [ "${DRY_RUN}" = "1" ]; then
      echo "  would remove ${kind} ${target} (${human})"
    elif $K3S crictl rmi "${target}" >/dev/null 2>&1; then
      echo "  removed ${kind} ${target} (${human})"
    else
      echo "  skipped ${kind} ${target} (in use)"
    fi
  done <"${PLAN}"
fi

AFTER="$(avail)"
log "root available after: ${AFTER} (was ${BEFORE})"
