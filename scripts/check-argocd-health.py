#!/usr/bin/env python3
"""Argo CD's health verdict on each object in tests/static/argocd-health/.

    scripts/check-argocd-health.py out/kind [out/eks]

Argo CD decides whether an Application is Healthy, and with it whether
scripts/wait-for-platform.sh lets a run go on, from health checks: the ones
compiled into Argo CD and the overrides in argocd-cm. Each fixture is an
object with the status a controller can leave on it, and an annotation with
the verdict Argo CD must reach: a known false failure that must not stop the
platform, and real failures that must. The verdicts come from
`argocd admin settings resource-overrides health`, run offline in the Argo CD
image platform/values/argo-cd/images.yaml pins, against the argocd-cm the
chart renders: the same binary, and the same overrides, as the cluster.

Needs docker.
"""
import glob
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "tests", "static", "argocd-health")
EXPECT = "reference-platform.test/expect-health"
EXPECT_MESSAGE = "reference-platform.test/expect-message"


def argocd_image():
    pins = yaml.safe_load(open(os.path.join(ROOT, "platform", "values", "argo-cd", "images.yaml")))
    image = pins["global"]["image"]
    if "@sha256:" not in image["tag"]:
        sys.exit("platform/values/argo-cd/images.yaml: the Argo CD image is not pinned by digest")
    return "%s:%s" % (image["repository"], image["tag"])


def argocd_cm(out):
    for doc in yaml.safe_load_all(open(os.path.join(out, "argo-cd.yaml"))):
        if doc and doc.get("kind") == "ConfigMap" and doc["metadata"]["name"] == "argocd-cm":
            return doc
    sys.exit("%s/argo-cd.yaml: no argocd-cm rendered" % out)


def verdicts(image, cm, fixtures):
    """{fixture name: (status, message)}, from one container."""
    with tempfile.TemporaryDirectory() as tmp:
        os.chmod(tmp, 0o755)
        yaml.safe_dump(cm, open(os.path.join(tmp, "argocd-cm.yaml"), "w"))
        for f in fixtures:
            shutil.copy(f, tmp)
        script = ('for f in /w/*.yaml; do [ "$f" = /w/argocd-cm.yaml ] && continue; echo "== $(basename "$f")"; '
                  'argocd admin settings resource-overrides health "$f" --argocd-cm-path /w/argocd-cm.yaml 2>/dev/null || echo "STATUS: error"; done')
        r = subprocess.run(["docker", "run", "--rm", "-v", "%s:/w:ro" % tmp, "--entrypoint", "sh", image, "-c", script],
                           capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("docker run %s failed: %s" % (image, (r.stderr.strip().splitlines() or ["no message"])[-1]))
    out, name = {}, None
    for line in r.stdout.splitlines():
        if line.startswith("== "):
            name = line[3:]
            out[name] = ["", ""]
        elif name and line.startswith("STATUS: "):
            out[name][0] = line[8:].strip()
        elif name and line.startswith("MESSAGE: "):
            out[name][1] = line[9:].strip()
    return out


def main():
    outs = sys.argv[1:] or [os.path.join(ROOT, "out", "kind")]
    fixtures = sorted(glob.glob(os.path.join(FIXTURES, "*.yaml")))
    if not fixtures:
        sys.exit("no fixtures in %s" % FIXTURES)
    if shutil.which("docker") is None:
        sys.exit("docker is needed to run Argo CD's health checks")
    image = argocd_image()
    failed = 0
    for out in outs:
        got = verdicts(image, argocd_cm(out), fixtures)
        for f in fixtures:
            name = os.path.basename(f)
            meta = yaml.safe_load(open(f))["metadata"]
            want, want_msg = meta["annotations"][EXPECT], meta["annotations"].get(EXPECT_MESSAGE, "")
            status, message = got.get(name, ["missing", ""])
            if status == want and want_msg in message:
                print("ok    %s %s: %s (%s)" % (os.path.basename(out), name, status, message))
            else:
                failed += 1
                print("FAIL  %s %s: Argo CD says %s (%s), expected %s%s"
                      % (os.path.basename(out), name, status, message, want,
                         " with \"%s\"" % want_msg if want_msg else ""))
    print("%d of %d verdicts as expected" % (len(outs) * len(fixtures) - failed, len(outs) * len(fixtures)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
