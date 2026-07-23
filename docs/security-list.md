# OCI security list — the only packet filter

firewalld is disabled on the node (k3s docs recommendation; see
`bootstrap/bootstrap-node.sh`), so the subnet's OCI security list / NSG is the
ONLY thing between the internet and the node. A port not opened there is
unreachable, full stop.

*節點上的 firewalld 已停用(k3s 官方建議),所以 subnet 的 OCI security list /
NSG 是網際網路和節點之間**唯一**的封包過濾。沒在那裡開的 port 就是不通。*

## Ingress rules

| Port | Who | Why |
|---|---|---|
| 22 | you (ideally restrict to your IP) | SSH + snoopy's CI deploy |
| 80 | world | HTTP → apps via Traefik; (HTTP-01 fallback if ever needed) |
| 443 | world | HTTPS via Traefik (wildcard cert) |
| 9000 | GitHub webhook deliveries | push-to-deploy listener; restrictable to GitHub's hook ranges (`https://api.github.com/meta`) |

Nothing else. In particular: 6443 (k8s API) stays closed — all kubectl access
is over SSH on the node; 8080 (snoopy health/metrics) is in-cluster only;
5432 (Postgres) is in-cluster only, reached from a laptop via
`kubectl port-forward` over SSH.

*其他一律不開。特別是:6443(k8s API)不開——kubectl 一律 SSH 上節點;
8080(snoopy health/metrics)只在叢集內;5432(Postgres)只在叢集內,
筆電要連就走 SSH 上的 `kubectl port-forward`。*
