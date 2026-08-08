# observability

Fleet monitoring for the single node `louis2` (A1.Flex, **2 OCPU / 12 GB**).
The design principle is **offload**: a lightweight collector on the node ships
metrics to Grafana Cloud, so the node keeps none of the storage/query load — a
monitor must never compete for the resources it is monitoring. Three things run
on the node: Grafana Alloy, node-exporter, postgres-exporter.

**Measured 2026-08-04, and it is not as light as this README first claimed.** An
earlier draft said "~200 MB total". The real figure, the day the stack went live:

| namespace | working set | note |
|---|---|---|
| **observability** | **397 MB** | the largest on the node |
| kube-system | 269 MB | |
| cert-manager | 143 MB | |
| snoopy + gelp + transigen + web | 259 MB | **all four apps combined** |
| data (Postgres) | 58 MB | |

So the collector currently outweighs everything it collects from. The offload
principle still holds where it matters — no TSDB, no query engine, no PVC, and
CPU across the whole fleet is ~1.3% of two cores — but "a monitor must never
compete for the resources it is monitoring" is a claim this stack has not fully
earned yet, and pretending otherwise in the README would be the wrong kind of
documentation.

The cause is known and is being worked: the kubelet endpoint's ~46.5k series are
parsed into label sets before the allowlist discards 99.9% of them, and that
parse-and-discard is what Alloy's memory goes to. `scrape_interval = "5m"` on
that one job (2026-08-04) cuts how often it happens by 5x. Alloy's 400Mi limit is
**deliberately left alone until that is re-measured** — lowering a limit on a
process already near it buys an OOMKill, not a saving. See `docs/pending.md` §2.8.

## What it monitors

| Area | Metrics | Source |
|---|---|---|
| **Per-app** (by namespace) | CPU, RAM, disk I/O*, ephemeral disk usage | kubelet + cAdvisor (already running) |
| **Host** | disk space, CPU, RAM, network, load | node-exporter |
| **Images** | count, logical size, actual on-disk bytes (containerd + podman stores) | `scripts/image-metrics.sh` → textfile |
| **Logs** | per-pod container-log dir size + total | `scripts/log-size.sh` → textfile |
| **Postgres** | per-app DB size, connections, cache hit, tx rate | postgres-exporter |
| **App metrics** | an app's own business metrics (opt-in) | pod `prometheus.io/scrape` annotation → Alloy |

\* Per-app disk **I/O** is best-effort (cgroup v2 `io.stat`; page-cache
writeback attribution is fuzzy). For accurate I/O, read Postgres's own stats via
postgres-exporter — Postgres is the only real disk-I/O generator here.

## Why per-app comes for free

Every app has its own namespace (`snoopy` / `gelp` / `transigen` / `web` /
`data`), so cAdvisor's per-container series become per-app with `sum by
(namespace)`. Postgres is db-per-app, so `pg_database_size_bytes{datname=...}`
is already the per-app data size. No per-app instrumentation needed.

## Files

```
namespace.yaml                 observability ns (holds the collector + exporters)
node-exporter.yaml             DaemonSet: host metrics + textfile collector
postgres-exporter.yaml         Deployment + Service: per-app DB metrics
provision-monitoring-role.sh   least-priv pg_monitor role for the exporter
alloy/rbac.yaml                Alloy ServiceAccount + read-only ClusterRole
alloy/alloy.yaml               Alloy Deployment (1 replica) + config (remote_write → Grafana Cloud)
scripts/image-metrics.sh       host: image count/size → textfile .prom
scripts/log-size.sh            host: per-pod log dir size → textfile .prom
scripts/observability-metrics.{service,timer}   systemd: run the two scripts every 5m
scripts/install-metrics-timer.sh   installs both scripts to /usr/local/sbin (SELinux) + the units
scripts/public-metrics.sh      host: Grafana Cloud -> allowlisted JSON -> ConfigMap (public page)
scripts/public-metrics.{service,timer}          systemd: refresh the public snapshot every 5m
scripts/install-public-metrics.sh  installs the above + prompts once for the metrics:read token
dashboards/fleet.json          the fleet dashboard — import into Grafana, see below
docs/architecture.md           the SHAPE: data flow, trust boundaries, failure modes
docs/data-path.md              where each number comes from + what a break costs (counter vs gauge)
docs/runbook.md                command-led install + verify (Grafana Cloud, secrets, rotation, prune)
docs/pending.md                MUST-READ before applying: pre-flight fixes + the open backend decision
docs/glossary.md               the WORDS: series, label, cardinality, temporality, up, WAL, ...
```

Six documents, six jobs — start with whichever question you have:

| Document | Answers |
|---|---|
| `README.md` (this file) | What is monitored, and from which source |
| `docs/architecture.md` | What shape it is, how the data flows, and what breaks when a piece fails |
| `docs/data-path.md` | Where a number is born, the five hops it travels, and which metrics lose data when a link breaks |
| `docs/runbook.md` | How to install it, command by command |
| `docs/pending.md` | Why each choice was made; what is deferred |
| `docs/glossary.md` | What a word means — `series`, `label`, `cardinality`, `temporality`, `up`, `WAL` |

**Read `docs/pending.md` first.** This branch was authored before the Phase B-1..B-4
hardening landed on `main`; three of the runbook's steps fail silently against the
NetworkPolicies now in place, and two others are stale.

See `docs/runbook.md` for the deploy order and the two things monitoring alone does
NOT fix: **containerd log rotation** and **periodic image prune**.

## Dashboard

`dashboards/fleet.json` — the fleet dashboard, kept in git rather than only in a
Grafana account. Import it with **Dashboards → New → Import → Upload JSON**, then
pick the Prometheus datasource when prompted.

It has a `cluster` variable driven by `label_values(up, cluster)`, so a second
cluster (§4.5 in `docs/pending.md`) appears in the picker without editing anything.

Do **not** import the community Kubernetes dashboards. Almost all of them depend
on **kube-state-metrics**, which this stack does not run — every panel would read
"No data" and look like a collection failure. kube-state-metrics reports cluster
*object* state (desired vs available replicas, restart counts); cAdvisor reports
resource *usage*. Different things; adding the former is a separate decision with
its own memory and active-series cost.

`1860` (Node Exporter Full) does work as-is if a deeper host view is wanted — it
reads only node-exporter, which this stack does run.

## The public snapshot

`lans-h.cc/fleet.html` shows a deliberately small subset of these metrics to the
public internet. It is **not** an embedded Grafana: a timer on the node runs a
fixed list of queries, reduces them to one JSON document, and publishes it as a
ConfigMap that `my_website`'s nginx pod mounts. The visitor gets a file, so there
is no query interface to go around — see `docs/pending.md` §5.5 for why that beat
running Grafana OSS, and runbook **Step 6** to install it.

**Before adding a query to it, read the redaction contract** at the top of
`scripts/public-metrics.sh`. The namespace map there is an allowlist: a namespace
added to the cluster later does not appear on the public page by default.
