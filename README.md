# CloudRadar on Kubernetes (minikube) with ArgoCD GitOps

Deploy the [CloudRadar](https://github.com/mi5technologies/CloudRadar) security tool as a 3-tier app on Kubernetes:

| Tier | What | Kubernetes object |
|---|---|---|
| Frontend | Vue app served by nginx | Deployment (blue + green) |
| Backend | FastAPI on port 8000 | Deployment |
| Datastore | PostgreSQL | StatefulSet + PersistentVolume |

Included: Ingress with TLS (LoadBalancer), ArgoCD GitOps, Prometheus + Grafana + Loki (metrics, dashboard, centralized logs), liveness/readiness probes, resource limits, blue-green deployments, and NetworkPolicies.

## Architecture

```
Browser ──https://cloudradar.local──> LoadBalancer ──> ingress-nginx
                                                            │
                                                            v
                                       frontend Service (blue ⇄ green switch)
                                                            │  /api proxied by nginx
                                                            v
                                                   backend Service :8000 <──scrape── Prometheus ──> Grafana
                                                            │                                          ^
                                                            v                                          │
                                                  postgres StatefulSet :5432             Loki <── Promtail (all pod logs)
```

## URL cheat-sheet (after setup)

| What | URL | Login |
|---|---|---|
| CloudRadar app | https://cloudradar.local | - |
| ArgoCD UI | https://localhost:8080 | `admin` / see- GitOps with ArgoCD section|
| Grafana (dashboards) | http://localhost:3000 | `admin` / `cloudradar` |
| Prometheus | http://localhost:9090 | - |

## Prerequisites

Install once (all free):

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) 
- [minikube](https://minikube.sigs.k8s.io/docs/start/) - `winget install Kubernetes.minikube`
- [kubectl](https://kubernetes.io/docs/tasks/tools/) - `winget install Kubernetes.kubectl`
- [helm](https://helm.sh/docs/intro/install/) - `winget install Helm.Helm`
- A free [Docker Hub](https://hub.docker.com/) account
- A GitHub account (for the GitOps part)

All commands below are PowerShell, run from the root of this repo.

---

## Part 1 - Run locally on minikube

### Step 1 - Start minikube

```powershell
minikube start --cpus=4 --memory=6g --cni=calico
```

> `--cni=calico` is required for NetworkPolicies to actually be enforced
> (the default minikube network ignores them silently).

### Step 2 - Install ingress-nginx (the LoadBalancer)

```powershell
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx `
  --namespace ingress-nginx --create-namespace `
  --set controller.service.type=LoadBalancer
```

Wait until the controller pod is ready:

```powershell
kubectl get pods -n ingress-nginx -w
```

### Step 3 - Create the TLS certificate

One self-signed cert for `cloudradar.local` (your browser will show a one-time warning - that is expected for self-signed certs):

```powershell
# Requires openssl (comes with Git for Windows: "C:\Program Files\Git\usr\bin\openssl.exe")
openssl req -x509 -nodes -days 365 -newkey rsa:2048 `
  -keyout tls.key -out tls.crt -subj "/CN=cloudradar.local"

kubectl create namespace cloudradar
kubectl create secret tls cloudradar-tls -n cloudradar --cert=tls.crt --key=tls.key
```

### Step 4 - Deploy the app

```powershell
kubectl apply -f k8s/ --recursive
```



```powershell
kubectl get pods -n cloudradar -w
```

You should see 4 pods reach `Running`: `frontend-blue-...`, `frontend-green-...`, `backend-...`, `postgres-0`.

#### Open the app

1. Add this line to `C:\Windows\System32\drivers\etc\hosts` (open Notepad **as Administrator**):

   ```
   127.0.0.1 cloudradar.local
   ```

2. In a **separate Administrator PowerShell window**, start the tunnel and leave it running
   (this is what gives the LoadBalancer a real local IP):

   ```powershell
   minikube tunnel
   ```

3. Open **https://cloudradar.local** - accept the self-signed certificate warning. Done!

---

## Part 2 - GitOps with ArgoCD

With ArgoCD, you stop running `kubectl apply` yourself. ArgoCD watches your Git repo
and keeps the cluster in sync automatically: **deploying = `git push`**.

```

### Install ArgoCD

```powershell
kubectl create namespace argocd
# --server-side is required: one ArgoCD CRD is too big for a normal apply
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for the pods (takes 1-2 minutes)
kubectl get pods -n argocd -w
```

Get the auto-generated admin password:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | `
  ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

Open the UI (leave this port-forward running):

```powershell
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Go to **https://localhost:8080** and log in with `admin` + the password above.

### Connect ArgoCD to your repo

Edit [argocd/cloudradar-app.yaml](argocd/cloudradar-app.yaml) - replace `YOUR_GITHUB_USERNAME`
with your GitHub username. Then:

```powershell
kubectl apply -f argocd/cloudradar-app.yaml
```

Open the ArgoCD UI - you will see a `cloudradar` application that automatically syncs
the `k8s/` folder. From now on:

1. Edit any YAML in `k8s/`
2. `git commit` + `git push`
3. ArgoCD applies the change within ~3 minutes (or click **Refresh** in the UI)

> `selfHeal: true` is enabled, so manual `kubectl` edits get reverted to match Git.
> That is the whole point of GitOps: Git is the single source of truth.

---

## Part 3 - Observability (Prometheus + Grafana + Loki)

### Step 6 - Install the monitoring stack

```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Prometheus + Grafana (one chart does it all)
helm install monitoring prometheus-community/kube-prometheus-stack `
  --namespace monitoring --create-namespace -f monitoring/prometheus-values.yaml

# Loki + Promtail = centralized logs from every pod
helm install loki grafana/loki-stack `
  --namespace monitoring -f monitoring/loki-values.yaml

# Scrape CloudRadar metrics + auto-load the CloudRadar dashboard
kubectl apply -f monitoring/servicemonitor.yaml
kubectl apply -f monitoring/grafana-dashboard.yaml
```

Wait for the pods:

```powershell
kubectl get pods -n monitoring -w
```

### Step 7 - Open the dashboards

```powershell
# Grafana -> http://localhost:3000   (login: admin / cloudradar)
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80
```

```powershell
# Prometheus -> http://localhost:9090   (optional, in another window)
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090
```

In Grafana:

- **Dashboards -> CloudRadar Overview** - findings by severity, compliance score,
  pod CPU/memory, and live logs from all CloudRadar pods (via Loki).
- **Dashboards -> Kubernetes / ...** - dozens of pre-built cluster dashboards.
- **Explore -> Loki** - query `{namespace="cloudradar"}` to search all logs in one place.

The CloudRadar metrics come from the backend's `/api/metrics` endpoint
(`cloudradar_findings_total`, `cloudradar_compliance_score`, ...) - run a scan in the app
and watch the numbers appear.

---

## Part 4 - Blue-green deployment

Two identical frontend Deployments exist: **blue** (live) and **green** (staging slot).
The `frontend` Service decides which one gets traffic via its `version` selector.

### Roll out a new version

```powershell
# 1. Build & push the new version
docker build -t <your-dockerhub-username>/cloudradar-frontend:v2 -f docker/frontend.Dockerfile .
docker push <your-dockerhub-username>/cloudradar-frontend:v2
```

2. Edit [k8s/frontend/deployment-green.yaml](k8s/frontend/deployment-green.yaml): change the image tag to `:v2`, then `git push`. ArgoCD deploys green next to blue (blue still serves all traffic).

3. Test green directly before switching:

```powershell
kubectl port-forward deployment/frontend-green -n cloudradar 8081:80
# check http://localhost:8081
```

4. **Switch traffic**: edit [k8s/frontend/service.yaml](k8s/frontend/service.yaml), change `version: blue` to `version: green`, then `git push`. Users now hit v2 instantly - no pods restart.

5. **Rollback** = change the selector back to `blue` and push. Instant.

> Not using ArgoCD? Apply steps 2 and 4 with `kubectl apply -f`, or switch with one command:
>
> ```powershell
> kubectl patch service frontend -n cloudradar -p '{\"spec\":{\"selector\":{\"app\":\"frontend\",\"version\":\"green\"}}}'
> ```

---