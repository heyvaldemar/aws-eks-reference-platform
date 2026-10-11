#!/usr/bin/env python3
"""Fail if a policy in policies/ has no test that shows it a violation.

    scripts/check-policy-tests.py

A policy whose test only ever sees compliant resources would pass with its
validation deleted. Every ValidatingPolicy listed in policies/kustomization.yaml
needs a Kyverno CLI test in policies/tests/<name>/ with at least one expected
`fail`; every GeneratingPolicy needs one that checks the generated resource.
The tests are then run by `kyverno test policies/tests`.
"""
import os
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POLICIES = os.path.join(ROOT, "policies")


def main():
    with open(os.path.join(POLICIES, "kustomization.yaml"), encoding="utf-8") as f:
        files = yaml.safe_load(f)["resources"]
    bad = []
    count = 0
    for fname in files:
        with open(os.path.join(POLICIES, fname), encoding="utf-8") as f:
            for doc in yaml.safe_load_all(f):
                if not doc or doc.get("apiVersion", "").split("/")[0] != "policies.kyverno.io":
                    continue
                count += 1
                name, kind = doc["metadata"]["name"], doc["kind"]
                test = os.path.join(POLICIES, "tests", name, "kyverno-test.yaml")
                if not os.path.exists(test):
                    bad.append("%s %s has no test at policies/tests/%s/" % (kind, name, name))
                    continue
                with open(test, encoding="utf-8") as f:
                    results = [r for r in (yaml.safe_load(f).get("results") or []) if r.get("policy") == name]
                if kind == "GeneratingPolicy":
                    if not any(r.get("generatedResource") for r in results):
                        bad.append("GeneratingPolicy %s: its test never checks what it generates" % name)
                elif not any(r.get("result") == "fail" for r in results):
                    bad.append("%s %s: its test never shows it a violation (no expected fail)" % (kind, name))
    for line in bad:
        print("UNTESTED  " + line)
    print("%d policies, %d without a test that can fail" % (count, len(bad)))
    return 1 if bad or not count else 0


if __name__ == "__main__":
    sys.exit(main())
