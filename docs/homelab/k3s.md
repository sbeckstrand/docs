# Home Lab: Kubernetes Cluster

## Overview

The home lab runs a [k3s](https://k3s.io/) cluster — a lightweight Kubernetes distribution well-suited for bare-metal and resource-constrained environments. k3s ships with sensible defaults (embedded SQLite or etcd, built-in Traefik, CoreDNS) and is managed like any other Kubernetes cluster once running.

---

## GitOps: ArgoCD

All workloads are managed through [ArgoCD](https://argo-cd.readthedocs.io/) using a GitOps workflow. The cluster state is defined entirely in a private Git repository; ArgoCD continuously reconciles the live cluster against that source of truth.

### App of Apps

ArgoCD is bootstrapped with a single root `Application` that points at the `argocd/` directory in the repo. That root app renders a Helm chart which generates individual ArgoCD `Application` resources for every service — one per app. This is the [App of Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern).

Apps are grouped into three categories:

| Category | Description |
|---|---|
| **system** | Core cluster infrastructure (ingress, DNS, storage, observability) |
| **management** | Cluster management tooling (secrets, DNS management, netbox) |
| **services** | User-facing applications |

Each app is a self-contained Helm chart under `apps/<category>/<name>/`. Adding a new service means adding a chart directory and a single entry in the root values file — ArgoCD picks it up on the next sync.

---

## Ingress: Traefik

[Traefik](https://traefik.io/) is the cluster's ingress controller, deployed via the `system/traefik` app. It holds a single static LoadBalancer IP assigned by MetalLB.

All HTTP traffic enters the cluster through Traefik. Services expose themselves by creating a standard Kubernetes `Ingress` resource pointing at that IP; Traefik routes requests to the correct backend based on the `Host` header.

HTTP traffic is automatically redirected to HTTPS at the Traefik level.

---

## Load Balancer: MetalLB

[MetalLB](https://metallb.universe.tf/) provides LoadBalancer IP allocation for bare-metal clusters (which have no cloud provider to do this automatically). It operates in Layer 2 mode, advertising IPs from a reserved range on the local network.

A small pool of IPs is reserved for cluster use. Most services no longer need their own LoadBalancer IP — they go through Traefik — but MetalLB is still used for services that require a dedicated IP (e.g. Blocky's DNS service on port 53).

---

## DNS: Blocky

[Blocky](https://0xERR0R.github.io/blocky/) is the cluster's DNS resolver, running as a high-availability deployment with its own dedicated LoadBalancer IP. Home network devices use this IP as their DNS server.

Blocky provides:

- **Ad blocking** — upstream block lists filter ads and trackers for all clients
- **Internal name resolution** — a `customDNS` mapping resolves `*.int.beckstrand.dev` to Traefik's LoadBalancer IP, keeping internal services off public DNS entirely
- **Conditional forwarding** — `cluster.local` queries are forwarded to CoreDNS for in-cluster service discovery; reverse DNS for the local subnet is forwarded to the home router
- **Caching** — responses are cached to reduce upstream query volume

Internal services are accessed at `<service>.int.beckstrand.dev`. These hostnames exist only in Blocky's custom DNS mapping and are never published to public DNS, so they are unreachable from outside the home network.

---

## TLS: cert-manager + Let's Encrypt

[cert-manager](https://cert-manager.io/) automates TLS certificate issuance and renewal. All services use certificates issued by [Let's Encrypt](https://letsencrypt.org/).

Because internal services at `*.int.beckstrand.dev` are not publicly reachable, HTTP-01 validation is not an option. Instead, every certificate uses the **DNS-01 challenge**, which proves domain ownership by creating a TXT record in the public `beckstrand.dev` Cloudflare zone. cert-manager handles this automatically via the Cloudflare API.

This means internal services get valid, browser-trusted TLS certificates even though they are never exposed to the internet.

Services opt in by annotating their `Ingress` resource:

```yaml
cert-manager.io/cluster-issuer: letsencrypt-issuer
```

cert-manager then issues and renews the certificate automatically.

---

## Secrets: External Secrets Operator + Doppler

Secrets are stored in [Doppler](https://www.doppler.com/) and synced into the cluster by the [External Secrets Operator](https://external-secrets.io/) (ESO).

All secrets live in a single Doppler project (`k8s-apps`) under keys prefixed by service name (e.g. `GRAFANA_ADMIN_PASSWORD`, `MINIO_ROOT_USER`). A `ClusterSecretStore` resource points ESO at that project.

Each service that needs secrets declares an `ExternalSecret` resource. ESO uses a `dataFrom.find` selector with a regexp to pull all keys matching the service's prefix, then strips the prefix via a `rewrite` rule so the resulting Kubernetes `Secret` contains bare key names (e.g. `ADMIN_PASSWORD`) — matching what the downstream Helm chart expects, without any changes to the chart itself.

---

## Storage

Two storage layers are in use:

**[Longhorn](https://longhorn.io/)** is the default `StorageClass` for general persistent volumes. It provides replicated block storage across cluster nodes and integrates with Kubernetes PVCs directly.

**[MinIO](https://min.io/)** provides S3-compatible object storage for services that need it. Observability backends (Mimir for metrics, Loki for logs) use MinIO buckets as their long-term storage layer instead of local disk, which simplifies backup and avoids tying large datasets to specific nodes.

---

## Observability

The observability stack is built around the Prometheus ecosystem:

| Component | Role |
|---|---|
| **kube-prometheus-stack** | Prometheus operator, alerting rules, node exporters |
| **Mimir** | Long-term metrics storage (backed by MinIO) |
| **Loki** | Log aggregation (backed by MinIO) |
| **Vector** | Log collection agent — ships logs from all pods to Loki |
| **Grafana** | Dashboards and visualization, sourcing from both Mimir and Loki |
| **Blackbox Exporter** | Synthetic probes for endpoint availability monitoring |

Grafana dashboards are version-controlled as JSON files in the `k8s-apps` repo and loaded automatically via a sidecar that watches for labelled ConfigMaps.
