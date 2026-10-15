#!/usr/bin/env bash
# kind-prefetch.sh <cluster-name> <checkout>... - put the Docker Official
# Images that a checkout's platform pulls from ECR Public into every kind
# node, before anything asks for them.
#
# ECR Public throttles anonymous pulls by source address, and GitHub's
# runners share theirs. On 15 October the upgrade job waited out helm's ten
# minutes twice on argocd-redis behind "429 Too Many Requests" from
# public.ecr.aws, while the fresh install on another runner passed. The same
# image, by the same digest, is on mirror.gcr.io, Google's cache of Docker
# Hub. Each node pulls it from there by the digest the platform pins and
# names it as the platform does, so the kubelet finds it present and never
# asks ECR. The digest is the one reviewed, whichever host served the bytes.
#
# Only public.ecr.aws/docker/library images have a counterpart there; any
# other image is left to the kubelet. A prefetch that fails is a warning, not
# an error: the kubelet can still pull it the usual way.
set -euo pipefail
CLUSTER="${1:?usage: kind-prefetch.sh <cluster-name> <checkout>...}"
shift
[ "$#" -gt 0 ] || { echo "usage: kind-prefetch.sh <cluster-name> <checkout>..." >&2; exit 2; }

# "name digest" for each Docker Official Image a checkout's values pin:
#   repository: public.ecr.aws/docker/library/redis
#   tag: 8.6.4-alpine@sha256:...
images="$(for dir in "$@"; do
  awk '/repository: *public\.ecr\.aws\/docker\/library\// { sub(/.*\/docker\/library\//, ""); name = $0; next }
       name != "" && /tag: *[^ ]*@sha256:/ { sub(/.*@/, ""); print name, $0 }
       { name = "" }' "$dir"/platform/values/*/images.yaml
done | sort -u)"
[ -n "$images" ] || { echo "kind-prefetch: no Docker Official Images from ECR Public to fetch"; exit 0; }

for node in $(kind get nodes --name "$CLUSTER"); do
  case "$(docker exec "$node" uname -m)" in
    x86_64) platform=linux/amd64 ;;
    aarch64 | arm64) platform=linux/arm64 ;;
    *) platform="linux/$(docker exec "$node" uname -m)" ;;
  esac
  while read -r name digest; do
    from="mirror.gcr.io/library/$name@$digest"
    as="public.ecr.aws/docker/library/$name@$digest"
    fetched=0
    for wait in 0 10 30; do
      sleep "$wait"
      if docker exec "$node" ctr -n k8s.io images pull --platform "$platform" "$from" >/dev/null; then
        fetched=1
        break
      fi
    done
    if [ "$fetched" = 1 ] && docker exec "$node" ctr -n k8s.io images tag --force "$from" "$as" >/dev/null; then
      echo "kind-prefetch: $node has $as (from mirror.gcr.io)"
    else
      echo "::warning::kind-prefetch: $node could not fetch $from; the kubelet will pull $as itself"
    fi
  done <<<"$images"
done
