#!/usr/bin/env python3
"""Turn the CRDs the platform installs into JSON schemas kubeconform can use.

    scripts/crd-schemas.py out/kind out/eks .cache/schemas

A public schema catalog lags the charts and holds whatever version someone
last uploaded. These schemas come from the CustomResourceDefinitions in the
rendered output, so every custom resource is checked against the exact CRD
version that will be in the cluster. Objects that declare properties get
`additionalProperties: false` unless the CRD keeps unknown fields, which is
what makes a misspelled field an error instead of a silent no-op.

Layout: <out>/<group>/<kind>_<version>.json, lowercase kind, matching
kubeconform's -schema-location template
    <out>/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json
"""
import json
import os
import sys

import yaml


class Loader(yaml.SafeLoader):
    """SafeLoader that reads YAML's value tag (a bare `=`) as a string."""


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def strict(node):
    if isinstance(node, dict):
        if node.get("type") == "object" and "properties" in node \
                and not node.get("x-kubernetes-preserve-unknown-fields") \
                and "additionalProperties" not in node:
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)
    return node


def main(args):
    *dirs, out = args
    count = 0
    for d in dirs:
        for fname in sorted(os.listdir(d)):
            if not fname.endswith(".yaml"):
                continue
            with open(os.path.join(d, fname), encoding="utf-8") as f:
                for doc in yaml.load_all(f, Loader=Loader):
                    if not isinstance(doc, dict) or doc.get("kind") != "CustomResourceDefinition":
                        continue
                    group = doc["spec"]["group"]
                    kind = doc["spec"]["names"]["kind"].lower()
                    for v in doc["spec"]["versions"]:
                        schema = (v.get("schema") or {}).get("openAPIV3Schema")
                        if not schema:
                            continue
                        schema = strict(json.loads(json.dumps(schema)))
                        # metadata is validated by the API server, not by the CRD schema.
                        schema.setdefault("properties", {})["metadata"] = {"type": "object"}
                        path = os.path.join(out, group, "%s_%s.json" % (kind, v["name"]))
                        os.makedirs(os.path.dirname(path), exist_ok=True)
                        with open(path, "w", encoding="utf-8") as o:
                            json.dump(schema, o)
                        count += 1
    print("%d CRD schemas written to %s" % (count, out))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1:])
