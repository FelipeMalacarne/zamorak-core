Here’s a **concise, structured summary** you can save and come back to later. It captures the *decisions*, *why they were made*, and the *current state* of your setup.

---

# 📘 k3s + Observability Stack – Conversation Summary

## 🖥️ Base Environment

* **Platform**: Oracle VM
* **Specs**: 4 vCPU, 24 GB RAM
* **OS**: Ubuntu
* **Kubernetes**: k3s (single-node)
* **Ingress**: Traefik (k3s default)
* **TLS**: cert-manager + Let’s Encrypt (HTTP-01)
* **DNS**: `*.felipemalacarne.com.br` → VM public IP
* **Storage**: `local-path-provisioner`, abstracted via `/data/k3s-storage` symlink for future block volume migration

---

## 🔐 HTTPS & Ingress

* Traefik works out of the box in k3s
* cert-manager was initially broken (missing controller pod)
* Fixed by reinstalling cert-manager
* TLS now works correctly:

  * Example: `https://nginx.felipemalacarne.com.br`
* Recommendation:

  * Add HTTP → HTTPS redirect via Traefik middleware
  * Consider wildcard cert later (DNS-01)

---

## 🧱 Storage Strategy (Future-Proofed)

* Avoid binding PVCs directly to `/var/lib/rancher/k3s/storage`
* Use:

  ```
  /var/lib/rancher/k3s/storage → /data/k3s-storage
  ```
* This allows painless migration to Oracle Block Volume later
* Use named StorageClasses + `Retain` for important data

---

## 📊 Observability Stack Decision

### ❌ Rejected (for now)

* ClickHouse (too heavy for single VM)
* Mimir (overkill)

### ✅ Chosen Stack (LGTM)

* **Metrics**: Prometheus
* **Logs**: Loki (later)
* **Traces**: Tempo (later)
* **UI**: Grafana

**Why**:

* Lightweight
* Kubernetes-native
* Low operational overhead
* Perfect for single-node clusters
* Easy future migration if needed

---

## 🧠 Tooling Philosophy

### Terraform

* Use for:

  * Cloud infrastructure (VMs, networking, DNS)
  * Optional: k3s install
* Do NOT use for:

  * App deployments
  * Helm releases
  * Kubernetes Secrets (state file risk)

### Argo CD (Chosen)

* First time using it, but worth learning
* Used for:

  * Monitoring stack
  * Applications
  * Ingresses
  * Continuous reconciliation (GitOps)
* Terraform may bootstrap Argo CD, then Argo takes over

---

## 📂 Git Repository Structure

```text
kubernetes/
├── bootstrap/
│   └── argocd-values.yaml
├── base/
│   └── namespaces.yaml
└── apps/
    └── monitoring/
        ├── application.yaml
        ├── prometheus-values.yaml
        └── grafana-values.yaml
```

---

## 🚀 Argo CD Setup

* Installed via **Helm**
* Exposed at:

  ```
  https://argocd.felipemalacarne.com.br
  ```
* TLS handled by Traefik + cert-manager
* `server.insecure: true` (TLS terminated at ingress)

---

## 📈 Monitoring Stack (Current State)

### Prometheus

* Chart: `kube-prometheus-stack`
* Alertmanager disabled
* Grafana disabled (external)
* Retention: **5 days**
* Storage: **20 Gi PVC**
* Resource-limited to protect apps

### Grafana

* Installed separately
* Exposed via Ingress + HTTPS
* Prometheus datasource auto-configured
* PVC enabled
* Resource-limited
* Admin password temporary (to be secured later)

### Managed by:

* **Single Argo CD Application**
* Auto-sync + self-heal enabled

---

## 🔜 Planned Next Steps

1. Secure Grafana credentials (Secret / SealedSecret)
2. Import Kubernetes dashboards
3. Add Loki (logs)
4. Add Tempo (traces)
5. Add basic alerting rules

---

## 🧠 Key Principles Learned

* Observability must never starve app workloads
* GitOps (Argo CD) fits Kubernetes better than Terraform for apps
* Start simple, evolve incrementally
* Design storage & observability for future growth, not current scale

---

If you want later, I can:

* Turn this into a **README.md**
* Convert it into a **checklist**
* Or help you resume exactly at **Loki**, **Tempo**, or **security hardening**
