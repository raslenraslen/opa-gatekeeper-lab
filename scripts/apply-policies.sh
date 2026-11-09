#!/usr/bin/env bash
# Applies every policy in policies/: templates first, then constraints.
set -euo pipefail
cd "$(dirname "$0")/.."

# The require-limits and run-as-non-root constraints target this namespace.
kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f -

for policy in policies/*/; do
  kubectl apply -f "${policy}template.yaml"
done

# A constraint can only be created once Gatekeeper has generated its CRD.
kubectl wait --for=jsonpath='{.status.created}'=true constrainttemplates --all --timeout=60s

for policy in policies/*/; do
  kubectl apply -f "${policy}constraint.yaml"
done

kubectl get constraints
