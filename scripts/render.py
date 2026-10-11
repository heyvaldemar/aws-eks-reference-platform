#!/usr/bin/env python3
"""Render the platform the way Argo CD would, without a cluster.

    scripts/render.py kind out/kind
    scripts/render.py eks  out/eks

Reads platform/clusters/<env>.env, runs every ApplicationSet in
platform/appsets/ against it, and writes what each generated Application
would apply: `helm template` for chart sources, `kubectl kustomize` for paths
in this repository. The output is what CI lints, validates and scans for
unpinned images, so a check that passes here is a check on the manifests the
cluster receives, not on the files that produce them.

Templating covers the subset of Go templates the ApplicationSets use:
{{ .name }}, {{ .metadata.labels.X }}, {{ .metadata.annotations.X }} and
{{- if eq <ref> "literal" }} ... {{- else }} ... {{- end }}. Anything else in
a template stops the render, so the subset cannot drift silently.

Placeholders of the form @NAME@ in the cluster file are filled from the
environment, falling back to SAMPLE below; EKS values that only exist after a
`terraform apply` render with sample values here.

Needs helm and kubectl on PATH. Charts are cached under .cache/charts.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KUBE_VERSION = "1.37.0"
CACHE = os.path.join(ROOT, ".cache", "charts")

SAMPLE = {
    "PLATFORM_REPO_URL": "https://github.com/heyvaldemar/aws-eks-reference-platform",
    "PLATFORM_REVISION": "0000000000000000000000000000000000000000",
    "CLUSTER_NAME": "reference-platform",
    "DOMAIN": "platform.example.com",
    "CLUSTER_ISSUER": "letsencrypt-production",
    "AWS_REGION": "us-east-1",
    "VPC_ID": "vpc-0123456789abcdef0",
    "VELERO_BUCKET": "reference-platform-velero-123456789012",
    "KARPENTER_NODE_ROLE": "reference-platform-karpenter-node",
    "KARPENTER_INTERRUPTION_QUEUE": "reference-platform-karpenter",
}


def read_cluster(env):
    labels, annotations = {}, {}
    path = os.path.join(ROOT, "platform", "clusters", env + ".env")
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            m = re.fullmatch(r"@([A-Z_]+)@", value)
            if m:
                value = os.environ.get(m.group(1)) or SAMPLE[m.group(1)]
            kind, _, name = key.partition(".")
            if kind == "label":
                labels[name] = value
            elif kind == "annotation":
                annotations[name] = value
            else:
                sys.exit("%s:%d: expected label.<name>= or annotation.<name>=" % (path, n))
    return {"name": "in-cluster", "metadata": {"labels": labels, "annotations": annotations}}


TOKEN = re.compile(r"\{\{(-?)\s*(.*?)\s*(-?)\}\}", re.S)


def lookup(ctx, ref):
    if not ref.startswith("."):
        raise ValueError("unsupported template expression: %s" % ref)
    value = ctx
    for part in ref[1:].split("."):
        if not isinstance(value, dict) or part not in value:
            # goTemplateOptions: missingkey=error, as in the ApplicationSets.
            raise KeyError("template refers to %s, which the cluster does not define" % ref)
        value = value[part]
    return value


def gotemplate(text, ctx):
    """Render the Go-template subset described in the module docstring."""
    out, stack = [], []  # stack of (active_before, branch_taken)
    pos = 0
    active = True
    for m in TOKEN.finditer(text):
        literal = text[pos:m.start()]
        if m.group(1):  # {{- trims whitespace before the action
            literal = literal.rstrip()
        if active:
            out.append(literal)
        pos = m.end()
        expr = m.group(2)
        if m.group(3):  # -}} trims whitespace after it
            rest = text[pos:]
            pos += len(rest) - len(rest.lstrip())
        cond = re.fullmatch(r'if eq (\.[\w.]+) "([^"]*)"', expr)
        if cond:
            taken = str(lookup(ctx, cond.group(1))) == cond.group(2)
            stack.append((active, taken))
            active = active and taken
        elif expr == "else":
            before, taken = stack[-1]
            active = before and not taken
        elif expr == "end":
            active = stack.pop()[0]
        elif re.fullmatch(r"\.[\w.]+", expr):
            if active:
                out.append(str(lookup(ctx, expr)))
        else:
            raise ValueError("unsupported template expression: {{ %s }}" % expr)
    if stack:
        raise ValueError("an {{ if }} is not closed")
    out.append(text[pos:])
    return "".join(out)


def render_tree(node, ctx):
    if isinstance(node, str):
        return gotemplate(node, ctx)
    if isinstance(node, list):
        return [render_tree(x, ctx) for x in node]
    if isinstance(node, dict):
        return {k: render_tree(v, ctx) for k, v in node.items()}
    return node


def selected(appset, cluster):
    for gen in appset["spec"]["generators"]:
        sel = gen.get("clusters", {}).get("selector", {}).get("matchLabels", {})
        if all(cluster["metadata"]["labels"].get(k) == v for k, v in sel.items()):
            return True
    return False


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit("%s\n%s%s" % (" ".join(cmd), r.stdout[-3000:], r.stderr[-3000:]))
    return r.stdout


def chart_dir(src):
    repo, chart, version = src["repoURL"], src["chart"], str(src["targetRevision"])
    dest = os.path.join(CACHE, chart, version)
    if not os.path.isdir(os.path.join(dest, chart)):
        os.makedirs(dest, exist_ok=True)
        if repo.startswith("http"):
            run(["helm", "pull", chart, "--repo", repo, "--version", version, "--untar", "--untardir", dest])
        else:
            run(["helm", "pull", "oci://%s/%s" % (repo, chart), "--version", version, "--untar", "--untardir", dest])
    return os.path.join(dest, chart)


def render_helm(app, src, refs, tmp):
    helm = src.get("helm", {})
    cmd = ["helm", "template", helm.get("releaseName", app["metadata"]["name"]), chart_dir(src),
           "--namespace", app["spec"]["destination"]["namespace"], "--kube-version", KUBE_VERSION,
           "--include-crds"]
    for vf in helm.get("valueFiles", []):
        # RENDER_CHART_DEFAULT_IMAGES=1 leaves the image pins out, to see
        # which images a chart version would pick by itself.
        if os.environ.get("RENDER_CHART_DEFAULT_IMAGES") == "1" and vf.endswith("/images.yaml"):
            continue
        ref, _, rel = vf.partition("/")
        path = os.path.join(refs[ref], rel) if ref.startswith("$") else vf
        if os.path.exists(path):
            cmd += ["-f", path]
        elif not helm.get("ignoreMissingValueFiles"):
            sys.exit("%s: value file %s does not exist" % (app["metadata"]["name"], vf))
    for key in ("values", "valuesObject"):
        if helm.get(key):
            path = os.path.join(tmp, "%s-%s.yaml" % (app["metadata"]["name"], key))
            with open(path, "w", encoding="utf-8") as f:
                f.write(helm[key] if key == "values" else yaml.safe_dump(helm[key]))
            cmd += ["-f", path]
    return run(cmd)


def render_kustomize(app, src, tmp):
    path = os.path.join(ROOT, src["path"])
    patches = src.get("kustomize", {}).get("patches")
    if not patches:
        return run(["kubectl", "kustomize", path])
    # kustomize refuses absolute resource paths, and on macOS the temporary
    # directory sits behind a symlink that breaks relative ones: the wrapper
    # lives inside the repository instead.
    wrap = os.path.join(ROOT, ".cache", "kustomize", app["metadata"]["name"])
    shutil.rmtree(wrap, ignore_errors=True)
    os.makedirs(wrap)
    with open(os.path.join(wrap, "kustomization.yaml"), "w", encoding="utf-8") as f:
        yaml.safe_dump({"resources": [os.path.relpath(path, wrap)], "patches": patches}, f)
    return run(["kubectl", "kustomize", "--load-restrictor", "LoadRestrictionsNone", wrap])


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    env, out = sys.argv[1], sys.argv[2]
    cluster = read_cluster(env)
    os.makedirs(out, exist_ok=True)
    apps = []
    appset_dir = os.path.join(ROOT, "platform", "appsets")
    for name in sorted(os.listdir(appset_dir)):
        with open(os.path.join(appset_dir, name), encoding="utf-8") as f:
            for doc in yaml.safe_load_all(f):
                if doc and doc.get("kind") == "ApplicationSet" and selected(doc, cluster):
                    app = render_tree(doc["spec"]["template"], cluster)
                    app = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", **app}
                    app["metadata"]["namespace"] = "argocd"
                    apps.append(app)
    with open(os.path.join(out, "_applications.yaml"), "w", encoding="utf-8") as f:
        yaml.safe_dump_all(apps, f, sort_keys=False)
    with tempfile.TemporaryDirectory() as tmp:
        for app in apps:
            name = app["metadata"]["name"]
            sources = app["spec"].get("sources") or [app["spec"]["source"]]
            refs = {"$" + s["ref"]: ROOT for s in sources if s.get("ref")}
            docs = []
            for src in sources:
                if src.get("ref"):
                    continue
                if src.get("chart"):
                    docs.append(render_helm(app, src, refs, tmp))
                else:
                    docs.append(render_kustomize(app, src, tmp))
            with open(os.path.join(out, name + ".yaml"), "w", encoding="utf-8") as f:
                f.write("\n---\n".join(docs))
            print("rendered %-30s %s" % (name, json.dumps([s.get("chart") or s.get("path") for s in sources if not s.get("ref")])))


if __name__ == "__main__":
    main()
