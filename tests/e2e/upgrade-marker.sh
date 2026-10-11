#!/usr/bin/env bash
# upgrade-marker.sh write|check - a marker the upgrade drill writes into the
# demo backend's volume on the previous release and reads back after the
# cluster has moved to the commit under test. The hash podinfo returns is
# kept in the cluster (a ConfigMap) so the two steps share nothing else.
set -euo pipefail
DOMAIN="${DOMAIN:-platform.test}"
HOST="demo.$DOMAIN" PORT=29443
work="$(mktemp -d)"
svc="$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=platform -o jsonpath='{.items[0].metadata.name}')"
kubectl -n envoy-gateway-system port-forward "svc/$svc" "$PORT:443" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null; wait $pf 2>/dev/null || true; rm -rf "$work"' EXIT
kubectl -n cert-manager get secret platform-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$work/ca.crt"
for _ in $(seq 1 30); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 1; done
gw() { curl -sS --max-time 10 --resolve "$HOST:$PORT:127.0.0.1" --cacert "$work/ca.crt" "$@"; }

case "${1:-}" in
  write)
    marker="upgrade-marker-$(date +%s)-$RANDOM"
    hash="$(gw -X POST --data "$marker" "https://$HOST:$PORT/store" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])')"
    kubectl -n default create configmap upgrade-marker --from-literal=hash="$hash" --from-literal=marker="$marker" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "wrote $marker ($hash) on the previous release"
    ;;
  check)
    hash="$(kubectl -n default get configmap upgrade-marker -o jsonpath='{.data.hash}')"
    want="$(kubectl -n default get configmap upgrade-marker -o jsonpath='{.data.marker}')"
    got="$(gw "https://$HOST:$PORT/store/$hash")"
    if [ "$got" = "$want" ]; then
      echo "the marker written on the previous release is still served after the upgrade"
    else
      echo "after the upgrade /store/$hash returned '${got:0:200}', expected '$want'" >&2
      exit 1
    fi
    ;;
  *) echo "usage: $0 write|check" >&2; exit 2 ;;
esac
