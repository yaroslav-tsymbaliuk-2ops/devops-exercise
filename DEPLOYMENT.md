# YellowPad — On-Prem Deployment Guide

This guide is written for a client IT team deploying YellowPad onto their own Kubernetes cluster. It assumes Kubernetes familiarity but no prior exposure to YellowPad.

The reference target is **single-node k3s on Linux**, which is the lightest production-credible footprint for an on-prem install. A k3d-based developer workflow is documented in the appendix.

---

## 1. Prerequisites

### Hardware (single-node minimum)
| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU      | 2 vCPU  | 4 vCPU |
| RAM      | 4 GB    | 8 GB |
| Disk     | 20 GB   | 50 GB SSD |
| Network  | Outbound HTTPS for image pulls (or air-gapped registry) |

### Software on the host
- Ubuntu 22.04 LTS / Debian 12 / RHEL 9 (anything systemd-based that k3s supports)
- `curl`, `bash`, `sudo`
- Ports `6443` (API), `80`, `443` (Ingress) reachable from operators

### Software on the operator workstation
- `kubectl` ≥ 1.29
- `git` (to clone this repo)
- Optional: `make`

### Access required
- SSH/root on the target host for k3s install
- A DNS entry (or `/etc/hosts` line) pointing `yellowpad.<your-domain>` at the host
- A private container registry **or** the ability to side-load tarball images

---

## 2. Quick-Start (zero → running)

```bash
# --- on the target host ---------------------------------------------------
# 2.1 Install k3s (single-node, with Traefik ingress + local-path storage)
curl -sfL https://get.k3s.io | sh -

# Make kubeconfig usable by your operator user
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
kubectl get nodes              # should show 1 Ready node

# --- on the operator workstation -----------------------------------------
# 2.2 Clone YellowPad
git clone https://github.com/yellowpadaifunc/devops-exercise.git
cd devops-exercise

# 2.3 Build & push the three images to YOUR registry, then update the
#     image: refs in k8s/{api-gateway,document-processor,web-ui}/deployment.yaml.
#     Example (replace registry.example.com):
for svc in api-gateway document-processor web-ui; do
  docker build -t registry.example.com/yellowpad/$svc:1.0.0 src/$svc
  docker push    registry.example.com/yellowpad/$svc:1.0.0
done

# 2.4 Rotate the bundled credentials BEFORE applying.
#     The repo ships exercise-only Secrets in k8s/secrets.yaml — DO NOT use them in production.
kubectl apply -f k8s/namespace.yaml
kubectl -n yellowpad create secret generic yellowpad-db \
  --from-literal=POSTGRES_USER=yellowpad \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=POSTGRES_DB=yellowpad \
  --from-literal=DB_USER=yellowpad \
  --from-literal=DB_PASSWORD="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml > my-db-secret.yaml
kubectl -n yellowpad create secret generic yellowpad-minio \
  --from-literal=MINIO_ROOT_USER=yellowpad \
  --from-literal=MINIO_ROOT_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=MINIO_ACCESS_KEY=yellowpad \
  --from-literal=MINIO_SECRET_KEY="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml > my-minio-secret.yaml
# Keep the DB and MinIO passwords consistent between the two Secrets above.
# Apply your own Secrets and skip the shipped k8s/secrets.yaml:
kubectl apply -f my-db-secret.yaml -f my-minio-secret.yaml

# 2.5 Deploy the rest of the stack (skip secrets.yaml so we don't overwrite yours)
kustomize build k8s | grep -v -e '^# Source: secrets.yaml' | kubectl apply -f -
# (Or simply delete k8s/secrets.yaml from the kustomization.yaml resources list.)

# 2.6 Set the ingress host you actually want and apply
sed -i 's/yellowpad.localtest.me/yellowpad.your-domain.com/' k8s/web-ui/ingress.yaml
kubectl apply -f k8s/web-ui/ingress.yaml
```

The stack is now coming up. Continue with **Verification**.

---

## 3. Verification

```bash
# 3.1 All pods should be Running and Ready
kubectl get pods -n yellowpad
# Expected: postgres-0, minio-0, redis-*, api-gateway-*, document-processor-*, web-ui-* all 1/1 Ready

# 3.2 API self-check (all four components must report ok)
kubectl -n yellowpad port-forward svc/api-gateway 8000:8000 &
curl -s http://localhost:8000/healthz
# Expected: {"api":"ok","database":"ok","redis":"ok","minio":"ok"}

# 3.3 End-to-end smoke test
curl -X POST http://localhost:8000/documents \
  -H "Content-Type: application/json" \
  -d '{"filename":"test.pdf","content":"hello world"}'
# Expected: {"id":1,"filename":"test.pdf","status":"pending"}

kubectl -n yellowpad port-forward svc/document-processor 8001:8001 &
curl -X POST http://localhost:8001/process/1
# Expected: {"id":1,"status":"processed","content_hash":"..."}

# 3.4 Web UI reachable via Ingress
curl -I http://yellowpad.your-domain.com/
# Expected: HTTP/1.1 200 OK
```

---

## 4. Architecture Overview

```
                       ┌──────────────────────┐
   user browser ─────▶ │  Traefik Ingress     │  (k3s built-in, :80/:443)
                       └──────────┬───────────┘
                                  │ Host: yellowpad.<domain>
                                  ▼
                       ┌──────────────────────┐
                       │  web-ui (Nginx)      │  static SPA + /api/* proxy
                       └──────────┬───────────┘
                                  │ /api/*
                                  ▼
                       ┌──────────────────────┐
                       │  api-gateway         │  FastAPI :8000  /healthz
                       └──┬────────┬─────────┬┘
                          │        │         │
                ┌─────────┘        │         └───────────┐
                ▼                  ▼                     ▼
       ┌──────────────┐   ┌──────────────┐     ┌──────────────────┐
       │ postgres     │   │ redis        │     │ minio (S3)       │
       │ pgvector/pg16│   │ cache        │     │ object storage   │
       │ PVC 5 Gi     │   │ ephemeral    │     │ PVC 10 Gi        │
       └──────────────┘   └──────────────┘     └──────────────────┘
                ▲                  ▲                     ▲
                └──────────────┐   │   ┌─────────────────┘
                               │   │   │
                       ┌───────┴───┴───┴──────┐
                       │ document-processor   │  FastAPI :8001  /healthz
                       └──────────────────────┘
```

- Everything runs in namespace `yellowpad`.
- Service discovery is plain DNS (`postgres`, `redis`, `minio`, `api-gateway`).
- `yellowpad-config` ConfigMap holds non-secret connection info; `yellowpad-db` and `yellowpad-minio` Secrets hold credentials.
- PostgreSQL and MinIO run as StatefulSets with PVCs so data survives pod restarts.
- Redis is a Deployment (cache; no persistence required).

---

## 5. Common Issues

### 5.1 Pods stuck in `ImagePullBackOff`
The image refs in `k8s/*/deployment.yaml` default to `yellowpad/<svc>:dev`, which only exists locally. For a real deploy, point them at your registry:

```bash
kubectl -n yellowpad set image deploy/api-gateway        api-gateway=registry.example.com/yellowpad/api-gateway:1.0.0
kubectl -n yellowpad set image deploy/document-processor document-processor=registry.example.com/yellowpad/document-processor:1.0.0
kubectl -n yellowpad set image deploy/web-ui             web-ui=registry.example.com/yellowpad/web-ui:1.0.0
```

If you pull from a private registry, also create a `dockerconfigjson` Secret and reference it via `imagePullSecrets` in each Deployment.

### 5.2 `/healthz` returns 503 (one of database/redis/minio = error)
The api-gateway aggregates health from all backends, so a 503 usually points at one specific dependency. Triage in this order:

```bash
kubectl -n yellowpad get pods
kubectl -n yellowpad logs statefulset/postgres
kubectl -n yellowpad logs deploy/redis
kubectl -n yellowpad logs statefulset/minio
kubectl -n yellowpad describe pvc                  # PVC stuck Pending?
```

The two most common root causes are:
- **PVC provisioning** — confirm a default StorageClass exists (`kubectl get sc`). On k3s it ships as `local-path`.
- **Stale Secret values** — if you rotated DB credentials but didn't restart the app pods, they're still using cached env vars. Run `kubectl -n yellowpad rollout restart deploy/api-gateway deploy/document-processor`.

### 5.3 `port-forward` fails with "address already in use"
If `:8000` or `:8001` is already in use on your workstation, map to a free host port and adjust the curl URL:

```bash
kubectl -n yellowpad port-forward svc/api-gateway 18000:8000
curl http://localhost:18000/healthz
```

The Service port (`8000`) is unchanged; only the host-side port differs.

### 5.4 Ingress returns 404 / not reachable
1. Confirm Traefik is running: `kubectl get pods -n kube-system | grep traefik`.
2. Confirm the Ingress was admitted: `kubectl get ingress -n yellowpad` (`ADDRESS` column should be populated).
3. Confirm DNS — `dig yellowpad.your-domain.com` should resolve to the host. For quick tests without DNS, use `curl -H 'Host: yellowpad.your-domain.com' http://<host-ip>/`.
4. If you disabled Traefik when installing k3s (`--disable=traefik`), you must install an ingress controller of your own (nginx-ingress, traefik via Helm, etc.) and update `ingressClassName` in `k8s/web-ui/ingress.yaml`.

---

## Appendix A — Developer workflow with k3d (macOS / Linux dev)

For local development we use **k3d**, which runs real k3s inside Docker. The manifests are identical to the on-prem deploy above.

```bash
brew install k3d kubectl kustomize    # macOS
make cluster                           # creates k3d cluster with :8080→:80 mapping
make build                             # docker build all three services
make load                              # k3d image import into the cluster
make deploy                            # kubectl apply -k k8s
make wait                              # block on rollouts
make verify                            # /healthz + upload + process + ingress checks
```

Then browse to `http://yellowpad.localtest.me:8080/` (the `localtest.me` domain always resolves to `127.0.0.1`, so no `/etc/hosts` edit is needed).

To tear down:

```bash
make clean      # delete the yellowpad namespace
make destroy    # delete the k3d cluster
```

---

## Appendix B — What's intentionally out of scope

The exercise calls this out explicitly, and so do we. Production deployments at scale should add:

- HA PostgreSQL (operator such as CloudNativePG) and HA MinIO (4-node erasure-coded).
- `cert-manager` + Let's Encrypt / internal CA for TLS at the Ingress.
- NetworkPolicies restricting pod-to-pod traffic to declared dependencies only.
- Backups (postgres `pg_dump` to S3, MinIO bucket replication or `mc mirror`).
- Observability stack (Prometheus + Grafana + Loki) and `/metrics` endpoints in the apps.
- A real secret-management story: SOPS-encrypted Secrets in Git, External Secrets Operator + Vault, or Sealed Secrets.
- Pod Security Admission set to `restricted` namespace-wide and per-container `securityContext` hardening (readOnlyRootFilesystem, drop ALL capabilities, runAsNonRoot).
