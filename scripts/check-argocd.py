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
                spec = doc["spec"]["template"]["spec"]
                for src in spec.get("sources") or [spec["source"]]:
                    if not src.get("chart") and src.get("targetRevision") != "{{ .metadata.annotations.platform_revision }}":
                        bad.append("%s: a Git source with targetRevision '%s'; it must be {{ .metadata.annotations.platform_revision }}"
                                   % (fname, src.get("targetRevision")))
    for line in bad:
        print("FLOATING  " + line)
    print("%d floating source(s)" % len(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
