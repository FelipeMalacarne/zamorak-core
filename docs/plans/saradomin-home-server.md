# saradomin Home Server — Implementation Plan

## Context

Migrating services from Oracle VM (`zamorak`, Docker Swarm) to an Intel N97 home server named
`saradomin` (16GB RAM, 512GB NVMe). Oracle VM stays alive; services migrate gradually.

**Machine naming:**
- `zaros` — main workstation
- `zamorak` — Oracle VM (cloud, existing k3s)
- `saradomin` — N97 home server (new, this plan)

**Goal:** GitOps home server using k3s + ArgoCD, mirroring zamorak patterns, with
home-specific services (Jellyfin, Pi-hole, Vaultwarden) and Longhorn storage with Cloudflare R2 backup.

---

## Architecture

```
saradomin (N97, k3s single-node)
├── Traefik (ArgoCD-managed Helm, NOT k3s built-in)
├── Cloudflare Tunnel → public: Jellyfin, Vaultwarden
├── Tailscale Operator → all services (private)
├── Pi-hole (DNS ad blocking, Tailscale-only admin)
├── Jellyfin (Tailscale + Cloudflare, Intel QuickSync)
├── Vaultwarden (Cloudflare public + PostgreSQL backend)
├── PostgreSQL (shared cluster DB)
├── Longhorn (storage + R2 backup)
└── Prometheus + Grafana (Tailscale-only)
```

**Access matrix:**

| Service       | Access                                                     |
|---------------|------------------------------------------------------------|
| Vaultwarden   | Cloudflare tunnel → `vault.felipemalacarne.com.br`         |
| Jellyfin      | Tailscale + Cloudflare → `jellyfin.felipemalacarne.com.br` |
| Pi-hole admin | Tailscale only                                             |
| ArgoCD        | Tailscale only                                             |
| Grafana       | Tailscale only                                             |
| PostgreSQL    | Cluster-internal only                                      |

---

## Repository Structure

```
saradomin/
├── terraform/
│   ├── main.tf              # R2 backend + cloudflare module call
│   ├── variables.tf
│   ├── terraform.tfvars     # (gitignored — real values)
│   └── cloudflare/
│       ├── main.tf          # Tunnels + DNS records for vault.* and jellyfin.*
│       ├── variables.tf
│       └── outputs.tf       # Tunnel tokens for cloudflared Secret
│
├── kubernetes/
│   ├── bootstrap/
│   │   └── argocd-values.yaml       # server.insecure: true, Tailscale LoadBalancer
│   │
│   ├── base/
│   │   └── namespaces.yaml          # media, security, networking, monitoring, data
│   │
│   └── apps/
│       ├── networking/
│       │   ├── traefik/             # Traefik Helm ApplicationSet
│       │   ├── pihole/              # Pi-hole + NodePort 53 + Tailscale svc
│       │   └── cloudflared/         # Cloudflare tunnel deployment
│       ├── data/
│       │   ├── longhorn/            # Longhorn + R2 BackupTarget
│       │   └── postgres/            # PostgreSQL shared DB
│       ├── media/
│       │   └── jellyfin/            # Jellyfin + HostPath + Intel GPU
│       ├── security/
│       │   └── vaultwarden/         # Vaultwarden + PostgreSQL
│       └── monitoring/
│           ├── prometheus/
│           └── grafana/
│
└── docs/
    └── plans/
        └── saradomin-home-server.md  # this file
```

---

## Storage Strategy

### Longhorn (default StorageClass — replace local-path-provisioner)
- Single-node: replication factor = 1
- Cloudflare R2 backup via `BackupTarget` CRD (S3-compatible API)
- `RecurringJob`: daily snapshot to R2

| PVC | Longhorn | R2 Backup |
|-----|----------|-----------|
| PostgreSQL data | Yes | Yes — daily |
| Vaultwarden SQLite (if not PG) | Yes | Yes |
| Grafana dashboards | Yes | Yes |
| Jellyfin config/metadata | Yes | Yes |
| Jellyfin media `/data/media` | **HostPath** | No — too large |

### Disk layout on NVMe
```
/data/
├── k3s-storage/    # optional symlink target for k3s storage
└── media/          # Jellyfin library (HostPath PV)
```

---

## Phase 1 — k3s Base

### Step 1: Install k3s (disable built-in Traefik)

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644
```

> **Why `--disable traefik`:** k3s manages its bundled Traefik outside Helm/ArgoCD. Disabling it
> lets ArgoCD own Traefik as a proper GitOps Helm release, consistent with zamorak pattern.

Copy kubeconfig to zaros:
```bash
scp saradomin:/etc/rancher/k3s/k3s.yaml ~/.kube/saradomin.yaml
# Edit server: https://saradomin:6443  →  https://<tailscale-ip>:6443
export KUBECONFIG=~/.kube/saradomin.yaml
```

### Step 2: Tailscale on host (for remote access while building)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
# Get pod CIDR and service CIDR from k3s:
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
# Typically 10.42.0.0/16 (pods) and 10.43.0.0/16 (services)
tailscale up --advertise-routes=10.42.0.0/16,10.43.0.0/16 --accept-dns=false
```

Approve routes in Tailscale admin panel.

### Step 3: Bootstrap ArgoCD

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --values kubernetes/bootstrap/argocd-values.yaml \
  --version 7.x
```

`kubernetes/bootstrap/argocd-values.yaml`:
```yaml
global:
  domain: argocd.saradomin  # Tailscale-only, no public DNS needed

configs:
  params:
    server.insecure: true   # Traefik terminates TLS

server:
  service:
    type: LoadBalancer
    annotations:
      tailscale.com/expose: "true"   # After Tailscale operator is installed
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

Initial access (before Tailscale operator): port-forward:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Get initial password:
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Phase 2 — Networking

### Step 4: Traefik (ArgoCD Helm Application)

`kubernetes/apps/networking/traefik/application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://helm.traefik.io/traefik
    chart: traefik
    targetRevision: "28.x"
    helm:
      values: |
        deployment:
          replicas: 1
        service:
          type: LoadBalancer
        ports:
          web:
            redirectTo:
              port: websecure
          websecure:
            tls:
              enabled: false  # cert-manager handles TLS
        ingressClass:
          enabled: true
          isDefaultClass: true
        providers:
          kubernetesCRD:
            enabled: true
          kubernetesIngress:
            enabled: true
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: networking
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

cert-manager is installed as a dependency before Traefik (it issues the TLS certs Traefik serves).

`kubernetes/apps/networking/cert-manager/application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: "v1.x"
    helm:
      values: |
        installCRDs: true
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: networking
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

`kubernetes/apps/networking/cert-manager/cluster-issuer.yaml`:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: felipe@felipemalacarne.com.br
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

Create the Cloudflare API token secret (needs `Zone:DNS:Edit` permission):
```bash
kubectl create secret generic cloudflare-api-token \
  --namespace networking \
  --from-literal=api-token=<cloudflare-dns-edit-token>
```

### Step 5: Tailscale Operator (ArgoCD)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tailscale-operator
  namespace: argocd
spec:
  source:
    repoURL: https://pkgs.tailscale.com/helmcharts
    chart: tailscale-operator
    targetRevision: "1.x"
    helm:
      values: |
        oauth:
          clientId: "<from-secret>"
          clientSecret: "<from-secret>"
  destination:
    namespace: tailscale
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Create the OAuth secret first:
```bash
kubectl create namespace tailscale
kubectl create secret generic operator-oauth \
  --namespace tailscale \
  --from-literal=client_id=<id> \
  --from-literal=client_secret=<secret>
```

### Step 6: Longhorn

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argocd
spec:
  source:
    repoURL: https://charts.longhorn.io
    chart: longhorn
    targetRevision: "1.7.x"
    helm:
      values: |
        defaultSettings:
          defaultReplicaCount: 1
          # R2 is S3-compatible; endpoint set in the credential secret
          backupTarget: "s3://saradomin-longhorn@auto/"
          backupTargetCredentialSecret: "longhorn-r2-secret"
        persistence:
          defaultClass: true
          defaultClassReplicaCount: 1
  destination:
    namespace: longhorn-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

R2 credentials secret — Longhorn expects S3-style keys plus a custom endpoint:
```bash
kubectl create secret generic longhorn-r2-secret \
  --namespace longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID=<r2-access-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<r2-secret-access-key> \
  --from-literal=AWS_ENDPOINTS="https://<account_id>.r2.cloudflarestorage.com" \
  --from-literal=AWS_CERT=""
```

> R2 access keys are created in the Cloudflare dashboard under **R2 → Manage R2 API Tokens**.
> Set `AWS_CERT=""` so Longhorn does not try to verify a custom CA.

RecurringJob (daily snapshot → R2):
```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"
  task: backup
  groups: ["default"]
  retain: 7
  concurrency: 1
```

### Step 7: Pi-hole

`kubernetes/apps/networking/pihole/`:

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pihole
  namespace: networking
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pihole
  template:
    metadata:
      labels:
        app: pihole
    spec:
      # hostNetwork exposes port 53 directly on the node IP — required because
      # DNS clients always dial port 53; NodePort (30000+) range won't work here.
      # systemd-resolved must be disabled or moved off port 53 first (see note below).
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: pihole
          image: pihole/pihole:latest
          env:
            - name: TZ
              value: "America/Sao_Paulo"
            - name: WEBPASSWORD
              valueFrom:
                secretKeyRef:
                  name: pihole-secret
                  key: webpassword
          ports:
            - containerPort: 53
              protocol: UDP
            - containerPort: 53
              protocol: TCP
            - containerPort: 80
              protocol: TCP
          volumeMounts:
            - name: pihole-data
              mountPath: /etc/pihole
      volumes:
        - name: pihole-data
          persistentVolumeClaim:
            claimName: pihole-pvc
---
# service-admin.yaml (Tailscale-only admin UI)
apiVersion: v1
kind: Service
metadata:
  name: pihole-admin
  namespace: networking
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "pihole"
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app: pihole
  ports:
    - port: 80
      targetPort: 80
```

> **systemd-resolved conflict:** Ubuntu/Debian hosts run `systemd-resolved` on port 53.
> Disable the stub listener before deploying Pi-hole:
> ```bash
> # On saradomin host:
> sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
> sudo systemctl restart systemd-resolved
> sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
> ```

The Tailscale service exposes Pi-hole's web UI (port 80) only — DNS goes via hostNetwork above.
After deploy: set the saradomin Tailscale IP as the custom DNS server in the Tailscale admin panel
→ all Tailscale devices get ad blocking.

### Step 8: Cloudflared

Terraform creates the tunnels (see Terraform section below). The tunnel tokens are output and stored as a Kubernetes Secret.

```yaml
# kubernetes/apps/networking/cloudflared/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: networking
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --no-autoupdate
            - run
            - --token
            - $(TUNNEL_TOKEN)
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflared-token
                  key: token
```

One tunnel routes both `vault.*` and `jellyfin.*` to Traefik (Traefik handles routing by hostname via Ingress rules).

---

## Phase 3 — Services

### Step 9: PostgreSQL

`kubernetes/apps/data/postgres/`:

```yaml
# statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: data
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: postgres-data
        annotations:
          # Ensure Longhorn recurs. backup applies
          recurring-job-group.longhorn.io/default: enabled
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: longhorn
        resources:
          requests:
            storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: data
spec:
  clusterIP: None   # headless for StatefulSet DNS
  selector:
    app: postgres
  ports:
    - port: 5432
```

Create databases for each service:
```sql
CREATE USER vaultwarden WITH PASSWORD 'changeme';
CREATE DATABASE vaultwarden OWNER vaultwarden;
```

### Step 10: Vaultwarden

```yaml
# kubernetes/apps/security/vaultwarden/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vaultwarden
  namespace: security
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vaultwarden
  template:
    spec:
      containers:
        - name: vaultwarden
          image: vaultwarden/server:latest
          env:
            # DATABASE_URL must be a single secret — k8s does not interpolate $(VAR)
            # inside value: fields across different env entries. Store the full URL
            # in a secret and reference it directly.
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: vaultwarden-secret
                  key: database_url   # value: postgresql://vaultwarden:<pass>@postgres.data.svc.cluster.local/vaultwarden
            - name: DOMAIN
              value: "https://vault.felipemalacarne.com.br"
            - name: SIGNUPS_ALLOWED
              value: "false"   # disable after first account created
          ports:
            - containerPort: 80
---
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vaultwarden
  namespace: security
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  ingressClassName: traefik
  rules:
    - host: vault.felipemalacarne.com.br
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vaultwarden
                port:
                  number: 80
  tls:
    - hosts:
        - vault.felipemalacarne.com.br
      secretName: vaultwarden-tls
```

### Step 11: Jellyfin

Intel QuickSync requires the `intel-device-plugins-operator`. Install first:

```bash
# Intel GPU Device Plugin (via ArgoCD or kubectl)
kubectl apply -f https://github.com/intel/intel-device-plugins-for-kubernetes/releases/latest/download/operator.yaml
```

```yaml
# kubernetes/apps/media/jellyfin/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jellyfin
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jellyfin
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: saradomin   # pin to node with GPU
      containers:
        - name: jellyfin
          image: jellyfin/jellyfin:latest
          resources:
            limits:
              gpu.intel.com/i915: 1   # Intel QuickSync
          env:
            - name: TZ
              value: "America/Sao_Paulo"
          ports:
            - containerPort: 8096
          volumeMounts:
            - name: config
              mountPath: /config
            - name: media
              mountPath: /data/media
              readOnly: true
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: jellyfin-config
        - name: media
          hostPath:
            path: /data/media   # large library, not in Longhorn
            type: Directory
---
# ClusterIP — used by Traefik ingress (Cloudflare path)
apiVersion: v1
kind: Service
metadata:
  name: jellyfin
  namespace: media
spec:
  type: ClusterIP
  selector:
    app: jellyfin
  ports:
    - port: 8096
      targetPort: 8096
---
# Tailscale LoadBalancer — direct private access from any Tailscale device
apiVersion: v1
kind: Service
metadata:
  name: jellyfin-tailscale
  namespace: media
  annotations:
    tailscale.com/hostname: "jellyfin"
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app: jellyfin
  ports:
    - port: 8096
      targetPort: 8096
---
# Ingress for Cloudflare tunnel path — points to ClusterIP, not Tailscale LB
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jellyfin
  namespace: media
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  rules:
    - host: jellyfin.felipemalacarne.com.br
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jellyfin
                port:
                  number: 8096
```

Verify QuickSync is working (inside Jellyfin container):
```bash
ffmpeg -init_hw_device qsv=hw -filter_hw_device hw -i input.mp4 \
  -vf hwupload=extra_hw_frames=64,format=qsv \
  -c:v h264_qsv output.mp4
```

---

## Phase 4 — Observability

### Step 12: Prometheus + Grafana

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: "65.x"
    helm:
      values: |
        grafana:
          service:
            type: LoadBalancer
            annotations:
              tailscale.com/expose: "true"
              tailscale.com/hostname: "grafana"
            loadBalancerClass: tailscale
          persistence:
            enabled: true
            storageClassName: longhorn
            size: 5Gi
          adminPassword: changeme   # override with secret
        prometheus:
          prometheusSpec:
            retention: 15d
            storageSpec:
              volumeClaimTemplate:
                spec:
                  storageClassName: longhorn
                  resources:
                    requests:
                      storage: 20Gi
        alertmanager:
          enabled: false   # not needed initially
  destination:
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Terraform

Same pattern as `zamorak-core/terraform` but Terraform state is stored in Cloudflare R2 instead of GCS. R2's S3-compatible API lets Terraform use the `s3` backend with a custom endpoint.

`terraform/main.tf`:
```hcl
terraform {
  required_version = ">= 1.0"

  # R2 is S3-compatible — use the s3 backend with Cloudflare endpoint
  backend "s3" {
    bucket                      = "saradomin-tfstate"
    key                         = "terraform/state/saradomin.tfstate"
    region                      = "auto"
    endpoint                    = "https://<account_id>.r2.cloudflarestorage.com"
    access_key                  = "<r2-access-key-id>"       # or use env var AWS_ACCESS_KEY_ID
    secret_key                  = "<r2-secret-access-key>"   # or use env var AWS_SECRET_ACCESS_KEY
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}

module "cloudflare" {
  source     = "./cloudflare"
  api_token  = var.cloudflare_api_token
  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  zone       = var.cloudflare_zone
}
```

`terraform/variables.tf`:
```hcl
variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID for felipemalacarne.com.br"
  type        = string
}

variable "cloudflare_zone" {
  description = "Domain (e.g. felipemalacarne.com.br)"
  type        = string
}
```

Sensitive backend credentials (R2 access key/secret) should be passed via environment variables
rather than committed to `terraform.tfvars`:
```bash
export AWS_ACCESS_KEY_ID=<r2-access-key-id>
export AWS_SECRET_ACCESS_KEY=<r2-secret-access-key>
terraform init
```


`terraform/cloudflare/main.tf`:
```hcl
provider "cloudflare" {
  api_token = var.api_token
}

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.8.2"
    }
  }
}

# R2 buckets
resource "cloudflare_r2_bucket" "tfstate" {
  account_id = var.account_id
  name       = "saradomin-tfstate"
  location   = "WEUR"
}

resource "cloudflare_r2_bucket" "longhorn" {
  account_id = var.account_id
  name       = "saradomin-longhorn"
  location   = "WEUR"
}

# Single tunnel handles both vault.* and jellyfin.* — Traefik routes by host header
resource "cloudflare_zero_trust_tunnel_cloudflared" "saradomin_tunnel" {
  account_id = var.account_id
  name       = "Terraform saradomin tunnel"
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "saradomin_tunnel_token" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.saradomin_tunnel.id
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "saradomin_tunnel_config" {
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.saradomin_tunnel.id
  account_id = var.account_id
  config = {
    ingress = [
      {
        hostname = "vault.${var.zone}"
        service  = "http://traefik.networking.svc.cluster.local:80"
      },
      {
        hostname = "jellyfin.${var.zone}"
        service  = "http://traefik.networking.svc.cluster.local:80"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_dns_record" "vault_dns" {
  zone_id = var.zone_id
  name    = "vault.${var.zone}"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.saradomin_tunnel.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "[terraform] saradomin Vaultwarden"
}

resource "cloudflare_dns_record" "jellyfin_dns" {
  zone_id = var.zone_id
  name    = "jellyfin.${var.zone}"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.saradomin_tunnel.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "[terraform] saradomin Jellyfin"
}
```

`terraform/cloudflare/outputs.tf`:
```hcl
output "tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.saradomin_tunnel_token.token
  sensitive = true
}
```

> **Bootstrap note:** The two R2 buckets (`saradomin-tfstate`, `saradomin-longhorn`) must be
> created before `terraform init` can use the R2 backend. Create them manually in the Cloudflare
> dashboard on first run, then run `terraform init` and `terraform apply` to bring them under
> management. Alternatively, run a one-time `terraform apply` with a local backend, then migrate.

After `terraform apply`, store the token:
```bash
terraform output -raw tunnel_token | kubectl create secret generic cloudflared-token \
  --namespace networking \
  --from-literal=token=-
```

---

## App-of-Apps (ArgoCD Root Application)

After bootstrapping ArgoCD manually, a single root Application manages all others via GitOps.
This avoids manually applying each Application YAML.

`kubernetes/bootstrap/root-app.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.io
spec:
  project: default
  source:
    repoURL: https://github.com/felipemalacarne/saradomin.git
    targetRevision: HEAD
    path: kubernetes/apps
    directory:
      recurse: true
      include: "*/*/application.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Apply once after ArgoCD bootstrap:
```bash
kubectl apply -f kubernetes/bootstrap/root-app.yaml
```

From then on, adding a new `application.yaml` anywhere under `kubernetes/apps/` is enough —
ArgoCD picks it up automatically on the next sync.

---

## Intel GPU Device Plugin (GitOps)

Rather than `kubectl apply -f <url>`, manage the Intel GPU operator as an ArgoCD Application.

`kubernetes/apps/media/intel-gpu-plugin/application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: intel-gpu-plugin
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://intel.github.io/helm-charts
    chart: intel-device-plugins-operator
    targetRevision: "0.x"
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

After the operator is running, create the `GpuDevicePlugin` CR:
```yaml
apiVersion: deviceplugin.intel.com/v1
kind: GpuDevicePlugin
metadata:
  name: gpudeviceplugin-sample
  namespace: media
spec:
  image: intel/intel-gpu-plugin:latest
  sharedDevNum: 1
```

Verify the plugin is advertising the GPU to k8s:
```bash
kubectl get nodes -o json | jq '.items[].status.allocatable | with_entries(select(.key | startswith("gpu.intel")))'
# Should show: "gpu.intel.com/i915": "1"
```

---

## Secrets Strategy

**Never commit raw secrets.** Two options:

### Option A: SOPS (recommended — same workflow everywhere)
```bash
# Install SOPS + age
age-keygen -o ~/.config/sops/age/keys.txt

# .sops.yaml at repo root:
creation_rules:
  - path_regex: .*/secrets/.*\.yaml$
    age: "<your-age-public-key>"

# Encrypt:
sops --encrypt kubernetes/apps/security/vaultwarden/secrets.yaml > \
  kubernetes/apps/security/vaultwarden/secrets.enc.yaml

# ArgoCD decrypts via argocd-vault-plugin or helm-secrets
```

### Option B: Sealed Secrets
```bash
helm install sealed-secrets sealed-secrets/sealed-secrets --namespace kube-system
kubeseal --fetch-cert > pub-cert.pem
kubectl create secret generic my-secret --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem -o yaml > my-sealed-secret.yaml
```

---

## Repo Housekeeping

`.gitignore`:
```
# Terraform
terraform/.terraform/
terraform/*.tfstate
terraform/*.tfstate.backup
terraform/terraform.tfvars
terraform/**/.terraform.lock.hcl

# Secrets (never commit unencrypted)
**/secrets.yaml
**/*.dec.yaml
.env
```

`terraform/terraform.tfvars.example`:
```hcl
cloudflare_api_token  = "your-cloudflare-api-token"
cloudflare_account_id = "your-account-id"
cloudflare_zone_id    = "your-zone-id"
cloudflare_zone       = "felipemalacarne.com.br"
```

---

## Namespaces

`kubernetes/base/namespaces.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: networking
---
apiVersion: v1
kind: Namespace
metadata:
  name: data
---
apiVersion: v1
kind: Namespace
metadata:
  name: media
---
apiVersion: v1
kind: Namespace
metadata:
  name: security
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: Namespace
metadata:
  name: tailscale
```

---

## Deployment Order (Checklist)

### Phase 1 — Base
- [ ] Disable `systemd-resolved` stub listener on saradomin host (see Pi-hole note)
- [ ] `mkdir -p /data/media /data/k3s-storage` on saradomin host
- [ ] Install k3s with `--disable traefik --disable servicelb`
- [ ] Copy kubeconfig to zaros, update server address to Tailscale IP
- [ ] Install Tailscale on host: `tailscale up --advertise-routes=10.42.0.0/16,10.43.0.0/16 --accept-dns=false`
- [ ] Approve routes in Tailscale admin panel
- [ ] `helm install argocd` with `kubernetes/bootstrap/argocd-values.yaml`
- [ ] `kubectl apply -f kubernetes/bootstrap/root-app.yaml` — from here ArgoCD manages everything

### Phase 2 — Networking
- [ ] Apply `kubernetes/base/namespaces.yaml`
- [ ] Create `cloudflare-api-token` secret in `networking` namespace (DNS-01 solver)
- [ ] ArgoCD: deploy cert-manager → apply `cluster-issuer.yaml` after CRDs are ready
- [ ] ArgoCD: deploy Traefik
- [ ] Create Tailscale OAuth secret in `tailscale` namespace
- [ ] ArgoCD: deploy Tailscale operator
- [ ] Create R2 API token in Cloudflare dashboard (R2 → Manage R2 API Tokens)
- [ ] `kubectl create secret generic longhorn-r2-secret ...` in `longhorn-system`
- [ ] ArgoCD: deploy Longhorn; verify backup target shows green in Longhorn UI
- [ ] Create `pihole-secret` in `networking` namespace
- [ ] ArgoCD: deploy Pi-hole; set saradomin Tailscale IP as DNS in Tailscale admin panel
- [ ] `terraform apply` → creates R2 buckets, tunnels, DNS records
- [ ] `terraform output -raw tunnel_token | kubectl create secret generic cloudflared-token ...`
- [ ] ArgoCD: deploy cloudflared

### Phase 3 — Services
- [ ] ArgoCD: deploy PostgreSQL
- [ ] Exec into postgres pod and create `vaultwarden` DB + user
- [ ] Create `vaultwarden-secret` with full `database_url` value
- [ ] ArgoCD: deploy Vaultwarden; verify `vault.felipemalacarne.com.br` loads
- [ ] Confirm `/data/media` is populated on host
- [ ] ArgoCD: deploy intel-gpu-plugin; verify `gpu.intel.com/i915: "1"` in node allocatable
- [ ] ArgoCD: deploy Jellyfin; verify QuickSync: `ffmpeg -init_hw_device qsv=hw ...`

### Phase 4 — Observability
- [ ] ArgoCD: deploy kube-prometheus-stack
- [ ] Verify Grafana accessible via Tailscale hostname `grafana`
- [ ] Import or build a k3s/node dashboard in Grafana

---

## Verification Checklist

- [ ] SSH into saradomin from zaros via Tailscale
- [ ] ArgoCD dashboard accessible via Tailscale — all apps `Synced` / `Healthy`
- [ ] Pi-hole blocks ads on test device using Tailscale DNS
- [ ] `vault.felipemalacarne.com.br` loads Vaultwarden, create account and entry
- [ ] `jellyfin.felipemalacarne.com.br` loads media library
- [ ] Jellyfin hardware transcode confirmed (`ffmpeg` uses `h264_qsv`)
- [ ] Jellyfin accessible via Tailscale IP directly
- [ ] Longhorn UI shows backup target connected to R2 (`saradomin-longhorn` bucket)
- [ ] Trigger manual Longhorn snapshot on PostgreSQL PVC, confirm object appears in R2 bucket
- [ ] Grafana shows k3s node metrics

---

## Key Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Traefik install | ArgoCD Helm (k3s built-in disabled) | Full GitOps control |
| Storage | Longhorn | Snapshots + R2 backup (S3-compatible) |
| Media storage | HostPath `/data/media` | Too large for Longhorn/bucket |
| Tailscale | k8s operator (per-service) | Granular access control |
| Vaultwarden DB | PostgreSQL (shared cluster) | Consistent, reusable |
| TLS | cert-manager + Cloudflare DNS-01 | Same as zamorak pattern |
| Cloudflare | Single tunnel → Traefik | Traefik handles host routing |
| Secrets in Git | SOPS or SealedSecrets | Never store raw secrets |
| Terraform state backend | Cloudflare R2 (`saradomin-tfstate`) | Centralize on Cloudflare, no GCP dependency |
| Longhorn backup target | Cloudflare R2 (`saradomin-longhorn`) | S3-compatible, no GCP dependency |
