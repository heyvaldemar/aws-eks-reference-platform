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
#   PLATFORM_REPO_TOKEN   only for a private repository over HTTPS: a read
#                         token (in CI, the job's own GITHUB_TOKEN). It reaches
#                         the cluster through stdin, never argv.
#   PLATFORM_REPO_SSH_KEY_FILE  only for a private repository over SSH: a
#                         read-only deploy key; PLATFORM_REPO_URL is then the
#                         git@github.com:... form.
#   SKIP_PUSH_CHECK=1     skip the "is HEAD on the remote" check (CI checks out
#                         a detached commit it knows is pushed)
#   any @NAME@ the cluster file uses (eks: filled by the Makefile from
#   terraform output)
#
# Re-running it is safe, and is how a cluster moves to another revision:
# Argo CD is not reinstalled, the cluster Secret and root Application are
# re-applied with the new PLATFORM_REVISION.
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

# --- 0. the API is whole --------------------------------------------------------
# Argo CD reads the cluster's whole API when it starts, aggregated APIs
# included. On a cluster minutes old, metrics.k8s.io can still be answering
# 503, and Argo CD's controller then fails its first cache sync with "the
# server is currently unable to handle the request" and leaves the root
# Application Unknown. The first EKS validation runs found exactly that.
say "every APIService Available"
if ! kubectl wait --for=condition=Available apiservice --all --timeout=600s >/dev/null; then
  echo "APIServices still not Available after 10 minutes:" >&2
  kubectl get apiservices -o jsonpath='{range .items[?(@.status.conditions[0].status!="True")]}{.metadata.name}{"  "}{.status.conditions[0].reason}{": "}{.status.conditions[0].message}{"\n"}{end}' >&2
  exit 1
fi

# Available is not enough: Argo CD reads the merged OpenAPI document as
# protobuf, and one aggregated API built with Go 1.27 (metrics-server
# v0.9.0-eksbuild.12) makes the API server answer that with 503 while JSON
# still works. Ask the way Argo CD asks, and say so if it fails.
say "the cluster's OpenAPI, read as Argo CD reads it"
# kubectl get --raw cannot choose the format, so the request goes through
# kubectl proxy: on a unix socket in a private directory, never a TCP port,
# because the proxy is the caller's credentials for anyone who can reach it.
proxy_dir="$(mktemp -d)"
kubectl proxy --unix-socket="$proxy_dir/api.sock" >/dev/null 2>&1 &
proxy=$!
trap 'kill "$proxy" 2>/dev/null || true; rm -rf "$proxy_dir"' EXIT
code=000
for _ in $(seq 1 30); do
  kill -0 "$proxy" 2>/dev/null || { echo "kubectl proxy exited; cannot ask for the OpenAPI document" >&2; exit 1; }
  if [ -S "$proxy_dir/api.sock" ]; then
    code="$(curl -s --max-time 30 --unix-socket "$proxy_dir/api.sock" -o /dev/null -w '%{http_code}' \
      -H 'Accept: application/com.github.proto-openapi.spec.v2@v1.0+protobuf' http://localhost/openapi/v2 || true)"
    [ "$code" = 200 ] && break
  fi
  sleep 10
done
kill "$proxy" 2>/dev/null || true
rm -rf "$proxy_dir"
trap - EXIT
if [ "$code" != 200 ]; then
  echo "/openapi/v2 as protobuf answers HTTP $code; Argo CD cannot build its cluster cache on this cluster." >&2
  echo "An aggregated API built with Go 1.27 does this (https://github.com/kubernetes-sigs/metrics-server/issues/1868):" >&2
  kubectl get apiservices -o jsonpath='{range .items[?(@.spec.service)]}  {.metadata.name}{"\n"}{end}' >&2
  exit 1
fi

# --- 1. Argo CD ---------------------------------------------------------------
ARGOCD_CHART_VERSION="$(sed -n 's/^ *targetRevision: \([0-9][0-9.]*\)$/\1/p' "$ROOT/platform/appsets/argo-cd.yaml" | head -1)"
[ -n "$ARGOCD_CHART_VERSION" ] || { echo "could not read the argo-cd chart version" >&2; exit 1; }

say "namespaces Argo CD and the bootstrap secrets need"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace argocd --overwrite \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest >/dev/null

# Once installed, Argo CD manages its own release through
# platform/appsets/argo-cd.yaml; a second Helm install would fight it for the
# same fields. A re-run only moves the cluster to a new revision (steps 3-4).
if kubectl -n argocd get deployment argocd-server >/dev/null 2>&1; then
  say "Argo CD is installed and manages itself; not reinstalling"
  # Except for its memory. Argo CD applies its own new release only by
  # syncing it, alongside every other Application the new revision moves,
  # and a controller that runs out of memory doing that never gets there:
  # v1.2.0's was OOMKilled nine times at 1Gi and nine times at 2Gi (kind e2e
  # runs 40550141772, 40563291328) and never applied its own update. So the
  # running controller gets this revision's memory limit and GOMEMLIMIT
  # first, in one patch. When it already has them, nothing restarts.
  values="$ROOT/platform/values/argo-cd/common.yaml"
  limit="$(sed -n '/^controller:/,/^[a-z]/s/^ *limits: {memory: \([0-9A-Za-z]*\)}$/\1/p' "$values")"
  gomemlimit="$(sed -n '/^controller:/,/^[a-z]/s/^ *env: \[{name: GOMEMLIMIT, value: \([0-9A-Za-z]*\)}\]$/\1/p' "$values")"
  [ -n "$limit" ] && [ -n "$gomemlimit" ] ||
    { echo "could not read the application controller's memory limit and GOMEMLIMIT from $values" >&2; exit 1; }
  say "application controller: memory limit $limit, GOMEMLIMIT $gomemlimit, before the new revision"
  kubectl -n argocd patch statefulset argocd-application-controller --type strategic -p "$(printf \
    '{"spec":{"template":{"spec":{"containers":[{"name":"application-controller","resources":{"limits":{"memory":"%s"}},"env":[{"name":"GOMEMLIMIT","value":"%s"}]}]}}}}' \
    "$limit" "$gomemlimit")"
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m
else
  say "Argo CD chart $ARGOCD_CHART_VERSION"
  values=(-f "$ROOT/platform/values/argo-cd/images.yaml" -f "$ROOT/platform/values/argo-cd/common.yaml")
  [ -f "$ROOT/platform/values/argo-cd/$ENV.yaml" ] && values+=(-f "$ROOT/platform/values/argo-cd/$ENV.yaml")
  helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd "${values[@]}" --wait --timeout 10m
fi

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
    # A finite read: `tr </dev/urandom | head` dies of SIGPIPE under pipefail.
    access="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Z0-9' | cut -c1-20)"
    secret="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-40)"
    [ "${#access}" -eq 20 ] && [ "${#secret}" -eq 40 ] || { echo "could not generate S3 keys" >&2; exit 1; }
    printf '{"identities":[{"name":"velero","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' "$access" "$secret" |
      kubectl -n object-store create secret generic object-store-s3 --from-file=s3.json=/dev/stdin
    printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$access" "$secret" |
      kubectl -n velero create secret generic velero-s3 --from-file=cloud=/dev/stdin
    unset access secret
  else
    echo "already present"
  fi
fi

if [ -n "${PLATFORM_REPO_SSH_KEY_FILE:-}" ]; then
  say "read access to $PLATFORM_REPO_URL (deploy key)"
  kubectl -n argocd create secret generic platform-repo \
    --from-literal=type=git --from-literal=url="$PLATFORM_REPO_URL" \
    --from-file=sshPrivateKey="$PLATFORM_REPO_SSH_KEY_FILE" --dry-run=client -o yaml |
    kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml |
    kubectl apply -f - >/dev/null
elif [ -n "${PLATFORM_REPO_TOKEN:-}" ]; then
  say "read access to $PLATFORM_REPO_URL"
  # printf, not a here-string: <<< appends a newline, the newline became part
  # of the stored password, and Argo CD sent it as-is when it listed the
  # remote's refs. A commit SHA needs no listing, so only a tag or a branch
  # failed, with "Invalid username or token" (v1.0.0; found by the upgrade
  # job, the first one to read a tag). printf is a builtin: still never argv.
  printf '%s' "$PLATFORM_REPO_TOKEN" |
    kubectl -n argocd create secret generic platform-repo \
    --from-literal=type=git --from-literal=url="$PLATFORM_REPO_URL" --from-literal=username=x-access-token \
    --from-file=password=/dev/stdin --dry-run=client -o yaml |
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
# Syncs run as the service account their project names, and a project that
# names none cannot sync. The projects go in first, so the root Application's
# first sync has its account; the root Application keeps them in Git's state.
kubectl apply -f "$ROOT/platform/appsets/project.yaml" >/dev/null
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
