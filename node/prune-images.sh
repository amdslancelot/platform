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
#   3. in containerd, the newest ${KEEP} *distinct images* of each localhost/*
#      repository, so there is at least one rollback target. Distinct images,
#      not tags: two tags on one build must not count as two. snoopy tags by git
#      sha, the only app here with a real version history to roll back through.
#      podman is governed separately by ${PODMAN_KEEP} — see section 1b.
#
# 絕不刪除的三層保護:執行中容器引用的、live workload spec 指名的(縮到 0 的
# Deployment 或每天才跑一次的 CronJob 也算)、以及 containerd 裡每個 localhost/*
# repo 最新的 ${KEEP} 個「不同的 image」(留回滾點)。沒有 registry,刪掉只能重
# build。podman 另由 ${PODMAN_KEEP} 管,見 1b 段。
#
# Usage:
#   sudo bash prune-images.sh                # KEEP=2 (containerd), PODMAN_KEEP=1
#   sudo KEEP=3 bash prune-images.sh         # three rollback targets in containerd
#   sudo PODMAN_KEEP=0 bash prune-images.sh  # drop the build cache too
#   sudo DRY_RUN=1 bash prune-images.sh      # print the plan, delete nothing
#
# Normally fired by prune-images.timer (daily 03:00). Safe to run by hand at
# any time, including mid-deploy: in-use images are refused, not forced.
set -euo pipefail

# sudo's secure_path excludes /usr/local/bin where k3s/kubectl live (CLAUDE.md).
export PATH="/usr/local/bin:${PATH}"

KEEP="${KEEP:-2}"
# podman's copy is build cache, not a rollback source — containerd already holds
# ${KEEP} of each and is the only store Kubernetes can run from. Default 1: keep
# the current build so the next one reuses its layers instead of redoing every
# app layer from the base image (a cold snoopy build measured 59s). 2 would be
# pointless: the three `:latest` pipelines never have a second tagged image to
# keep, and a second snoopy build here would serve nothing.
PODMAN_KEEP="${PODMAN_KEEP:-1}"
DRY_RUN="${DRY_RUN:-0}"
K3S="/usr/local/bin/k3s"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

log() { printf '==> %s\n' "$*"; }
avail() { df -BM --output=avail / | awk 'NR==2{print $1}'; }

BEFORE="$(avail)"
log "root available before: ${BEFORE}"

# --- 1a. podman: drop dangling build layers ----------------------------------
# Tagged bases (node:22-alpine, nginx:alpine, ...) stay put — they are the build
# cache, and re-pulling them costs a slow arm64 fetch. podman runs nothing on
# this node; it is purely a build tool.
log "podman: pruning dangling images"
if [ "${DRY_RUN}" = "1" ]; then
  podman images --filter dangling=true --format '  would remove {{.ID}} {{.Size}}' || true
else
  podman image prune -f || log "WARNING: podman prune failed; continuing"
fi

# --- 1b. podman: retain only the newest ${KEEP} localhost/* images ------------
# Dangling alone is not enough, and which app you look at decides whether you
# notice. gelp/transigen/my_website rebuild the SAME tag every deploy
# (localhost/<app>:latest), so each new build strips the tag off the previous
# image, it becomes <none>, and the prune above collects it — that is where the
# 77 dangling images came from. snoopy tags by git sha instead, so no tag is
# ever reused, nothing is ever orphaned, and its images accumulate one per
# deploy at ~789MB each while `podman images -f dangling=true` reports nothing.
#
# The sha scheme is the better one — `:latest` cannot tell you which commit is
# running — so the fix belongs here, not in snoopy's pipeline.
#
# Retention is its own knob (${PODMAN_KEEP}, default 0) rather than containerd's
# ${KEEP}, because the two stores hold these images for different reasons.
# containerd's copy is what actually runs and what a rollback needs. podman's is
# a byproduct of the build, already handed to containerd by `podman save`, and
# keeping it buys only layer cache for the next build of the same app — which is
# why the default is 1 rather than 0: the duplicate copy costs ~545MB on a
# volume at 4% use, and saves rebuilding every app layer on the next deploy.
# Only names under localhost/ are considered either way, so base
# images (docker.io/library/python:3.11-slim, node:22-alpine, ...) are never
# candidates: those are the cache that actually pays for itself on a slow arm64
# pull.
#
# 只清 dangling 不夠:三個 app 每次重用 `:latest`,舊 image 因此失去 tag 變成
# dangling 才被收走;snoopy 用 git sha 當 tag,永遠沒有 tag 被搶走,所以一個都不會
# 變 dangling,每次部署就多積一份。sha 才是比較好的做法,所以修在這裡而不是改
# snoopy。保留數獨立成 ${PODMAN_KEEP}(預設 0)而非沿用 ${KEEP}:containerd 那份
# 是實際在跑、回滾要用的;podman 那份只是 build 的副產品,`podman save` 之後已經
# 交給 containerd,留著只換到下次 build 的圖層快取 —— 預設 1 而非 0 的理由:那份
# 重複約佔 545MB,而卷才用了 4%,換到的是下次部署不必從基底映像重跑所有應用層。
# 無論設多少,只有 localhost/ 開頭的會被考慮,基底映像永遠不在候選內。
log "podman: retaining newest ${PODMAN_KEEP} per localhost/* repository"
PODMAN_PLAN="$(mktemp)"
trap 'rm -f "${PODMAN_PLAN}" "${PLAN:-}"' EXIT

python3 - "${PODMAN_KEEP}" >"${PODMAN_PLAN}" <<'PYEOF'
import json, subprocess, sys

keep = int(sys.argv[1])
out = subprocess.run(["podman", "images", "--format", "json"],
                     capture_output=True, text=True).stdout.strip()
images = json.loads(out) if out else []

# Group every localhost/* tag by its repository. One image can carry several
# tags; rank by distinct image, not by tag, or two tags on one build would
# "keep two" that are the same bytes — the bug the containerd side hit first.
repos = {}
for img in images:
    for name in img.get("Names") or []:
        if name.startswith("localhost/"):
            repo = name.rsplit(":", 1)[0]
            repos.setdefault(repo, []).append((name, img["Id"], img.get("Created", 0),
                                               img.get("Size", 0)))

emitted = set()
for repo, tags in repos.items():
    ranked = sorted(tags, key=lambda t: t[2], reverse=True)
    # keep == 0 means retain nothing: the guard matters because the loop below
    # only stops once it has collected `keep` ids, so without it a zero would
    # fall through and keep every one of them — the exact opposite.
    keep_ids = []
    if keep > 0:
        for _, img_id, _, _ in ranked:
            if img_id not in keep_ids:
                keep_ids.append(img_id)
            if len(keep_ids) == keep:
                break
    for name, img_id, _, size in ranked:
        # podman lists an image once per tag, each carrying the full Names list,
        # so the same ref shows up more than once; emitting it twice would make
        # the second `podman rmi` fail and log a misleading "in use".
        if img_id not in keep_ids and name not in emitted:
            emitted.add(name)
            print("REF", name, size)
PYEOF

if [ ! -s "${PODMAN_PLAN}" ]; then
  log "podman: nothing to retire"
else
  while read -r _ target size; do
    human="$(numfmt --to=iec --suffix=B "${size}" 2>/dev/null || echo "${size}")"
    if [ "${DRY_RUN}" = "1" ]; then
      echo "  would remove ${target} (${human})"
    elif podman rmi "${target}" >/dev/null 2>&1; then
      echo "  removed ${target} (${human})"
    else
      echo "  skipped ${target} (in use)"
    fi
  done <"${PODMAN_PLAN}"
fi

# --- 2/3. containerd: plan the deletions -------------------------------------
# Deliberately NOT `crictl rmi --prune`: that also removes tagged images no
# container currently holds, which on this node means the snoopy rollback tag.
# We compute the plan first so DRY_RUN can show it and so every deletion below
# is visible in the log.
PLAN="$(mktemp)"
trap 'rm -f "${PODMAN_PLAN}" "${PLAN}"' EXIT   # replaces the earlier trap; both files

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
