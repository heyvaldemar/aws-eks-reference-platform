#!/usr/bin/env bash
# bootstrap.sh <kind|eks> - install Argo CD once and hand the cluster to it.
#
# Everything after this script is Argo CD reading this repository at one
# commit. The script does four things a Git repository cannot do for itself:
#
#   1. installs Argo CD with the same chart version and values that its own
#      ApplicationSet (platform/appsets/argo-cd.yaml) will manage afterwards;
#   2. on kind, generates the S3 keys SeaweedFS and Velero share, so that no
#      key exists anywhere but in the cluster;
#   3. registers the cluster with Argo CD as a Secret whose labels and
#      annotations come from platform/clusters/<env>.env;
#   4. creates the root Application, which applies platform/appsets/.
#
# Environment:
#   PLATFORM_REPO_URL     the repository Argo CD reads (default: origin)
#   PLATFORM_REVISION     the commit it reads (default: HEAD, which must be pushed)
#   PLATFORM_REPO_TOKEN   only for a private repository: a read token. It is
#                         written into the cluster through stdin, never argv.
#   SKIP_PUSH_CHECK=1     skip the "is HEAD on the remote" check (CI checks out
#                         a detached commit it knows is pushed)
#   any @NAME@ the cluster file uses (eks: filled by the Makefile from
#   terraform output)
#
# Re-running it is safe: every step is an upgrade or an apply.
set -euo pipefail

ENV="${1:?usage: bootstrap.sh kind|eks}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_FILE="$ROOT/platform/clusters/$ENV.env"
[ -f "$CLUSTER_FILE" ] || { echo "no cluster file $CLUSTER_FILE" >&2; exit 1; }

for tool in kubectl helm git; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

if [ -z "${PLATFORM_REPO_URL:-}" ]; then
  PLATFORM_REPO_URL="$(git -C "$ROOT" remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')"
fi
PLATFORM_REVISION="${PLATFORM_REVISION:-$(git -C "$ROOT" rev-parse HEAD)}"
export PLATFORM_REPO_URL PLATFORM_REVISION

# Argo CD reads the remote, not this working tree. A commit that only exists
# here would leave every Application in "revision not found" with nothing on
# screen to say why.
if [ "${SKIP_PUSH_CHECK:-}" != 1 ]; then
  git -C "$ROOT" fetch --quiet origin || true
  if [ -z "$(git -C "$ROOT" branch -r --contains "$PLATFORM_REVISION" 2>/dev/null)" ]; then
    echo "commit $PLATFORM_REVISION is not on the remote yet. Argo CD reads the remote:" >&2
    echo "push it, or set PLATFORM_REVISION to a commit or tag that is there." >&2
    exit 1
  fi
fi

say() { printf '\n== %s\n' "$*"; }

# --- 1. Argo CD ---------------------------------------------------------------
ARGOCD_CHART_VERSION="$(sed -n 's/^ *targetRevision: \([0-9][0-9.]*\)$/\1/p' "$ROOT/platform/appsets/argo-cd.yaml" | head -1)"
[ -n "$ARGOCD_CHART_VERSION" ] || { echo "could not read the argo-cd chart version" >&2; exit 1; }

say "namespaces Argo CD and the bootstrap secrets need"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace argocd --overwrite \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest >/dev/null

say "Argo CD chart $ARGOCD_CHART_VERSION"
values=(-f "$ROOT/platform/values/argo-cd/images.yaml" -f "$ROOT/platform/values/argo-cd/common.yaml")
[ -f "$ROOT/platform/values/argo-cd/$ENV.yaml" ] && values+=(-f "$ROOT/platform/values/argo-cd/$ENV.yaml")
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd "${values[@]}" --wait --timeout 10m

# --- 2. secrets that must never be in Git --------------------------------------
if [ "$ENV" = kind ]; then
  say "S3 keys for SeaweedFS and Velero (generated here, kept only in the cluster)"
  kubectl create namespace object-store --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace object-store --overwrite \
    pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest >/dev/null
  kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
  # The node agent reads pod volumes from the host; see platform/appsets/velero.yaml.
  kubectl label namespace velero --overwrite \
    pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=restricted >/dev/null
  if ! kubectl -n object-store get secret object-store-s3 >/dev/null 2>&1; then
    access="$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom | head -c 20)"
    secret="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"
    printf '{"identities":[{"name":"velero","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' "$access" "$secret" |
      kubectl -n object-store create secret generic object-store-s3 --from-file=s3.json=/dev/stdin
    printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$access" "$secret" |
      kubectl -n velero create secret generic velero-s3 --from-file=cloud=/dev/stdin
    unset access secret
  else
    echo "already present"
  fi
fi

if [ -n "${PLATFORM_REPO_TOKEN:-}" ]; then
  say "read access to $PLATFORM_REPO_URL"
  kubectl -n argocd create secret generic platform-repo \
    --from-literal=type=git --from-literal=url="$PLATFORM_REPO_URL" --from-literal=username=x-access-token \
    --from-file=password=/dev/stdin --dry-run=client -o yaml <<<"$PLATFORM_REPO_TOKEN" |
    kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml |
    kubectl apply -f - >/dev/null
fi

# --- 3. the cluster, as Argo CD sees it ----------------------------------------
say "cluster Secret from $(basename "$CLUSTER_FILE")"
labels=() annotations=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  key="${line%%=*}" value="${line#*=}"
  if [[ "$value" =~ ^@([A-Z_]+)@$ ]]; then
    var="${BASH_REMATCH[1]}"
    value="${!var:-}"
    [ -n "$value" ] || { echo "$CLUSTER_FILE needs $var, which is not set" >&2; exit 1; }
  fi
  case "$key" in
    label.*) labels+=("${key#label.}=$value") ;;
    annotation.*) annotations+=("${key#annotation.}=$value") ;;
  esac
done <"$CLUSTER_FILE"

kubectl -n argocd create secret generic in-cluster \
  --from-literal=name=in-cluster --from-literal=server=https://kubernetes.default.svc \
  --from-literal=config='{"tlsClientConfig":{"insecure":false}}' \
  --dry-run=client -o yaml |
  kubectl label --local -f - argocd.argoproj.io/secret-type=cluster "${labels[@]}" -o yaml |
  kubectl annotate --local -f - "${annotations[@]}" -o yaml |
  kubectl apply -f - >/dev/null
echo "labels:      ${labels[*]}"
echo "revision:    $PLATFORM_REVISION"

# --- 4. the root Application ---------------------------------------------------
say "root Application: $PLATFORM_REPO_URL platform/appsets @ $PLATFORM_REVISION"
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $PLATFORM_REPO_URL
    targetRevision: $PLATFORM_REVISION
    path: platform/appsets
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
EOF

say "handed over; watch it with: kubectl -n argocd get applications -w"
