#!/usr/bin/env bash
# scripts/validate.sh [check ...] - the static checks, on what Argo CD would apply.
#
#   render        scripts/render.py for kind and eks, into out/
#   images        every image reference pinned by digest (scripts/check-images.py)
#   kubeconform   every object valid for Kubernetes 1.37, custom resources
#                 against the CRDs the platform itself installs, strictly
#   kube-linter   the manifests this repository authors (.kube-linter.yaml)
#   pluto         no API removed or deprecated as of 1.37
#   argocd        no chart range and no Git branch as a source (check-argocd.py)
#   policy-tests  every policy has a test that shows it a violation
#   kyverno       the policy tests themselves (kyverno test)
#
# With no arguments every check runs, render first. A named check reuses
# out/ if it is there. Exit status is the number of checks that failed.
#
# Tools: helm, kubectl, kubeconform, kube-linter, pluto, kyverno, python3 with
# PyYAML. scripts/install-tools.sh installs the pinned versions.
set -uo pipefail
cd "$(dirname "$0")/.."

KUBE_VERSION=1.37.0
# yannh/kubernetes-json-schema at a fixed commit: the built-in schemas cannot
# change under a green build.
# K8S_SCHEMAS may point at a local checkout of the same commit instead. (The
# default is assigned on its own line: the template's braces would close a
# ${VAR:-default} expansion early.)
default_schemas='https://raw.githubusercontent.com/yannh/kubernetes-json-schema/817113f21a2643311cbc3e992bb44ffe1c416c54/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json'
K8S_SCHEMAS="${K8S_SCHEMAS:-$default_schemas}"
ENVS=(kind eks)

check_render() {
  for env in "${ENVS[@]}"; do
    rm -rf "out/$env"
    python3 scripts/render.py "$env" "out/$env" >/dev/null || return 1
  done
  echo "rendered: ${ENVS[*]}"
}

check_images() { python3 scripts/check-images.py "${ENVS[@]/#/out/}"; }

check_kubeconform() {
  rm -rf .cache/schemas
  python3 scripts/crd-schemas.py "${ENVS[@]/#/out/}" .cache/schemas || return 1
  mkdir -p .cache/kubeconform
  # CustomResourceDefinitions themselves are skipped: the schema catalog has
  # no schema for them (the type is recursive), and every CRD here comes from
  # an upstream chart that the API server accepts in the daily kind run.
  kubeconform -strict -summary -output text -skip CustomResourceDefinition \
    -kubernetes-version "$KUBE_VERSION" -cache .cache/kubeconform \
    -schema-location "$K8S_SCHEMAS" \
    -schema-location '.cache/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "${ENVS[@]/#/out/}" platform/appsets
}

check_kube_linter() {
  local files=()
  for env in "${ENVS[@]}"; do
    for app in demo object-store platform-config aws-config; do
      [ -f "out/$env/$app.yaml" ] && files+=("out/$env/$app.yaml")
    done
  done
  kube-linter lint --config .kube-linter.yaml "${files[@]}"
}

check_pluto() {
  local rc=0
  for env in "${ENVS[@]}"; do
    pluto detect-files -d "out/$env" --target-versions "k8s=v$KUBE_VERSION" -o wide || rc=1
  done
  return $rc
}

check_argocd() { python3 scripts/check-argocd.py "${ENVS[@]/#/out/}"; }

check_policy_tests() { python3 scripts/check-policy-tests.py; }

check_kyverno() { kyverno test policies/tests; }

all=(render images kubeconform kube-linter pluto argocd policy-tests kyverno)
selected=("$@")
[ ${#selected[@]} -eq 0 ] && selected=("${all[@]}")
if [ ! -d out/kind ] && [[ " ${selected[*]} " != *" render "* ]]; then
  selected=(render "${selected[@]}")
fi

failed=()
for c in "${selected[@]}"; do
  printf '\n== %s\n' "$c"
  if "check_${c//-/_}"; then
    echo "-- $c: ok"
  else
    echo "-- $c: FAILED"
    failed+=("$c")
    # Nothing downstream can be trusted without a render.
    [ "$c" = render ] && break
  fi
done
printf '\n%d of %d checks failed%s\n' "${#failed[@]}" "${#selected[@]}" "${failed:+: ${failed[*]}}"
exit "${#failed[@]}"
