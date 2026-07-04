# CAPI + ArgoCD Multi-Cluster GitOps Lab (Demo Edition)

**Source of truth repo:** `github.com/RatanVMistry/gitops-capi-argocd-lab` (create this repo — layout in §2)
**Runs on:** a single Mac laptop, Docker Desktop, `kind` + Cluster API (CAPD) + ArgoCD
**Audience takeaway:** cluster lifecycle (CAPI) and application lifecycle (ArgoCD) both run as GitOps, with a
real two-dimensional progressive-delivery pipeline — dev → qa → prod, one prod region at a time, with in-cluster
canary + automatic rollback on bad metrics.

> Design note up front: everything below is standard, currently-documented tooling — CAPD, ArgoCD Helm chart,
> ApplicationSet Cluster generator, ApplicationSet Progressive Syncs (`RollingSync`), Argo Rollouts + AnalysisTemplate.
> I've called out the one place a public Helm chart doesn't map 1:1 onto what we need (§8) and what I did instead.

---

## Table of contents

1. [The pitch (for your audience)](#1-the-pitch)
2. [Architecture](#2-architecture)
3. [Repository layout](#3-repository-layout)
4. [Prerequisites & resource budget](#4-prerequisites--resource-budget)
5. [Part A — bootstrap `mgmt` (CAPI + CAPD)](#5-part-a)
6. [Part B — CAPI-provision `hub`, install ArgoCD via Helm](#6-part-b)
7. [Part C — CAPI-provision `dev` / `qa` / `prod-us` / `prod-eu`](#7-part-c)
8. [Part D — stateless app: podinfo as an Argo Rollouts canary](#8-part-d)
9. [Part E — stateful app: Valkey via the official Helm chart](#9-part-e)
10. [Part F — platform layer via ApplicationSet](#10-part-f)
11. [Part G — the promotion pipeline: dev → qa → prod (RollingSync)](#11-part-g)
12. [Live demo script — happy path upgrade](#12-demo-happy-path)
13. [Live demo script — induced failure + automatic rollback](#13-demo-failure-rollback)
14. [Live demo script — stateful upgrade + git-revert rollback](#14-demo-stateful-rollback)
15. [Part H — hands-on SRE drills](#15-part-hands-on-sre-drills)
16. [Troubleshooting](#16-troubleshooting)
17. [Teardown](#17-teardown)

---

## 1. The pitch (for your audience) — <a name="1-the-pitch"></a>

Say this, roughly, at the top of the demo:

> "Everything you're about to see — which Kubernetes clusters exist, what's running on them, and in what order
> an upgrade rolls out — is defined in **one git repository**. Nothing here was `kubectl apply`'d by hand except
> the very first bootstrap step. If I want a new production region, I add a file. If a deploy goes bad, the
> system rolls itself back before I've even opened a laptop."

Two controllers do all the work:
- **Cluster API (CAPI)** — cluster lifecycle as Kubernetes objects (`Cluster`, `MachineDeployment`, etc.)
- **ArgoCD** — application lifecycle as Kubernetes objects (`Application`, `ApplicationSet`), continuously
  reconciling git → cluster

---

## 2. Architecture — <a name="2-architecture"></a>

```
┌───────────────────────────────────────────────────────────────────────┐
│                         mgmt  (kind cluster — the ONLY one you         │
│                                `kind create` by hand)                  │
│                                                                          │
│   CAPI core + CAPD (Docker infra provider)                             │
│   Reconciles Cluster/KubeadmControlPlane/MachineDeployment objects      │
│   for FOUR child clusters, each running as Docker containers:          │
│                                                                          │
│   ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐          │
│   │  hub   │  │  dev   │  │   qa   │  │prod-us │  │prod-eu │(optional,│
│   │        │  │        │  │        │  │        │  │        │ add live │
│   └────┬───┘  └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘ in demo) │
└────────┼──────────┼───────────┼───────────┼───────────┼───────────────┘
         │           │           │           │           │
   Helm-installed ArgoCD lives here. It registers dev/qa/prod-* as
   remote clusters and pushes apps + platform components into them.
         │
         ├─ ApplicationSet "platform" ──► Argo Rollouts + Prometheus on each spoke
         │
         └─ ApplicationSet "apps" (RollingSync: dev → qa → prod, 1-then-rest)
                  ├─► app-stateless (podinfo, Rollout+canary+AnalysisTemplate)
                  └─► app-stateful  (Valkey, official Helm chart, StatefulSet)
```

Two independent "blast radius" gates compose here, and this is the core concept to narrate to your audience:
- **`RollingSync`** (ApplicationSet) decides **which cluster** gets the new version next, and won't advance if the
  previous cluster isn't `Healthy`.
- **Argo Rollouts canary + AnalysisTemplate** decides, **within one cluster**, what % of traffic the new version
  gets, based on live Prometheus metrics, and auto-aborts if the metrics are bad.

A change has to clear *both* gates to reach 100% in every region. This is genuinely how large multi-region
services roll out changes — it's not a simplification for the lab.

**Traffic routing vs. rollout order — a distinction worth stating explicitly to your audience:** which prod
cluster actually serves a given user (nearest-region routing) is a separate concern handled by DNS/GSLB or a
service-mesh gateway (Route53 latency routing, Cloudflare, Istio multi-cluster) — not by ArgoCD or Rollouts. This
lab controls *when* each region gets new code, not *which region a user's request lands on*. Worth a slide of
its own if your audience asks about it.

---

## 3. Repository layout — <a name="3-repository-layout"></a>

```
gitops-capi-argocd-lab/
├── clusters/
│   ├── hub.yaml                  # CAPI Cluster manifest for the ArgoCD hub
│   ├── dev.yaml
│   ├── qa.yaml
│   ├── prod-us.yaml
│   └── prod-eu.yaml              # add mid-demo to show live cluster onboarding
├── bootstrap/
│   └── argocd-helm-values.yaml   # values.yaml for the argo/argo-cd chart
├── platform/
│   └── applicationset-platform.yaml   # Argo Rollouts + Prometheus, fanned to every spoke
├── apps/
│   ├── app-stateless/
│   │   ├── Chart.yaml            # thin wrapper chart — see §8 for why
│   │   ├── values.yaml           # image tag, replica count, fault-injection toggle
│   │   └── templates/
│   │       ├── rollout.yaml
│   │       ├── analysistemplate.yaml
│   │       ├── service-canary.yaml
│   │       └── service-stable.yaml
│   ├── app-stateful/
│   │   ├── values.yaml           # values for the official valkey-io/valkey-helm chart
│   │   └── pdb.yaml
│   └── applicationset-apps.yaml  # RollingSync: dev → qa → prod-us → prod-eu
└── README.md
```

---

## 4. Prerequisites & resource budget — <a name="4-prerequisites--resource-budget"></a>

```bash
brew install kind kubectl clusterctl helm argocd k9s
```

Docker Desktop → Settings → Resources: **at least 8 GB RAM / 6 CPU** dedicated to Docker. You're running up to
5 control planes + a couple of worker nodes as containers, each with its own etcd/apiserver/kubelet — genuinely
heavier than it looks. **For the live demo, bring up `mgmt / hub / dev / qa / prod-us` beforehand** and add
`prod-eu` live on stage (§13) rather than running all 6 clusters cold in front of an audience.

### Prechecks before Part A

Run these first and do not continue if any of them fail:

```bash
docker info >/dev/null
kind version
kubectl version --client
clusterctl version
helm version
argocd version --client
git status --short
```

If you want to be extra strict, also confirm Docker Desktop has the RAM and CPU budget above before you start.

---

## 5. Part A — bootstrap `mgmt` — <a name="5-part-a"></a>

```bash
cat > kind-mgmt.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: mgmt
networking: {ipFamily: dual}
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
EOF
kind create cluster --config kind-mgmt.yaml
kubectl config use-context kind-mgmt

export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure docker
kubectl get pods -A --watch   # Ctrl+C once capi-system / capd-system / capi-kubeadm-* are 1/1
```

**Checkpoint:** `clusterctl describe cluster` won't work yet (no clusters exist) — you're just confirming the
controllers are up. `kubectl get providers -A` should list `cluster-api`, `bootstrap-kubeadm`,
`control-plane-kubeadm`, `infrastructure-docker`, all `Installed`.

---

## 6. Part B — CAPI-provision `hub`, install ArgoCD via Helm — <a name="6-part-b"></a>

Generate the CAPI manifest for the hub cluster and **commit it to git first** — this is the whole point:

```bash
clusterctl generate cluster hub \
  --flavor development \
  --kubernetes-version v1.31.0 \
  --control-plane-machine-count=1 \
  --worker-machine-count=0 \
  > clusters/hub.yaml
git add clusters/hub.yaml && git commit -m "Add hub cluster manifest" && git push

kubectl apply -f clusters/hub.yaml
kubectl get cluster,kubeadmcontrolplane hub --watch   # Ctrl+C once Provisioned/Ready

clusterctl get kubeconfig hub > hub.kubeconfig
kubectl --kubeconfig=hub.kubeconfig apply -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl --kubeconfig=hub.kubeconfig get nodes --watch   # wait for Ready
```

Install ArgoCD **via the Helm chart** (per your ask, not raw manifests):

```bash
export KUBECONFIG=hub.kubeconfig
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

cat > bootstrap/argocd-helm-values.yaml <<'EOF'
server:
  service:
    type: ClusterIP
configs:
  params:
    server.insecure: true   # fine for local demo; terminate TLS at a real ingress in prod
applicationSet:
  args:
    - --enable-progressive-syncs   # required for RollingSync — see §11
EOF

helm install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f bootstrap/argocd-helm-values.yaml

kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
argocd login localhost:8080 --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
  --insecure
```

**Checkpoint / demo beat:** open `http://localhost:8080` in a browser — an empty ArgoCD UI, nothing deployed
yet. Good moment to say "this is a completely empty control plane; everything from here is a git commit."

---

## 7. Part C — CAPI-provision `dev` / `qa` / `prod-us` (`/prod-eu`) — <a name="7-part-c"></a>

Repeat for each workload cluster (back on `mgmt` context):

```bash
kubectl config use-context kind-mgmt

for name in dev qa; do
  clusterctl generate cluster "$name" \
    --flavor development --kubernetes-version v1.31.0 \
    --control-plane-machine-count=1 --worker-machine-count=1 \
    > "clusters/${name}.yaml"
done

# prod clusters get 2 workers to look more "real" and to have somewhere for canary pods to land
for name in prod-us prod-eu; do
  clusterctl generate cluster "$name" \
    --flavor development --kubernetes-version v1.31.0 \
    --control-plane-machine-count=1 --worker-machine-count=2 \
    > "clusters/${name}.yaml"
done

git add clusters/ && git commit -m "Add dev/qa/prod-us/prod-eu cluster manifests" && git push

# for the initial demo setup, apply dev/qa/prod-us now; hold prod-eu back for the live "add a region" beat
kubectl apply -f clusters/dev.yaml -f clusters/qa.yaml -f clusters/prod-us.yaml
kubectl get clusters --watch   # wait for all three Provisioned
```

Install CNI + register each into ArgoCD, and **label by env/region** — the labels are what `RollingSync` and the
Cluster generator key off of:

```bash
for name in dev qa prod-us; do
  clusterctl get kubeconfig "$name" > "${name}.kubeconfig"
  kubectl --kubeconfig="${name}.kubeconfig" apply -f \
    https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
done

export KUBECONFIG=hub.kubeconfig
argocd cluster add dev-admin@dev --name dev --kubeconfig dev.kubeconfig
argocd cluster add qa-admin@qa --name qa --kubeconfig qa.kubeconfig
argocd cluster add prod-us-admin@prod-us --name prod-us --kubeconfig prod-us.kubeconfig

kubectl -n argocd label secret cluster-dev      env=dev
kubectl -n argocd label secret cluster-qa       env=qa
kubectl -n argocd label secret cluster-prod-us  env=prod region=us

argocd cluster list   # confirm all 3 + in-cluster show Successful
```

---

## 8. Part D — stateless app: podinfo as an Argo Rollouts canary — <a name="8-part-d"></a>

**Why not just deploy the public podinfo Helm chart directly?** The upstream `podinfo/podinfo` chart (repo:
`https://stefanprodan.github.io/podinfo`) templates a `kind: Deployment` — Helm charts essentially never ship
`kind: Rollout`, since that's an Argo-specific CRD. So the standard approach (used across real platform teams) is
a **thin local chart** that reuses podinfo's public container image (`ghcr.io/stefanprodan/podinfo`) but emits a
`Rollout` instead of a `Deployment`. This is still "using the public app" — you get podinfo's built-in
`/metrics` (Prometheus format) and its `/fault_injection/enable` endpoint, which is genuinely built for exactly
this kind of canary-analysis demo.

`apps/app-stateless/Chart.yaml`:
```yaml
apiVersion: v2
name: podinfo-rollout
version: 0.1.0
appVersion: "6.7.1"
```

`apps/app-stateless/values.yaml`:
```yaml
image:
  repository: ghcr.io/stefanprodan/podinfo
  tag: 6.7.1
replicaCount: 5
```

`apps/app-stateless/templates/rollout.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: podinfo
  namespace: apps
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels: {app: podinfo}
  template:
    metadata:
      labels: {app: podinfo}
    spec:
      containers:
        - name: podinfo
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports: [{containerPort: 9898, name: http}]
          command: ["./podinfo", "--port=9898", "--level=info"]
  strategy:
    canary:
      canaryService: podinfo-canary
      stableService: podinfo-stable
      steps:
        - setWeight: 20
        - pause: {duration: 1m}
        - analysis:
            templates: [{templateName: success-rate}]
            args: [{name: service-name, value: podinfo-canary}]
        - setWeight: 50
        - pause: {duration: 1m}
        - setWeight: 100
```

`apps/app-stateless/templates/analysistemplate.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: apps
spec:
  args: [{name: service-name}]
  metrics:
    - name: success-rate
      interval: 30s
      count: 5
      failureLimit: 2
      successCondition: "result[0] >= 0.95"
      provider:
        prometheus:
          address: http://prometheus-server.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(http_requests_total{service="{{`{{args.service-name}}`}}",status!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{service="{{`{{args.service-name}}`}}"}[2m]))
```
(podinfo exposes `http_requests_total` natively at `/metrics` — no extra instrumentation needed.)

`templates/service-canary.yaml` / `templates/service-stable.yaml`: plain `Service` objects selecting
`app: podinfo`, `port: 9898`, named `podinfo-canary` / `podinfo-stable` (Argo Rollouts manages the pod-template
label selector under the hood — you don't hand-manage which pods each Service hits).

---

## 9. Part E — stateful app: Valkey via the official Helm chart — <a name="9-part-e"></a>

**Don't reach for a Bitnami chart here** — as of 2025-2026 Broadcom moved most versioned Bitnami images behind a
paid "Bitnami Secure Images" subscription and archived the old free ones to `bitnamilegacy` (unpatched, no
guarantee of longevity). For exactly this reason, the Valkey community published an **official, community
maintained chart** as the direct replacement: `valkey-io/valkey-helm`. Good talking point for your audience —
it's a live example of "know your supply chain," which is very on-brand for an SRE demo.

```bash
helm repo add valkey https://valkey.io/valkey-helm/
```

ArgoCD `Application` (via the apps `ApplicationSet` in §10) pointing at that chart:

```yaml
source:
  repoURL: https://valkey.io/valkey-helm/
  chart: valkey
  targetRevision: "*"          # pin to an exact version once you've picked one for the demo
  helm:
    valueFiles:
      - $values/apps/app-stateful/values.yaml
```

`apps/app-stateful/values.yaml` (replication topology → primary StatefulSet + replica StatefulSet, matching what
Bitnami's Redis/Valkey chart used to default to, so the concepts transfer):

```yaml
architecture: replication
primary:
  replicaCount: 1
replica:
  replicaCount: 2
auth:
  enabled: true
metrics:
  enabled: true    # Prometheus exporter — nice parity with the stateless app's metrics story
```

`apps/app-stateful/pdb.yaml` (guarantee at least N-1 replicas survive a voluntary disruption — this is the
control that makes stateful rollouts *slower and safer* than the stateless canary, worth narrating explicitly):

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: valkey-replica-pdb
  namespace: apps
spec:
  minAvailable: 1
  selector:
    matchLabels: {app.kubernetes.io/component: replica}
```

---

## 10. Part F — platform layer via ApplicationSet — <a name="10-part-f"></a>

`platform/applicationset-platform.yaml` installs Argo Rollouts + a lightweight Prometheus onto every registered
spoke cluster automatically — including any cluster you register *after* this ApplicationSet already exists
(that's the live "add prod-eu" demo beat in §13):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-components
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - clusters:
        selector:
          matchExpressions:
            - {key: env, operator: Exists}     # matches dev/qa/prod-*, excludes the hub itself
  template:
    metadata: {name: '{{.name}}-argo-rollouts'}
    spec:
      project: default
      source:
        repoURL: https://argoproj.github.io/argo-helm
        chart: argo-rollouts
        targetRevision: 2.35.0
        helm: {values: "dashboard:\n  enabled: true\n"}
      destination: {server: '{{.server}}', namespace: argo-rollouts}
      syncPolicy: {automated: {prune: true, selfHeal: true}, syncOptions: [CreateNamespace=true]}
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-monitoring
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - clusters: {selector: {matchExpressions: [{key: env, operator: Exists}]}}
  template:
    metadata: {name: '{{.name}}-prometheus'}
    spec:
      project: default
      source:
        repoURL: https://prometheus-community.github.io/helm-charts
        chart: prometheus
        targetRevision: "25.*"
        helm:
          values: |
            alertmanager: {enabled: false}
            server:
              persistentVolume: {enabled: false}   # keep it light for a laptop demo
      destination: {server: '{{.server}}', namespace: monitoring}
      syncPolicy: {automated: {prune: true, selfHeal: true}, syncOptions: [CreateNamespace=true]}
```

```bash
kubectl apply -f platform/applicationset-platform.yaml
argocd app list   # you should see *-argo-rollouts and *-prometheus for dev/qa/prod-us, Syncing → Healthy
```

---

## 11. Part G — the promotion pipeline: dev → qa → prod (RollingSync) — <a name="11-part-g"></a>

`apps/applicationset-apps.yaml` — this is the centerpiece of the demo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: apps-progressive-rollout
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - clusters: {selector: {matchExpressions: [{key: env, operator: Exists}]}}
          - list:
              elements:
                - app: podinfo
                  path: apps/app-stateless
                - app: valkey
                  path: apps/app-stateful
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions: [{key: env, operator: In, values: [dev]}]
          # maxUpdate unset → 100%, dev updates immediately
        - matchExpressions: [{key: env, operator: In, values: [qa]}]
          maxUpdate: 100%
        - matchExpressions: [{key: env, operator: In, values: [prod]}]
          maxUpdate: 1        # exactly one prod region first — prod-us, since it registers first
        - matchExpressions: [{key: env, operator: In, values: [prod]}]
          maxUpdate: 100%     # remaining prod regions (prod-eu, and any future one) once step above is Healthy
  template:
    metadata:
      name: '{{.app}}-{{.name}}'
      labels: {env: '{{.metadata.labels.env}}', region: '{{.metadata.labels.region}}', app: '{{.app}}'}
    spec:
      project: default
      source:
        repoURL: https://github.com/RatanVMistry/gitops-capi-argocd-lab.git
        targetRevision: main
        path: '{{.path}}'
      destination: {server: '{{.server}}', namespace: apps}
      syncPolicy: {syncOptions: [CreateNamespace=true]}
        # note: no `automated:` block — RollingSync drives sync itself and disables autosync
        # on its generated Applications; leaving `automated` here would just produce a
        # controller warning in the logs, per the ArgoCD docs.
```

```bash
kubectl apply -f apps/applicationset-apps.yaml
argocd appset get apps-progressive-rollout   # shows current rollout step + which Applications are pending
```

**What "Healthy" means for the gate, concretely:** for `app-stateless`, Healthy = the `Rollout` resource finished
its canary steps *including* the Prometheus `AnalysisRun` passing. For `app-stateful`, Healthy = the Valkey
`StatefulSet`s reached the desired ready replica count. `RollingSync` will not advance past a step whose
Applications aren't Healthy — that's your automatic "wait, then proceed" behavior, and it fails closed rather
than just timing out.

---

## 12. Live demo script — happy path upgrade — <a name="12-demo-happy-path"></a>

1. `git`: bump `apps/app-stateless/values.yaml` → `image.tag: 6.7.2`, commit, push.
2. Narrate while ArgoCD picks it up (or force it: `argocd app sync podinfo-dev`): "dev updates first, 100% at
   once — it's the lowest-risk environment."
3. Show `kubectl argo rollouts get rollout podinfo -n apps --context dev --watch` — canary steps ramping.
4. Once `dev` is Healthy, `RollingSync` auto-advances to `qa` — show `argocd appset get` ticking to the next step.
5. Once `qa` is Healthy, it advances to `prod` step 1 (`maxUpdate: 1`) — **only `prod-us` moves**. Point out
   `prod-eu` (once added) is untouched — that's the region-by-region gate working.
6. `prod-us` clears its own in-cluster canary + analysis → Healthy → final step fires → `prod-eu` updates.
7. End state: `argocd app list` shows every `podinfo-*` Application `Synced/Healthy` at the new tag.

---

## 13. Live demo script — induced failure + automatic rollback — <a name="13-demo-failure-rollback"></a>

This is the payoff moment — use podinfo's built-in fault injection instead of shipping a broken image:

1. Bump the tag again (any tag change triggers a new rollout — `6.7.2` → `6.7.2` won't retrigger, so bump a label
   or use `kubectl argo rollouts restart` if you want to reuse the same image).
2. As soon as the canary pod for the target environment is up, `kubectl exec` into it (or curl it directly) and
   call:
   ```bash
   curl -X POST http://<canary-pod-ip>:9898/fault_injection/enable
   ```
   This makes that pod return HTTP 500 on every app endpoint while probes/metrics stay healthy — so Rollouts
   keeps it in rotation long enough for the AnalysisRun to actually observe the failure, which is exactly what
   you want for a live demo (a crash-looping pod would just get evicted before the analysis runs).
3. Watch the `AnalysisRun`: `kubectl argo rollouts get rollout podinfo -n apps --context dev` — success-rate
   metric drops, `failureLimit: 2` trips.
4. **Argo Rollouts automatically aborts the canary and shifts all traffic back to the stable ReplicaSet** — no
   human, no `kubectl` command from you.
5. Point out `argocd app get podinfo-dev` now shows `OutOfSync` — narrate: "that's not a bug, that's the system
   telling us an automated safety rollback happened here; git says the new tag, the cluster is running the old
   one on purpose."
6. Because `RollingSync` requires Healthy before advancing, **`qa` and `prod` never see the bad version at all.**
   That's the whole point of the two-gate design — say this explicitly, it's the "wow" moment of the demo.
7. Recovery: `git revert` the bad commit (real fix) — push — watch `dev` re-sync clean and the pipeline resume
   from step 1.

---

## 14. Live demo script — stateful upgrade + git-revert rollback — <a name="14-demo-stateful-rollback"></a>

1. Bump `apps/app-stateful/values.yaml` image/version override, commit, push — same `RollingSync` pipeline
   applies (dev → qa → prod-us → prod-eu), but there's no in-cluster canary gate here — Healthy just means the
   `StatefulSet`s are ready.
2. Contrast pace on screen: `kubectl get pods -n apps -w --context dev` — note `OrderedReady` pod management
   (StatefulSet default) rolling replicas one at a time, versus how fast the stateless canary ramped.
3. Simulate a bad stateful change (e.g., a config value that breaks startup) → pods never go Ready → `RollingSync`
   stalls at that step, same fail-closed behavior as before.
4. Fix via `git revert HEAD && git push` — the audited, preferred path.
5. Mention (don't need to demo live) the break-glass alternative: `argocd app rollback valkey-dev <REVISION>` —
   and the caveat that you must follow it with a reconciling git commit or the next auto-reconcile will undo it.

---

## 15. Part H — hands-on SRE drills — <a name="15-part-hands-on-sre-drills"></a>

If the goal is to build Sr SRE muscle, these are the extra lab exercises I would add and actually practice:

1. Add a Grafana dashboard for the rollout path by installing something like kube-prometheus-stack into the platform layer. Show podinfo request success rate, analysis runs, ArgoCD sync status, and cluster readiness on one screen. The exercise is to spot a bad deploy before the rollback finishes, not just to watch controllers do work.
2. Add a real alert path in the same stack. Put one alert on rollout failure and one on error-budget burn rate, route them to Alertmanager, and verify you can trigger and silence them. That gives you the normal SRE loop of detect, triage, mitigate, and clear.
3. Run failure drills on purpose. Break the Prometheus query, kill a canary pod, scale a worker node down, stop an ArgoCD controller, and confirm you know exactly what changes in the UI and what the recovery step is.
4. Practice upgrades. Bump ArgoCD, Argo Rollouts, and the Kubernetes version one component at a time and write down the order you used, what broke, and how you verified the upgrade completed cleanly.
5. Practice restore, not only deploy. Delete one generated Application, remove one cluster secret, or recreate the hub cluster from git and prove the lab converges back to the desired state.
6. Turn each drill into a short runbook. A senior SRE interview is easier when you can explain the symptom, the check, the mitigation, and the postmortem action in under two minutes.

## 16. Troubleshooting — <a name="16-troubleshooting"></a>

- **`RollingSync` doesn't seem to do anything:** confirm `--enable-progressive-syncs` actually landed on the
  `applicationset-controller` pod (`kubectl -n argocd get deploy argocd-applicationset-controller -o yaml | grep
  progressive-syncs`) — it's easy to set it in Helm values and have it silently not apply if the key name drifts
  between chart versions.
- **Applications stuck `Progressing` forever:** for `app-stateless`, check the `AnalysisRun` object directly
  (`kubectl get analysisrun -n apps`) — a Prometheus query typo shows up as the analysis never producing a result,
  not as an obvious error.
- **CAPD workload cluster kubeconfig can't connect from the host:** macOS + Docker Desktop needs the LB-port
  rewrite mentioned in the CAPI docs; `clusterctl get kubeconfig` handles this for you, don't hand-roll it from
  the container IP.
- **Docker Desktop grinding to a halt with 5-6 clusters up:** this is expected on typical laptop RAM — drop
  `prod-eu` until the live demo moment, and reduce `replica.replicaCount` on Valkey to 1 for rehearsal runs.

---

## 17. Teardown — <a name="17-teardown"></a>

```bash
kind delete cluster --name mgmt   # removes hub/dev/qa/prod-us/prod-eu containers too — they're all
                                   # CAPD-reconciled children of Cluster objects that lived on mgmt
```
