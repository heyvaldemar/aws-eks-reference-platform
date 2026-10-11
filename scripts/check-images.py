#!/usr/bin/env python3
"""Fail if any image the platform would run is not pinned by digest.

    scripts/check-images.py out/kind out/eks

Reads what scripts/render.py wrote and looks at every string in every
object, not only `image:` fields: operators take images as flags
(--prometheus-config-reloader=quay.io/...), CRs carry them in their own
fields, and a pin that misses those is a pin with holes. A reference counts
as an image when it starts with a registry this platform pulls from and has
a tag or a digest.

Skipped: CustomResourceDefinitions (their schemas hold example strings) and
Helm test hooks (Argo CD never runs them).
"""
import os
import re
import sys

import yaml


class Loader(yaml.SafeLoader):
    """SafeLoader that reads a bare `=` (YAML's value tag, found in some CRD
    enums) as the string it is."""


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))

REGISTRIES = (
    "docker.io/", "quay.io/", "ghcr.io/", "registry.k8s.io/", "public.ecr.aws/",
    "reg.kyverno.io/", "ecr-public.aws.com/", "gcr.io/", "mcr.microsoft.com/",
    "otel/", "envoyproxy/", "velero/", "chrislusf/", "busybox", "bats/",
)
REF = re.compile(r"(?<![\w./-])((?:%s)[\w./-]*(?::[\w.-]+)?(?:@sha256:[0-9a-f]{64})?)" % "|".join(re.escape(r) for r in REGISTRIES))


def strings(node, path=""):
    if isinstance(node, str):
        yield path, node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from strings(v, "%s.%s" % (path, k) if path else str(k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from strings(v, "%s[%d]" % (path, i))


def is_image(ref):
    # A bare repository with neither tag nor digest is a prefix (a registry
    # setting, a repository field next to a separate digest field), not a
    # reference a container runtime would pull.
    name = ref.split("@")[0]
    return ":" in name.split("/")[-1] or "@sha256:" in ref


def main(dirs):
    bad, seen = [], set()
    for d in dirs:
        for fname in sorted(os.listdir(d)):
            if not fname.endswith(".yaml"):
                continue
            with open(os.path.join(d, fname), encoding="utf-8") as f:
                for doc in yaml.load_all(f, Loader=Loader):
                    if not isinstance(doc, dict):
                        continue
                    if doc.get("kind") == "CustomResourceDefinition":
                        continue
                    hook = (doc.get("metadata") or {}).get("annotations") or {}
                    if "test" in str(hook.get("helm.sh/hook", "")).split(","):
                        continue
                    obj = "%s/%s" % (doc.get("kind"), (doc.get("metadata") or {}).get("name"))
                    for path, s in strings(doc):
                        for m in REF.finditer(s):
                            ref = m.group(1)
                            if not is_image(ref):
                                continue
                            seen.add(ref)
                            if not re.search(r"@sha256:[0-9a-f]{64}$", ref):
                                bad.append("%s/%s  %s  %s: %s" % (os.path.basename(d), fname, obj, path, ref))
    for line in sorted(set(bad)):
        print("NOT PINNED  " + line)
    print("%d image references, %d without a digest" % (len(seen), len(set(bad))))
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
