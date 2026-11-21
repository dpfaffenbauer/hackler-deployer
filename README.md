# hackler-deployer

Run Hackler cloud sessions in your own Kubernetes cluster. The
**hackler-operator** registers your cluster as a Hackler *location* (kind
K8s-Cluster) and runs every cloud session there as a sandbox pod.

This repository holds what you need to deploy it: a Helm chart
(`charts/hackler-operator`) and the same manifests for Kustomize
(`kustomize/`). The images are public:

- `ghcr.io/dpfaffenbauer/hackler-operator` – the operator, and the egress guard and proxy sidecar of every sandbox (one build)
- `ghcr.io/dpfaffenbauer/hackler-machine` – the stock sandbox image

Operator and machine image always go together in the same version.

The machine image has what Claude's and Codex's cloud environments have, in
every version either offers (Node 18–24, Python 3.10–3.14, PHP 8.2–8.5,
Java 11–25, Go, Rust, Ruby, Swift, Erlang/Elixir, PostgreSQL, Redis, Chrome,
…; `check-tools` in a session lists them). Its layers are zstd-compressed (pulling needs
containerd ≥ 1.5). It is **linux/amd64 only and about
9 GB compressed, 25–30 GB unpacked**: give the nodes that run sandboxes a
root volume of 100 GB or more. The first sandbox on a new node waits several
minutes for the pull.

## Before you start

1. **A location and its token.** In Hackler, open admin → Standorte →
   Standort hinzufügen, kind **K8s-Cluster**, and set the slots (sandboxes
   that may run at once). The token (`hkp_…`) is shown once.
2. **The cluster** needs:
   - outbound access only: the operator and every sandbox connect to the
     Hackler server and pull from `ghcr.io`; nothing connects into the cluster;
   - amd64 nodes with a root volume of 100 GB or more (the machine image);
   - a default StorageClass for the sandboxes' workspaces (or set one);
   - iptables `nat` with `REDIRECT` and the `owner` match on the nodes (the
     egress guard in every pod);
   - optionally metrics-server (CPU and memory in the admin) and Cilium (an
     extra deny policy, below).

## Install with Helm

```sh
kubectl create namespace hackler-system
kubectl label namespace hackler-system pod-security.kubernetes.io/enforce=restricted
kubectl -n hackler-system create secret generic hackler-operator --from-literal=PROVISIONER_TOKEN=hkp_…

helm install hackler-operator oci://ghcr.io/dpfaffenbauer/charts/hackler-operator -n hackler-system
# or from a checkout of this repository:
helm install hackler-operator ./charts/hackler-operator -n hackler-system

kubectl -n hackler-system logs -f deploy/hackler-operator
```

The chart creates the sandbox namespace `hackler-sandboxes` (PodSecurity
`privileged`, see Security). If it exists already, add
`--set sandboxes.createNamespace=false`.

Upgrading: `helm upgrade hackler-operator … -n hackler-system`. Running
sandboxes keep the rules and the sidecar they were made with; a sandbox that
sleeps and resumes gets the new ones.

## Install with Kustomize

```sh
kubectl apply -k https://github.com/dpfaffenbauer/hackler-deployer//kustomize/base?ref=main
kubectl -n hackler-system create secret generic hackler-operator --from-literal=PROVISIONER_TOKEN=hkp_…
```

To change settings, copy `kustomize/example` and patch the ConfigMap there.

## Settings

| Helm value | Variable | Default | |
| --- | --- | --- | --- |
| `server` | `HACKLER_SERVER` | `https://api.hackler.app` | The Hackler server as the operator reaches it |
| `machineServer` | `HACKLER_MACHINE_SERVER` | `server` | The server as a sandbox reaches it |
| `token.value` / `token.secretName` | `PROVISIONER_TOKEN` | Secret `hackler-operator` | Better create the Secret yourself than put the token in values |
| `image.*`, `machineImage.*` | `SANDBOX_GUARD_IMAGE`, `SANDBOX_MACHINE_IMAGE` | the chart's appVersion | Keep both on the same version |
| `imagePullSecrets` | `SANDBOX_IMAGE_PULL_SECRETS` | – | Only for images of your own registry |
| `sandboxes.namespace` | `SANDBOX_NAMESPACE` | `hackler-sandboxes` | |
| `sandboxes.dns` | `SANDBOX_DNS` | `1.1.1.1,8.8.8.8` | Resolvers of the sandboxes; `cluster` = the cluster DNS |
| `sandboxes.egressAlways` | `SANDBOX_EGRESS_ALWAYS` | `api.anthropic.com,api.github.com` | Reachable from every sandbox |
| `sandboxes.requestRatio` | `SANDBOX_REQUEST_RATIO` | `0.5` | Requests = the environment's cpu/memory × ratio |
| `sandboxes.blockedCidrs` | `SANDBOX_BLOCKED_CIDRS` | – | Extra blocked ranges, e.g. the nodes' public addresses on clusters without Cilium |
| `sandboxes.networkPolicy` | `SANDBOX_NETWORK_POLICY` | `on` | A NetworkPolicy per sandbox |
| `sandboxes.ciliumPolicy` | `SANDBOX_CILIUM_POLICY` | `auto` | The Cilium deny policy: `auto`, `on`, `off` |
| `sandboxes.egressGuard` | `SANDBOX_EGRESS_GUARD` | `on` | `off` only where NET_ADMIN is not allowed and NetworkPolicies are enforced |
| `sandboxes.storageClass` | `SANDBOX_STORAGE_CLASS` | default class | |
| `sandboxes.prepull` | `SANDBOX_PREPULL` | `on` | A DaemonSet keeps the machine image on every amd64 node: pulled as soon as a node joins, never garbage-collected, a new version pulled before the old one goes |
| `sandboxes.runtimeClass` | `SANDBOX_RUNTIME_CLASS` | – | e.g. `gvisor`, a second isolation layer |
| `extraConfig` | any | – | Further variables, e.g. `PROVISIONER_POLL_MS` |

Name, slots and price of the location are set in the Hackler admin, not here.

## Security

- **Two namespaces, no cluster-wide rights.** The operator runs in its
  namespace (PodSecurity `restricted`) with a Role in the sandbox namespace
  only: pods, logs, events, PVCs, Secrets, NetworkPolicies,
  CiliumNetworkPolicies, the pre-pull DaemonSet, pod metrics. No ClusterRole, no CRD.
- **The sandbox pod**: no ServiceAccount token, no service links, seccomp
  `RuntimeDefault`; the sandbox container runs as uid 1000 with every
  capability dropped. The sandbox namespace is `privileged` only because the
  egress guard, an init container, needs `NET_ADMIN` for a moment to load the
  pod's iptables rules.
- **Egress guard and proxy**: no inbound connections, no private ranges, no
  cluster; the environment's network access (None, Limited with allowed
  domains, Full) is enforced by the proxy sidecar, which checks the TLS
  server name. Network secrets and GitHub access are added by the sidecar;
  the sandbox never sees them.
- **The API server's public address** is read from its certificate and
  blocked for sandboxes.
- **Cilium**: where it is installed, the operator keeps a
  `CiliumNetworkPolicy` `hackler-sandbox-deny` in the sandbox namespace that
  denies the nodes (under every address), the API server, all pods and the
  private ranges. A deny wins over every allow, so this holds whatever an
  environment allows.
- **No Docker in sandboxes.** It would need root in a user namespace of the
  pod's own, and that root could take the proxy's uid and leave past the
  egress rules. Tasks that need Docker run on a local machine.
- Sandboxes share the node's kernel. For untrusted workloads add a sandboxed
  runtime (`sandboxes.runtimeClass`, e.g. gVisor) or dedicated nodes.
