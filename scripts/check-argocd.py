#!/usr/bin/env python3
"""Fail if an Argo CD source can move without a commit, or a tenant can leave its namespace.

    scripts/check-argocd.py out/kind out/eks

Reads the Applications scripts/render.py generated (_applications.yaml) and
the ApplicationSets they came from. A chart source must name one exact
version: not a range, not a wildcard, not empty. A Git source must point at
the revision the cluster is pinned to, never at a branch: HEAD, main or a
branch name would let a push change every cluster with no release in
between.

Tenants are checked too: each runs under its own AppProject, made by the
platform (platform/tenant), whose one destination is the tenant's namespace;
what a tenant's directory renders stays in that namespace and holds no
cluster-scoped kind; and a directory cannot take a platform name.
"""
import os
import re
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXACT = re.compile(r"^v?\d+\.\d+\.\d+([-+][\w.]+)?$")
FLOATING = {"", "HEAD", "main", "master", "*", "latest"}


# Kinds the API server keeps outside any namespace. A tenant's directory may
# hold none of them; Argo CD refuses them too (the tenant's project allows no
# cluster-scoped kind), this says so before a cluster does.
CLUSTER_SCOPED = {
    "Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition",
    "StorageClass", "PriorityClass", "PersistentVolume", "RuntimeClass",
    "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration",
    "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding",
    "MutatingAdmissionPolicy", "MutatingAdmissionPolicyBinding",
    "ClusterIssuer", "ClusterSecretStore", "ClusterExternalSecret", "ClusterGenerator",
    "ClusterPolicy", "ValidatingPolicy", "GeneratingPolicy", "MutatingPolicy", "ImageValidatingPolicy",
    "GatewayClass", "NodePool", "EC2NodeClass", "APIService", "CSIDriver",
}
# What a tenant's project must keep out of its namespace.
TENANT_BLOCKED = [("", "ResourceQuota"), ("", "LimitRange"), ("kyverno.io", "PolicyException"),
                  ("policies.kyverno.io", "PolicyException"), ("gateway.networking.k8s.io", "Gateway")]


class Loader(yaml.SafeLoader):
    """SafeLoader that reads YAML's value tag (a bare `=`, which a chart's
    rendered alert rules contain) as the string it is."""


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def load(path):
    with open(path, encoding="utf-8") as f:
        return [d for d in yaml.load_all(f, Loader=Loader) if d]


def check_tenants(dirs, appsets):
    bad = []
    tenants = load(os.path.join(appsets, "tenants.yaml"))[0]
    guardrails = load(os.path.join(appsets, "tenant-guardrails.yaml"))[0]
    project = tenants["spec"]["template"]["spec"]["project"]
    if project != "tenant-{{ .path.basename }}":
        bad.append("tenants.yaml: tenants run under the '%s' project, not each under its own tenant-<name>" % project)
    if guardrails["spec"]["generators"] != tenants["spec"]["generators"]:
        bad.append("tenant-guardrails.yaml and tenants.yaml generate from different directories; a tenant would run without its namespace or project")
    chart = os.path.join(ROOT, "platform", "tenant")
    with open(os.path.join(chart, "values.yaml"), encoding="utf-8") as f:
        reserved = set(yaml.safe_load(f)["reserved"])
    # The chart is what refuses a platform name on a live cluster: shown
    # each reserved name, and a few others it must refuse, it has to fail;
    # shown an ordinary team name, it has to render.
    for n in sorted(reserved) + ["kube-public", "tenant-a", "Team_A", "team-a"]:
        r = subprocess.run(["helm", "template", "t", chart, "--set", "name=%s,cluster=c,repoURL=r" % n],
                           capture_output=True, text=True)
        if n == "team-a" and r.returncode != 0:
            bad.append("platform/tenant does not render for an ordinary team name: %s" % r.stderr.strip()[-300:])
        elif n != "team-a" and r.returncode == 0:
            bad.append("platform/tenant renders for apps/%s; a tenant directory could take that name" % n)
    for d in dirs:
        env = os.path.basename(d)
        apps = load(os.path.join(d, "_applications.yaml"))
        role = {a["metadata"]["name"]: a["metadata"].get("labels", {}).get("platform.heyvaldemar.com/component") for a in apps}
        platform_names = {"platform"} | {n for n, r in role.items() if r not in ("tenant", "tenant-guardrails")}
        platform_namespaces = set()
        for a in apps:
            name = a["metadata"]["name"]
            ns = a["spec"]["destination"]["namespace"]
            docs = load(os.path.join(d, name + ".yaml"))
            if role[name] == "tenant":
                for doc in docs:
                    kind, meta = doc.get("kind"), doc.get("metadata", {})
                    where = "%s/%s: %s/%s" % (env, name, kind, meta.get("name"))
                    if kind in CLUSTER_SCOPED:
                        bad.append("%s is cluster-scoped; a tenant's directory holds only what runs inside its namespace" % where)
                    elif meta.get("namespace", ns) != ns:
                        bad.append("%s is in namespace %s; a tenant writes only to its own (%s)" % (where, meta.get("namespace"), ns))
                if a["spec"]["project"] != "tenant-" + name:
                    bad.append("%s/%s: runs under project %s, not tenant-%s" % (env, name, a["spec"]["project"], name))
                continue
            if role[name] == "tenant-guardrails":
                tenant = ns
                projects = [x for x in docs if x.get("kind") == "AppProject"]
                spaces = [x for x in docs if x.get("kind") == "Namespace"]
                if len(projects) != 1 or projects[0]["metadata"]["name"] != "tenant-" + tenant:
                    bad.append("%s/%s: renders no AppProject tenant-%s" % (env, name, tenant))
                    continue
                spec = projects[0]["spec"]
                dests = [x.get("namespace") for x in spec.get("destinations", [])]
                if dests != [tenant]:
                    bad.append("project tenant-%s allows destinations %s; only its own namespace %s" % (tenant, dests, tenant))
                if spec.get("clusterResourceWhitelist"):
                    bad.append("project tenant-%s may create cluster-scoped kinds: %s" % (tenant, spec["clusterResourceWhitelist"]))
                if any("*" in r for r in spec.get("sourceRepos", [])):
                    bad.append("project tenant-%s takes manifests from a wildcard source %s" % (tenant, spec["sourceRepos"]))
                blocked = {(b.get("group"), b.get("kind")) for b in spec.get("namespaceResourceBlacklist", [])}
                for kind in TENANT_BLOCKED:
                    if kind not in blocked:
                        bad.append("project tenant-%s lets the tenant create %s/%s" % ((tenant,) + kind))
                labels = spaces[0].get("metadata", {}).get("labels", {}) if spaces else {}
                if labels.get("platform.heyvaldemar.com/tenant") != "true" or labels.get("pod-security.kubernetes.io/enforce") != "restricted":
                    bad.append("%s/%s: namespace %s is not labelled as a restricted tenant: %s" % (env, name, tenant, labels))
                continue
            platform_namespaces.add(ns)
            for doc in docs:
                meta = doc.get("metadata", {})
                if doc.get("kind") == "Namespace":
                    platform_namespaces.add(meta.get("name"))
                elif meta.get("namespace"):
                    platform_namespaces.add(meta["namespace"])
        for n in sorted((platform_names | platform_namespaces) - reserved):
            if not n.startswith("kube-"):
                bad.append("%s: platform name %s is not in platform/tenant/values.yaml reserved; apps/%s would take it" % (env, n, n))
        for n in sorted(set(r for r, x in role.items() if x == "tenant") & (platform_names | platform_namespaces | reserved)):
            bad.append("%s: tenant %s has a platform name" % (env, n))
    return bad


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
    bad += check_tenants(dirs, appsets)
    for line in bad:
        print("FAIL  " + line)
    print("%d problem(s)" % len(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
