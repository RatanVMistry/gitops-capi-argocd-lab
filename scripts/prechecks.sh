#!/usr/bin/env bash

set -euo pipefail

echo "Checking Docker..."
docker info >/dev/null

echo "Checking installed tools..."
kind version
kubectl version --client
clusterctl version
helm version
argocd version --client

echo "Checking repo state..."
git status --short

echo "Prechecks passed."
