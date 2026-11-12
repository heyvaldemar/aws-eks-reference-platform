#!/usr/bin/env python3
"""Fail if a field a chart makes anew on every render is not held by Argo CD.

    scripts/check-render-drift.py out/kind out/eks
    scripts/check-render-drift.py selftest

Some charts make a value at render time. The AWS Load Balancer Controller's
makes its webhook CA, certificate and key with genCA on every `helm template`.
Argo CD renders a chart again whenever its manifest cache misses, and applies
what changed. The EKS run of 11 November 2026 started by hand
(run 43119033426) lost every Service to that: a second render's CA reached
the webhook's caBundle while the controller's pods, started on the first
render's Secret, kept serving the first certificate, and the webhook rejects a
Service it cannot be called for.

So each environment is rendered a second time, into a temporary directory, and
every field whose value differs between the two renders must be covered by
its Application's ignoreDifferences, with RespectIgnoreDifferences=true among
its syncOptions: ignoreDifferences alone only hides the change from the diff,
and the next sync of anything else in the Application would still apply it.
With both, a sync keeps the value the cluster already has, and a create
applies the whole render.

Only paths are printed, never values: the values that drift here are
private keys.
"""
import os
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESPECT = "RespectIgnoreDifferences=true"

# The jq paths ignoreDifferences may use here: dotted fields, each optionally
# followed by [] or []? to mean every element. Anything else stops the check,
# so a path it cannot read is never taken to cover a field.
JQ = re.compile(r"^(\.[A-Za-z_][A-Za-z0-9_]*(\[\]\??)?)+$")
JQ_PART = re.compile(r"\.([A-Za-z_][A-Za-z0-9_]*)(\[\]\??)?")


def escape(key):
    return str(key).replace("~", "~0").replace("/", "~1")


def drift(a, b, ptr=""):
    """JSON pointers whose values differ between two documents."""
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            if k not in a or k not in b:
                yield ptr + "/" + escape(k)
            else:
                yield from drift(a[k], b[k], ptr + "/" + escape(k))
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            yield from drift(x, y, "%s/%d" % (ptr, i))
    elif a != b:
        yield ptr or "/"


def jq_pattern(expr):
    if not JQ.match(expr):
        sys.exit("ignoreDifferences jqPathExpression %r: this check reads only dotted fields and [] or []?; "
                 "extend it before using another form" % expr)
    out = ""
    for name, every in JQ_PART.findall(expr):
        out += "/" + re.escape(escape(name)) + (r"/\d+" if every else "")
    return re.compile("^" + out + "(/|$)")


def covers(rule, obj, ptr):
    group = obj["apiVersion"].rpartition("/")[0] if "/" in obj["apiVersion"] else ""
    meta = obj.get("metadata") or {}
    if rule.get("group", "") != group or rule.get("kind") != obj.get("kind"):
        return False
    if rule.get("name") and rule["name"] != meta.get("name"):
        return False
    if rule.get("namespace") and rule["namespace"] != meta.get("namespace"):
        return False
    for p in rule.get("jsonPointers") or []:
        if ptr == p or ptr.startswith(p.rstrip("/") + "/"):
            return True
    return any(jq_pattern(e).match(ptr) for e in rule.get("jqPathExpressions") or [])


def key(obj):
    meta = obj.get("metadata") or {}
    return (obj.get("apiVersion"), obj.get("kind"), meta.get("namespace") or "", meta.get("name"))


class Loader(yaml.SafeLoader):
    """SafeLoader that reads YAML's value tag (a bare `=`, which a chart's
    rendered alert rules hold) as the string it is, as scripts/check-argocd.py does."""


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def documents(path):
    with open(path, encoding="utf-8") as f:
        return {key(d): d for d in yaml.load_all(f, Loader=Loader) if isinstance(d, dict) and d.get("kind")}


def applications(out):
    with open(os.path.join(out, "_applications.yaml"), encoding="utf-8") as f:
        return {a["metadata"]["name"]: a for a in yaml.safe_load_all(f) if a}


def check(env, first, second, out=print):
    """Compare two renders of one environment. Returns how many drifting fields are not held."""
    apps = applications(first)
    held = loose = 0
    for name in sorted(apps):
        a_path, b_path = os.path.join(first, name + ".yaml"), os.path.join(second, name + ".yaml")
        if not os.path.exists(a_path):
            continue
        a, b = documents(a_path), documents(b_path)
        spec = apps[name].get("spec") or {}
        rules = spec.get("ignoreDifferences") or []
        respected = RESPECT in ((spec.get("syncPolicy") or {}).get("syncOptions") or [])
        for k in sorted(set(a) | set(b), key=lambda k: tuple(str(x) for x in k)):
            where = "%s %s %s %s" % (env, name, k[1], "/".join(x for x in (k[2], k[3]) if x))
            if k not in a or k not in b:
                out("DRIFT      %s: in one render only" % where)
                loose += 1
                continue
            for ptr in drift(a[k], b[k]):
                if not any(covers(r, a[k], ptr) for r in rules):
                    out("DRIFT      %s %s: changes on every render and is not in the Application's ignoreDifferences" % (where, ptr))
                    loose += 1
                elif not respected:
                    out("DRIFT      %s %s: in ignoreDifferences, but syncOptions lack %s, so a sync applies it" % (where, ptr, RESPECT))
                    loose += 1
                else:
                    out("ok  held   %s %s" % (where, ptr))
                    held += 1
    out("%s: %d fields change between two renders: %d held, %d not" % (env, held + loose, held, loose))
    return loose


def main(dirs):
    loose = 0
    with tempfile.TemporaryDirectory(prefix="render-drift-") as tmp:
        for first in dirs:
            env = os.path.basename(os.path.normpath(first))
            second = os.path.join(tmp, env)
            subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "render.py"), env, second],
                           check=True, stdout=subprocess.DEVNULL)
            loose += check(env, first, second)
    return 1 if loose else 0


def selftest():
    def app(rules=None, respect=True):
        spec = {"syncPolicy": {"syncOptions": ["ServerSideApply=true"] + ([RESPECT] if respect else [])}}
        if rules is not None:
            spec["ignoreDifferences"] = rules
        return {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": {"name": "lbc"}, "spec": spec}

    def render(seed):
        return [
            {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "tls", "namespace": "kube-system"},
             "data": {"tls.key": "k%d" % seed, "tls.crt": "c%d" % seed, "ca.crt": "a%d" % seed}},
            {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "MutatingWebhookConfiguration",
             "metadata": {"name": "hook"},
             "webhooks": [{"name": "w%d" % i, "clientConfig": {"caBundle": "a%d" % seed}} for i in range(2)]},
            {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "svc", "namespace": "kube-system"},
             "spec": {"ports": [{"port": 443}]}},
        ]

    rules = [{"kind": "Secret", "name": "tls", "jsonPointers": ["/data"]},
             {"group": "admissionregistration.k8s.io", "kind": "MutatingWebhookConfiguration",
              "jqPathExpressions": [".webhooks[]?.clientConfig.caBundle"]}]

    def run(application):
        with tempfile.TemporaryDirectory() as tmp:
            for side, seed in (("a", 1), ("b", 2)):
                os.makedirs(os.path.join(tmp, side))
                with open(os.path.join(tmp, side, "_applications.yaml"), "w", encoding="utf-8") as f:
                    yaml.safe_dump(application, f)
                with open(os.path.join(tmp, side, "lbc.yaml"), "w", encoding="utf-8") as f:
                    yaml.safe_dump_all(render(seed), f)
            lines = []
            return check("t", os.path.join(tmp, "a"), os.path.join(tmp, "b"), out=lines.append), lines

    loose, lines = run(app(rules))
    assert loose == 0 and lines[-1] == "t: 5 fields change between two renders: 5 held, 0 not", lines
    assert not any("k1" in l or "k2" in l or "a1" in l for l in lines), "a value reached the output"
    loose, lines = run(app(None))
    assert loose == 5 and any("Secret kube-system/tls /data/tls.key: changes on every render" in l for l in lines), lines
    loose, lines = run(app(rules, respect=False))
    assert loose == 5 and "lack " + RESPECT in lines[0], lines
    loose, _ = run(app([rules[0]]))
    assert loose == 2, "the webhooks' caBundle must not be covered by the Secret's rule"
    loose, _ = run(app([dict(rules[0], name="other"), rules[1]]))
    assert loose == 3, "a rule for another name must not cover the Secret"
    assert jq_pattern(".webhooks[]?.clientConfig.caBundle").match("/webhooks/1/clientConfig/caBundle")
    assert not jq_pattern(".webhooks[]?.clientConfig.caBundle").match("/webhooks/1/clientConfig/url")
    try:
        jq_pattern('.webhooks[] | select(.name == "x")')
        raise AssertionError("an unreadable jq path was accepted")
    except SystemExit:
        pass
    assert list(drift({"a": [1, 2]}, {"a": [1, 2, 3]})) == ["/a"]
    assert list(drift({"a/b": 1}, {"a/b": 2})) == ["/a~1b"]
    print("selftest: ok (generated Secret data and caBundle held by ignoreDifferences + %s; "
          "drift without either is reported, values never printed, rules match group, kind and name)" % RESPECT)
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["selftest"]:
        sys.exit(selftest())
    if not sys.argv[1:]:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
