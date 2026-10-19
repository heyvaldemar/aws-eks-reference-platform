#!/usr/bin/env python3
"""Blank every Secret's values in rendered manifests, before they are uploaded.

    scripts/redact-secrets.py <dir>     rewrite every .yaml under <dir> in place
    scripts/redact-secrets.py selftest  show it a Secret holding a key, and fail
                                        if any of the key survives

Some charts generate key material when they render: the AWS Load Balancer
Controller's and External Secrets' webhook certificates come out of the
render with a private key in a Secret. Those keys are never deployed (Argo CD
renders the charts itself), but Verification uploads what it rendered, and a
private key does not belong in a public artifact. Each Secret keeps its name
and its keys, so the artifact still shows what exists; every value becomes
"redacted". Run after the checks, which read the real render.
"""
import base64
import glob
import os
import sys
import tempfile

import yaml



class Loader(yaml.SafeLoader):
    """SafeLoader, and a bare `=` (YAML 1.1's value tag, in Prometheus rules) read as text."""


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))

REDACTED = "redacted"
REDACTED_B64 = base64.b64encode(REDACTED.encode()).decode()


def redact(doc):
    if not isinstance(doc, dict) or doc.get("kind") != "Secret":
        return doc, 0
    n = 0
    for field, value in (("data", REDACTED_B64), ("stringData", REDACTED)):
        if isinstance(doc.get(field), dict):
            for k in doc[field]:
                doc[field][k] = value
                n += 1
    return doc, n


def redact_file(path):
    with open(path, encoding="utf-8") as f:
        docs = list(yaml.load_all(f, Loader=Loader))
    total = 0
    for i, d in enumerate(docs):
        docs[i], n = redact(d)
        total += n
    if total:
        with open(path, "w", encoding="utf-8") as f:
            yaml.safe_dump_all(docs, f, sort_keys=False)
    return total


def selftest():
    key = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----\n"
    planted = {
        "apiVersion": "v1", "kind": "Secret", "metadata": {"name": "webhook-cert"},
        "data": {"tls.key": base64.b64encode(key.encode()).decode()},
        "stringData": {"token": "planted-token-value"},
    }
    other = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "c"}, "data": {"k": "kept"}}
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "chart.yaml")
        with open(p, "w", encoding="utf-8") as f:
            yaml.safe_dump_all([other, planted], f)
        n = redact_file(p)
        out = open(p, encoding="utf-8").read()
    leaked = [s for s in (key.splitlines()[1], planted["data"]["tls.key"][:24], "planted-token-value") if s in out]
    ok = n == 2 and not leaked and "kept" in out and "tls.key" in out
    print("selftest: %s (%d values blanked, %s leaked, the ConfigMap %s)"
          % ("ok" if ok else "FAILED", n, leaked or "nothing", "kept" if "kept" in out else "changed"))
    return 0 if ok else 1


def main():
    if sys.argv[1:] == ["selftest"]:
        return selftest()
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    files = sorted(glob.glob(os.path.join(sys.argv[1], "**", "*.yaml"), recursive=True))
    total = sum(redact_file(p) for p in files)
    print("blanked %d Secret values in %d rendered files" % (total, len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
