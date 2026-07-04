#!/usr/bin/env bash

set -euo pipefail

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
kubectl get pods -A --watch
