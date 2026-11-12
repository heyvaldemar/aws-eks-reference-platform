#!/usr/bin/env python3
"""Fail if one rendered webhook that fails closed stands in front of a whole kind.

    scripts/check-webhooks.py out/kind out/eks
    scripts/check-webhooks.py selftest

A webhook with failurePolicy Fail turns its own outage into an outage of
everything it matches. The AWS Load Balancer Controller's Service webhook
matched every Service in the cluster: when its certificate went stale in the
EKS run of 11 November 2026 started by hand (run 43119033426), no Service could
be created, and cert-manager, External Secrets and Kyverno, whose own webhooks
answer on Services, went down with it.

So a rendered Mutating- or ValidatingWebhookConfiguration may fail closed on
the kinds every controller needs (core pods, services, secrets, configmaps,
namespaces and service accounts; apps workloads; or a wildcard) only for
objects that opt in: its namespaceSelector or objectSelector must hold a
matchLabels entry or an In or Exists expression. NotIn and DoesNotExist alone
exclude a few and match the rest. Webhooks the platform's controllers make at
run time (Kyverno's) are not rendered and not read here; Kyverno's admission
is the API server's own (ADR 5).
"""
import glob
import os
import sys

import yaml

BROAD = {
    "": {"pods", "services", "secrets", "configmaps", "namespaces", "serviceaccounts", "*"},
    "apps": {"deployments", "statefulsets", "daemonsets", "replicasets", "*"},
}
KINDS = {"MutatingWebhookConfiguration", "ValidatingWebhookConfiguration"}


class Loader(yaml.SafeLoader):
    """SafeLoader that reads YAML's value tag (a bare `=`) as the string it is."""


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def opts_in(selector):
    selector = selector or {}
    if selector.get("matchLabels"):
        return True
    return any(e.get("operator") in ("In", "Exists") for e in selector.get("matchExpressions") or [])


def broad(rule):
    """The kinds this rule matches out of BROAD, as group/resource."""
    if not set(rule.get("operations") or []) & {"CREATE", "UPDATE", "*"}:
        return []
    out = []
    for group in rule.get("apiGroups") or []:
        for g in (BROAD if group == "*" else [group]):
            for r in rule.get("resources") or []:
                if r.split("/")[0] in BROAD.get(g, ()) or (r == "*" and g in BROAD):
                    out.append("%s/%s" % (g or "core", r))
    return out


def check(objs, where, out=print):
    bad = 0
    for o in objs:
        if o.get("kind") not in KINDS:
            continue
        for w in o.get("webhooks") or []:
            if w.get("failurePolicy", "Fail") != "Fail":
                continue
            if opts_in(w.get("namespaceSelector")) or opts_in(w.get("objectSelector")):
                continue
            hit = sorted({k for rule in w.get("rules") or [] for k in broad(rule)})
            if hit:
                out("BROAD      %s %s %s/%s: fails closed on every %s in the cluster; let objects opt in, "
                    "or set failurePolicy Ignore" % (where, o["kind"], o["metadata"]["name"], w.get("name"), ", ".join(hit)))
                bad += 1
    return bad


def main(dirs):
    bad = seen = 0
    for d in dirs:
        env = os.path.basename(os.path.normpath(d))
        for path in sorted(glob.glob(os.path.join(d, "*.yaml"))):
            if os.path.basename(path).startswith("_"):
                continue
            with open(path, encoding="utf-8") as f:
                objs = [o for o in yaml.load_all(f, Loader=Loader) if isinstance(o, dict)]
            seen += sum(len(o.get("webhooks") or []) for o in objs if o.get("kind") in KINDS)
            bad += check(objs, "%s %s" % (env, os.path.basename(path)[:-5]))
    print("%d rendered webhooks: %d fail closed on a whole kind" % (seen, bad))
    return 1 if bad else 0


def selftest():
    def hook(name, policy="Fail", ns=None, obj=None, resources=("services",), group="", ops=("CREATE", "UPDATE")):
        w = {"name": name, "rules": [{"apiGroups": [group], "operations": list(ops), "resources": list(resources)}]}
        if policy is not None:
            w["failurePolicy"] = policy
        if ns is not None:
            w["namespaceSelector"] = ns
        if obj is not None:
            w["objectSelector"] = obj
        return w

    notin = {"matchExpressions": [{"key": "app.kubernetes.io/name", "operator": "NotIn", "values": ["x"]}]}
    optin = {"matchExpressions": [{"key": "inject", "operator": "In", "values": ["enabled"]}]}
    cfg = {"kind": "MutatingWebhookConfiguration", "metadata": {"name": "lbc"}, "webhooks": [
        hook("mservice", obj=notin),                        # the 11 November webhook: broad
        hook("default-policy", policy=None, resources=("pods",)),  # failurePolicy defaults to Fail: broad
        hook("mpod", ns=optin, obj=notin, resources=("pods",)),    # opt-in namespaces: fine
        hook("ignore", policy="Ignore"),                    # fails open: fine
        hook("own-kind", group="elbv2.k8s.aws", resources=("targetgroupbindings",)),  # its own kind: fine
        hook("delete-only", ops=("DELETE",)),               # cannot stop a create: fine
        hook("wild", group="*", resources=("*",)),          # everything: broad
    ]}
    lines = []
    assert check([cfg], "t", out=lines.append) == 3, lines
    assert "lbc/mservice: fails closed on every core/services" in lines[0], lines
    assert "lbc/default-policy" in lines[1] and "lbc/wild" in lines[2], lines
    assert check([dict(cfg, kind="ConfigMap")], "t", out=lines.append) == 0
    print("selftest: ok (the Service webhook of 11 November fails, a default failurePolicy counts as Fail, "
          "opt-in selectors, Ignore, own kinds and DELETE-only pass)")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["selftest"]:
        sys.exit(selftest())
    if not sys.argv[1:]:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
