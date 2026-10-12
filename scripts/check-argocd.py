#!/usr/bin/env python3
"""Fail if an Argo CD source can move without a commit to this repository.

    scripts/check-argocd.py out/kind out/eks

Reads the Applications scripts/render.py generated (_applications.yaml) and
the ApplicationSets they came from. A chart source must name one exact
version: not a range, not a wildcard, not empty. A Git source must point at
the revision the cluster is pinned to, never at a branch: HEAD, main or a
branch name would let a push change every cluster with no release in
between.
"""
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXACT = re.compile(r"^v?\d+\.\d+\.\d+([-+][\w.]+)?$")
FLOATING = {"", "HEAD", "main", "master", "*", "latest"}


def main(dirs):
    bad = []
    for d in dirs:
        with open(os.path.join(d, "_applications.yaml"), encoding="utf-8") as f:
            apps = [a for a in yaml.safe_load_all(f) if a]
        for app in apps:
            name = "%s/%s" % (os.path.basename(d), app["metadata"]["name"])
            for src in app["spec"].get("sources") or [app["spec"]["source"]]:
                rev = str(src.get("targetRevision", ""))
                if src.get("chart"):
                    if not EXACT.match(rev):
                        bad.append("%s: chart %s at '%s' is not one exact version" % (name, src["chart"], rev))
                elif rev in FLOATING or not re.fullmatch(r"[0-9a-f]{40}", rev):
                    bad.append("%s: %s at '%s' is not a commit" % (name, src.get("path") or src.get("ref"), rev))
    # The templates themselves: a Git source must take its revision from the
    # cluster Secret, so no ApplicationSet can hard-code a branch.
    appsets = os.path.join(ROOT, "platform", "appsets")
    for fname in sorted(os.listdir(appsets)):
        with open(os.path.join(appsets, fname), encoding="utf-8") as f:
            for doc in yaml.safe_load_all(f):
                if not doc or doc.get("kind") != "ApplicationSet":
                    continue
                for gen in doc["spec"]["generators"]:
                    for child in gen.get("matrix", {}).get("generators", [gen]):
                        git = child.get("git")
                        if git and git.get("revision") != "{{ .metadata.annotations.platform_revision }}":
                            bad.append("%s: a Git generator reading revision '%s'; it must be {{ .metadata.annotations.platform_revision }}"
                                       % (fname, git.get("revision")))
                spec = doc["spec"]["template"]["spec"]
                for src in spec.get("sources") or [spec["source"]]:
                    if not src.get("chart") and src.get("targetRevision") != "{{ .metadata.annotations.platform_revision }}":
                        bad.append("%s: a Git source with targetRevision '%s'; it must be {{ .metadata.annotations.platform_revision }}"
                                   % (fname, src.get("targetRevision")))
    # Tenants live under their own AppProject, which may create no
    # cluster-scoped kind but its Namespace and may not target a platform
    # namespace; a tenant under the platform project could create anything.
    with open(os.path.join(appsets, "project.yaml"), encoding="utf-8") as f:
        projects = {p["metadata"]["name"]: p for p in yaml.safe_load_all(f) if p}
    with open(os.path.join(appsets, "tenants.yaml"), encoding="utf-8") as f:
        tenants = next(d for d in yaml.safe_load_all(f) if d)
    project = tenants["spec"]["template"]["spec"]["project"]
    proj = projects.get(project, {}).get("spec", {})
    if project != "tenants":
        bad.append("tenants.yaml: tenants run under the '%s' project, not the restricted 'tenants' project" % project)
    elif proj.get("clusterResourceWhitelist") != [{"group": "", "kind": "Namespace"}]:
        bad.append("project tenants may create cluster-scoped kinds beyond its Namespace: %s" % proj.get("clusterResourceWhitelist"))
    else:
        denied = {d["namespace"] for d in proj.get("destinations", []) if str(d.get("namespace", "")).startswith("!")}
        for ns in ("!argocd", "!kube-*", "!kyverno", "!monitoring", "!velero", "!gateway"):
            if ns not in denied:
                bad.append("project tenants does not deny the platform namespace %s" % ns[1:])
        blocked = {(b.get("group"), b.get("kind")) for b in proj.get("namespaceResourceBlacklist", [])}
        for kind in (("kyverno.io", "PolicyException"), ("policies.kyverno.io", "PolicyException")):
            if kind not in blocked:
                bad.append("project tenants lets a tenant create %s/%s, an exemption from admission policy" % kind)
    for line in bad:
        print("FLOATING  " + line)
    print("%d floating source(s)" % len(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
