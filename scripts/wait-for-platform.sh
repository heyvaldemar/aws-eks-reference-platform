#!/usr/bin/env bash
# wait-for-platform.sh [timeout-seconds] - wait until every Application the
# platform generates is Synced and Healthy, and say which ones are not.
#
# The expected set is what scripts/render.py would generate for the cluster
# (its _applications.yaml), plus the root Application; an Application that
# never appears counts as not ready, so a broken ApplicationSet cannot pass
# by generating nothing.
#
# It stops early when the root Application has not read the repository for
# ROOT_GRACE seconds (sync status Unknown: Argo CD could not fetch or render
# it), since nothing below it can appear. Either way it ends by printing
# each pending Application's conditions, which is where Argo CD says why.
set -euo pipefail
TIMEOUT="${1:-1200}"
ROOT_GRACE="${ROOT_GRACE:-600}"
EXPECTED="${EXPECTED_APPS:-}"
start=$(date +%s)
deadline=$(( start + TIMEOUT ))

conditions() {   # conditions <app>...: what Argo CD says about each
  local app
  for app in "$@"; do
    kubectl -n argocd get applications.argoproj.io "$app" \
      -o jsonpath='{range .status.conditions[*]}{"  "}{.type}{": "}{.message}{"\n"}{end}' 2>/dev/null \
      | sed "s/^/  $app /" >&2 || true
  done
}
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
  if grep -q '^platform Unknown ' <<<"$status" && [ "$(( $(date +%s) - start ))" -ge "$ROOT_GRACE" ]; then
    echo "the root Application has not read the repository in ${ROOT_GRACE}s; nothing below it can appear:" >&2
    conditions platform
    exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out after ${TIMEOUT}s; not ready:" >&2
    printf '%s\n' "$pending" >&2
    echo "what Argo CD says about them:" >&2
    # shellcheck disable=SC2046  # one name per word
    conditions $(awk 'NF >= 3 && $2 != "(not" {print $1}' <<<"$pending")
    exit 1
  fi
  printf '%s waiting on:\n%s\n' "$(date -u +%H:%M:%S)" "$pending"
  sleep 20
done
