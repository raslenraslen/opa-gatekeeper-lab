#!/usr/bin/env bash
# Installs a pinned Gatekeeper release and waits until its webhook is ready.
set -euo pipefail

GATEKEEPER_VERSION="${GATEKEEPER_VERSION:-v3.14.2}"

kubectl apply -f "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${GATEKEEPER_VERSION}/deploy/gatekeeper.yaml"
kubectl wait --for=condition=Available deployment --all -n gatekeeper-system --timeout=180s
kubectl get pods -n gatekeeper-system
