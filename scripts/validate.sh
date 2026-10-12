#!/usr/bin/env bash
# scripts/validate.sh [check ...] - the static checks, on what Argo CD would apply.
#
#   render        scripts/render.py for kind and eks, into out/
#   images        every image reference pinned by digest (scripts/check-images.py)
#   kubeconform   every object valid for Kubernetes 1.37, custom resources
#                 against the CRDs the platform itself installs, strictly
#   kube-linter   the manifests this repository authors (.kube-linter.yaml)
#   pluto         no API removed or deprecated as of 1.37
#   argocd        no chart range and no Git branch as a source; every tenant
#                 confined to its own namespace (check-argocd.py)
#   policy-tests  every policy has a test that shows it a violation
#   kyverno       the policy tests themselves (kyverno test)
#   promtool      every PrometheusRule is valid PromQL, and the SLO alerts
#                 pass their unit tests (tests/slo): a burn pages, a normal
#                 error rate does not
#
# With no arguments every check runs, render first. A named check reuses
# out/ if it is there. Exit status is the number of checks that failed.
#
# Tools: helm, kubectl, kubeconform, kube-linter, pluto, kyverno, promtool, python3 with
# PyYAML. scripts/install-tools.sh installs the pinned versions.
# The check_* functions are called by name from the loop at the bottom.
# shellcheck disable=SC2329
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

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
  # Every Application whose source is a path in this repository (the platform
  # configuration, the object store, every tenant), not the upstream charts.
  local files=() f
  for env in "${ENVS[@]}"; do
    while IFS= read -r f; do files+=("$f"); done < <(python3 - "out/$env" <<'PY'
import os, sys, yaml
d = sys.argv[1]
for a in yaml.safe_load_all(open(os.path.join(d, "_applications.yaml"))):
    if a and any(s.get("path") for s in (a["spec"].get("sources") or [a["spec"]["source"]])):
        print(os.path.join(d, a["metadata"]["name"] + ".yaml"))
PY
)
  done
  echo "linting: ${files[*]}"
  kube-linter lint --config .kube-linter.yaml "${files[@]}"
}

check_pluto() {
  local rc=0
  for env in "${ENVS[@]}"; do
    pluto detect-files -d "out/$env" --target-versions "k8s=v$KUBE_VERSION" -o wide || rc=1
  done
  return "$rc"
}

check_argocd() { python3 scripts/check-argocd.py "${ENVS[@]/#/out/}"; }

check_policy_tests() { python3 scripts/check-policy-tests.py; }

check_kyverno() { kyverno test policies/tests; }

check_promtool() {
  # Every PrometheusRule in the rendered output, as a plain rule file. The
  # demo's also lands where its unit tests expect it.
  rm -rf .cache/rules && mkdir -p .cache/rules
  python3 - "${ENVS[@]/#/out/}" <<'PY' || return 1
import os, sys, yaml
class L(yaml.SafeLoader): pass
L.add_constructor("tag:yaml.org,2002:value", lambda l, n: l.construct_scalar(n))
for d in sys.argv[1:]:
    for f in sorted(os.listdir(d)):
        if not f.endswith(".yaml"):
            continue
        for doc in yaml.load_all(open(os.path.join(d, f)), Loader=L):
            if isinstance(doc, dict) and doc.get("kind") == "PrometheusRule":
                name = "%s-%s.rules.yaml" % (os.path.basename(d), doc["metadata"]["name"])
                yaml.safe_dump(doc["spec"], open(os.path.join(".cache/rules", name), "w"), sort_keys=False)
                if doc["metadata"]["name"] == "demo-slo" and os.path.basename(d) == "kind":
                    yaml.safe_dump(doc["spec"], open("tests/slo/demo-slo.rules.yaml", "w"), sort_keys=False)
PY
  # Rules this repository authors must also pass promtool's lint. The charts'
  # own rules are only required to be valid: kube-prometheus-stack ships a
  # duplicated apiserver recording rule that is upstream's to fix.
  local ours=() upstream=() f
  for f in .cache/rules/*.rules.yaml; do
    case "$f" in *-demo-slo.rules.yaml) ours+=("$f") ;; *) upstream+=("$f") ;; esac
  done
  promtool check rules --lint=none "${upstream[@]}" >/dev/null || { promtool check rules --lint=none "${upstream[@]}"; return 1; }
  promtool check rules --lint-fatal "${ours[@]}" || return 1
  echo "${#upstream[@]} chart rule files valid, ${#ours[@]} of ours valid and lint-clean"
  promtool test rules tests/slo/*.test.yaml
}

all=(render images kubeconform kube-linter pluto argocd policy-tests kyverno promtool)
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
