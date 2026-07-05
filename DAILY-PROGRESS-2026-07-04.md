# Daily Progress - 2026-07-04

## Objective
Build a local CAPI + ArgoCD lab that models a realistic GitOps flow:
- Bootstrap a management cluster.
- Create a hub workload cluster via CAPI.
- Install ArgoCD on hub.
- Use ArgoCD to drive workload cluster creation through the management cluster.

## What We Completed

### 1. Repository setup and remote publishing
- Initialized local git repository on `main`.
- Added initial lab files and commits.
- Switched GitHub auth from enterprise-managed account to personal account.
- Fixed a global git rewrite rule that was forcing GitHub HTTPS URLs to SSH.
- Successfully pushed repository to:
  - `https://github.com/RatanVMistry/gitops-capi-argocd-lab`

Why this mattered:
- GitHub had to be the source of truth for cluster manifests and GitOps flow.
- Push failures were not code issues; they were auth + git transport config issues.

### 2. Lab scaffold and automation scripts
Created project structure:
- `clusters/`
- `bootstrap/`
- `platform/`
- `apps/` (with stateful/stateless substructure)
- `scripts/`

Added scripts:
- `scripts/prechecks.sh`
  - Verifies Docker and required CLI tools.
- `scripts/bootstrap-mgmt.sh`
  - Creates `kind` management cluster.
  - Installs CAPI core + kubeadm bootstrap/control-plane providers + CAPD provider.

Why this mattered:
- Reduced repeated manual setup steps.
- Made the lab reproducible and easy to restart.

### 3. Management cluster bootstrap (Part A)
- Ran `bootstrap-mgmt.sh` successfully.
- Verified providers installed:
  - `cluster-api`
  - `bootstrap-kubeadm`
  - `control-plane-kubeadm`
  - `infrastructure-docker`

Why this mattered:
- This is the control plane where desired state for cluster lifecycle is reconciled.

### 4. Hub cluster creation via CAPI
- Generated and applied `clusters/hub.yaml` using Kubernetes `v1.36.1`.
- Initially hub control plane was not fully Ready due to missing CNI in workload cluster.
- Installed Calico on hub.
- Scaled hub to include one worker node (`replicas: 1`) for a more realistic mini-env.

Why this mattered:
- CAPI does not install CNI by default in this quick-start flow.
- Single-node control-plane-only hub caused scheduling constraints for some components.
- Adding a worker improves stability for platform workloads (like ArgoCD).

### 5. ArgoCD installation on hub
- Installed ArgoCD on hub using Helm values in:
  - `bootstrap/argocd-helm-values.yaml`
- Verified all major ArgoCD components running.

Issue encountered:
- Port-forward instability (`connection reset by peer`) occurred repeatedly.

How we handled it:
- Confirmed ArgoCD server itself was healthy.
- Used `argocd --core` as a reliable operational workaround when tunnel was unstable.
- Validated UI eventually worked and login as `admin` succeeded.

Why this mattered:
- It unblocked progress even when local tunnel behavior was flaky.

### 6. Context and kubeconfig hygiene
- Merged `hub.kubeconfig` into global kubeconfig.
- Renamed context to `hub` for easy switching.
- Cleaned obsolete contexts (especially `teleport-qa-cluster*`).

Why this mattered:
- Reduced operator error while switching between `kind-mgmt` and `hub`.
- Simplified commands and improved daily workflow.

### 7. ArgoCD-driven CAPI cluster management
Created ArgoCD Application manifest:
- `platform/app-capi-clusters.yaml`
- Source path: `clusters/`
- Destination: management cluster (`kind-mgmt`)

Issue encountered:
- ArgoCD initially registered mgmt endpoint as `127.0.0.1:<port>`, unreachable from ArgoCD pods.

Fix:
- Patched ArgoCD cluster secret to use mgmt Docker-network API endpoint (`https://172.18.0.2:6443`).
- Forced hard refresh.
- App moved to `Synced` and `Healthy`.

Why this mattered:
- ArgoCD pod network cannot use your laptop localhost endpoint.
- This was the key fix that enabled true in-cluster GitOps reconciliation.

### 8. Dev cluster via GitOps
- Added and pushed `clusters/dev.yaml`.
- ArgoCD `capi-clusters` app synced and created `dev` CAPI resources on mgmt.
- Initially installed Calico in `dev` workload cluster manually.
- Verified dev control plane + worker reached `Ready`.

Why this mattered:
- Demonstrated complete chain:
  - Git commit -> ArgoCD sync -> CAPI reconcile -> workload cluster ready.

### 9. Automated CNI with ClusterResourceSet
Added automatic Calico installation for labeled clusters:
- `clusters/addons/calico-manifests-configmap.yaml`
- `clusters/addons/calico-clusterresourceset.yaml`
- Added label `cni: calico` to `hub` and `dev` cluster manifests.

Verification:
- `ClusterResourceSet` reported `Applied=True`.
- `ClusterResourceSetBinding` objects were created for both `hub` and `dev` with resource `applied: true`.

Why this mattered:
- Removed repeated manual CNI installation after each cluster creation.
- Solved the common NodeNotReady pattern caused by missing network plugin.

### 10. QA cluster added through GitOps
- Added and pushed `clusters/qa.yaml` with label `cni: calico`.
- ArgoCD reconciled it through the same CAPI management flow.
- `qa` control plane + worker both reached `Ready`.
- `ClusterResourceSetBinding` for `qa` confirmed Calico was auto-applied.

Why this mattered:
- Proved CNI automation works for new clusters without manual kubectl apply.
- Confirmed repeatable Git commit -> ArgoCD -> CAPI -> ready cluster pipeline.

### 11. Switched ArgoCD to one app per cluster
Replaced monolithic cluster app model with per-cluster app generation:
- Updated `platform/app-capi-clusters.yaml` from single `Application` to `ApplicationSet`.
- Each cluster file now gets its own app in UI (`capi-hub`, `capi-dev`, `capi-qa`).
- Excluded `clusters/addons/*.yaml` from app generation to keep UI focused.

Why this mattered:
- Greatly improved ArgoCD UI readability and troubleshooting.
- Avoided very large mixed-resource app trees as cluster count grows.

### 12. Commit author identity cleanup
- Updated repo-local git identity to personal values.
- Rewrote all `main` branch commit author/committer metadata to:
  - `RatanVMistry <ratan.mistry30@gmail.com>`
- Force-pushed rewritten history and verified ArgoCD synced to new revision.

Why this mattered:
- Removed corporate email identity from personal-lab commit history.
- Ensured ArgoCD UI author metadata reflects personal identity.

### 13. Onboarded dev and qa as direct ArgoCD destination clusters
- Registered `dev` and `qa` as ArgoCD cluster secrets in `argocd` namespace on hub.
- Created per-cluster service account and cluster role binding on both workload clusters:
  - `argocd-manager` service account in `kube-system`
  - `argocd-manager-role-binding` to `cluster-admin` (lab scope)
- Verified cluster registration with:
  - `argocd --core --kube-context hub cluster list`

Why this mattered:
- This enables future app deployment directly to workload clusters from ArgoCD.
- It separates cluster lifecycle management (to `kind-mgmt`) from workload app deployment (to `dev`/`qa`).

### 14. Fixed kubeconfig endpoints for local kubectl access to dev and qa
- Discovered macOS host cannot directly reach CAPD internal endpoints like `172.18.x.x`.
- Derived host-mapped API ports from Docker load balancers:
  - `dev-lb` -> `127.0.0.1:32772`
  - `qa-lb` -> `127.0.0.1:32775`
- Rewrote local kubeconfig server endpoints for laptop use and added contexts:
  - `dev`
  - `qa`
- Saved working kubeconfig artifacts:
  - `dev.kubeconfig`
  - `qa.kubeconfig`

Why this mattered:
- `kubectl --context dev ...` and `kubectl --context qa ...` now work consistently from laptop.
- Prevents repeated timeout/debug cycles caused by internal-only endpoint usage from host.

### 15. Clarified ArgoCD `Unknown` status for dev/qa clusters
- Observed in ArgoCD:
  - `dev` -> `Unknown`
  - `qa` -> `Unknown`
- Verified message indicates:
  - `Cluster has no applications and is not being monitored.`

Why this mattered:
- `Unknown` here is informational, not a connectivity failure.
- Status will become actively monitored once apps are targeted to those destinations.

## Key Problems We Fixed (with root cause)

1. Git push/auth failures
- Root cause: wrong GitHub account + global HTTPS->SSH rewrite.
- Fix: account switch + remove rewrite rules.

2. Hub/dev/qa nodes not Ready after cluster creation
- Root cause: no CNI installed by default.
- Fix: automated Calico using `ClusterResourceSet` and `cni: calico` labels.

3. ArgoCD app comparison errors to mgmt cluster
- Root cause: ArgoCD cluster endpoint registered as localhost from laptop perspective.
- Fix: update destination cluster secret to Docker-network reachable endpoint.

4. ArgoCD login instability from CLI
- Root cause: intermittent port-forward resets in this local CAPD topology.
- Fix: use `--core` CLI path and continue with UI/cluster operations.

5. Local kubectl access to workload clusters timing out
- Root cause: workload kubeconfigs used Docker-network API endpoints (`172.18.x.x`) not directly reachable from macOS host.
- Fix: rewrite local kubeconfig endpoints to Docker published localhost ports while keeping ArgoCD cluster secrets on pod-reachable internal endpoints.

## Current Status (end of day)
- Repository has current-day progress/doc updates pending commit.
- Management cluster (`kind-mgmt`) healthy.
- Hub cluster healthy (control plane + 1 worker).
- ArgoCD installed on hub and operational.
- ArgoCD now uses one-app-per-cluster model via ApplicationSet (`capi-hub`, `capi-dev`, `capi-qa` all synced/healthy).
- Dev and QA clusters both created via ArgoCD -> CAPI flow and now Ready.
- Calico auto-install is enabled for labeled clusters via ClusterResourceSet.
- Dev and QA are also onboarded as direct ArgoCD destinations (`cluster-dev`, `cluster-qa`).
- Local kubectl contexts `dev` and `qa` are configured and validated.

## Files Added/Updated Today
- `.gitignore`
- `README.md`
- `capi-argocd-lab.md`
- `scripts/prechecks.sh`
- `scripts/bootstrap-mgmt.sh`
- `clusters/hub.yaml`
- `clusters/dev.yaml`
- `clusters/qa.yaml`
- `clusters/addons/calico-manifests-configmap.yaml`
- `clusters/addons/calico-clusterresourceset.yaml`
- `bootstrap/argocd-helm-values.yaml`
- `platform/app-capi-clusters.yaml`
- `dev.kubeconfig`
- `qa.kubeconfig`
- `DAILY-PROGRESS-2026-07-04.md`

## Commits Created
- `dfebdcc` Initial lab scaffold
- `92e9f60` Add repo scaffold and lab guide
- `304a483` Add lab scaffold and precheck script
- `24595a7` Add mgmt cluster bootstrap script
- `5451bfb` Add dev workload cluster manifest
- `8081363` Add ArgoCD app for CAPI cluster manifests
- `7125405` Automate Calico via ClusterResourceSet
- `52cc4ed` Add qa workload cluster manifest
- `f887905` Switch to per-cluster ArgoCD apps

## Recommended Next Steps (next session)
1. Add `prod-us` and `prod-eu` manifests with `cni: calico` and validate they auto-bootstrap with CNI.
2. Add ArgoCD ApplicationSet for app workloads (`apps/`) and start progressive promotion path to `dev` and `qa` destinations.
3. Add a reusable script to onboard any new workload cluster as ArgoCD destination (RBAC + token + secret).
4. Add guardrails so CAPI cluster destination registration does not drift to localhost endpoints.
5. Add small runbooks for:
   - kubeconfig endpoint rewrites in CAPD
   - ArgoCD destination cluster registration checks
   - cluster readiness triage (`Cluster`, `KCP`, `Machine`, `Node` layers)
