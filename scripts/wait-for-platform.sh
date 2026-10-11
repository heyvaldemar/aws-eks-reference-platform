#!/usr/bin/env bash
# wait-for-platform.sh [timeout-seconds] - wait until every Application the
# platform generates is Synced and Healthy, and say which ones are not.
#
# The expected set is what scripts/render.py would generate for the cluster
# (its _applications.yaml), plus the root Application; an Application that
# never appears counts as not ready, so a broken ApplicationSet cannot pass
# by generating nothing.
set -euo pipefail
TIMEOUT="${1:-1200}"
EXPECTED="${EXPECTED_APPS:-}"
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  status="$(kubectl -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null || true)"
  pending=""
  for app in platform $EXPECTED; do
    line="$(grep -E "^$app " <<<"$status" || true)"
    [ "$line" = "$app Synced Healthy" ] || pending+="  ${line:-$app (not generated yet)}"$'\n'
  done
  if [ -z "$EXPECTED" ]; then
    pending+="$(grep -vE ' Synced Healthy$' <<<"$status" | sed 's/^/  /' || true)"
  fi
  if [ -z "${pending//[[:space:]]/}" ]; then
    echo "all Applications Synced and Healthy:"
    while IFS= read -r l; do echo "  $l"; done <<<"$status"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out after ${TIMEOUT}s; not ready:" >&2
    printf '%s\n' "$pending" >&2
    exit 1
  fi
  printf '%s waiting on:\n%s\n' "$(date -u +%H:%M:%S)" "$pending"
  sleep 20
done
