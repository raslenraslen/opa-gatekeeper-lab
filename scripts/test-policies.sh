#!/usr/bin/env bash
# Sends each manifest in tests/ through the admission webhook with
# --dry-run=server (nothing is created) and checks that Gatekeeper rejects it
# with the expected message. Exits 1 if any manifest is accepted.
set -uo pipefail
cd "$(dirname "$0")/.."

declare -A expected=(
  [tests/no-nodeport.yaml]="Usage of Service type NodePort is forbidden"
  [tests/no-latest-tag.yaml]="uses the ':latest' tag, which is forbidden"
  [tests/no-privileged.yaml]="cannot run in privileged mode"
  [tests/require-limits.yaml]="must have CPU limits"
  [tests/run-as-non-root.yaml]="must set runAsNonRoot to true"
)

failed=0
for manifest in "${!expected[@]}"; do
  result="FAIL"
  # Retry: a new constraint reaches the webhook pods a few seconds after it is created.
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if output=$(kubectl apply --dry-run=server -f "$manifest" 2>&1); then
      sleep 3
      continue
    fi
    if grep -qF "${expected[$manifest]}" <<<"$output"; then
      result="PASS"
    fi
    break
  done
  echo "${result}  ${manifest}"
  [[ "$result" == "PASS" ]] || { failed=1; echo "      ${output}"; }
done

exit "$failed"
