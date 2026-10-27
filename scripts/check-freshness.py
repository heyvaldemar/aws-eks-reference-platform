#!/usr/bin/env python3
"""Report every pin in this repository that upstream has moved past.

    GH_TOKEN=... scripts/check-freshness.py
    scripts/check-freshness.py selftest   show it a registry that keeps answering
                                          429, and fail unless it says so

Pins are what make a green build mean something, and they are also what goes
stale without a sound. This compares each one with upstream and prints a
GitHub error annotation per pin that fell behind; it changes nothing. Fleet
triage reads the failed run and opens the bump, which then has to pass the
same Verification and kind e2e as any other change.

  charts        platform/appsets/*.yaml against the repository Argo CD pulls
                from (a Helm index, or the project's releases for OCI charts)
  images        every repo:tag@sha256 against what the tag resolves to now
                (a moved tag is a rebuilt image nobody here has run)
  chart images  each chart rendered without images.yaml, against the tags
                images.yaml pins: a chart bump that moves an image's default
                tag while the pin stays behind is caught here, not in a cluster
  tools         tools.lock against each tool's latest release
  ci images     ci-images.pins, same as images
  kind node     kind/cluster.yaml against the Kubernetes version targeted
  kubernetes    the targeted minor against EKS's newest, and its support end
  terraform     the AWS provider in terraform/.terraform.lock.hcl

A registry that keeps refusing is not a pin behind and not a pin current.
ECR Public throttles anonymous requests by source address, and GitHub's
shared runners share theirs: on 27 October about half of this job's runs met
"429 toomanyrequests: Data limit exceeded" for the same three pins, which
resolved from everywhere else. A refusal is tried three times over three
minutes; after that the pin is reported as not checked, which fails the run
as a pin behind does, and the summary never counts it as current.
"""
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
Loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
problems = []
not_checked = []


def behind(what, detail):
    problems.append(what)
    print("::error::%s: %s" % (what, detail))


def unchecked(what, detail):
    not_checked.append(what)
    print("::error::%s: %s" % (what, detail))


class Unchecked(Exception):
    """A registry refused to answer: the pin is neither current nor behind."""


THROTTLED = re.compile(r"\b429\b|toomanyrequests", re.I)
WAITS = (60, 120)  # before the second and the third try
throttled_hosts = {}


def registry(ref):
    """The registry host of an image reference, and what to call it."""
    first = ref.split("/", 1)[0]
    host = first if "/" in ref and ("." in first or ":" in first) else "docker.io"
    return host, ("ECR Public" if host == "public.ecr.aws" else host)


def last_line(text):
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    return lines[-1][:300] if lines else "no message"


def ok(what, detail):
    print("ok  %-48s %s" % (what, detail))


def get(url, gh=False):
    req = urllib.request.Request(url, headers={"User-Agent": "check-freshness"})
    if gh and TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def semver(v):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)$", v)
    return tuple(int(x) for x in m.groups()) if m else None


def newest(versions):
    vs = [v for v in versions if semver(v)]
    return max(vs, key=semver) if vs else None


def gh_releases(repo, pattern):
    data = json.loads(get("https://api.github.com/repos/%s/releases?per_page=100" % repo, gh=True))
    out = []
    for r in data:
        if r.get("prerelease") or r.get("draft"):
            continue
        m = re.fullmatch(pattern, r["tag_name"])
        if m:
            out.append(m.group(1))
    return out


# OCI charts have no index to read; their projects tag releases instead.
OCI_RELEASES = {
    "gateway-helm": ("envoyproxy/gateway", r"(v\d+\.\d+\.\d+)"),
    "karpenter": ("aws/karpenter-provider-aws", r"v(\d+\.\d+\.\d+)"),
}


def check_charts():
    indexes = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "platform", "appsets", "*.yaml"))):
        for doc in yaml.safe_load_all(open(path, encoding="utf-8")):
            if not doc or doc.get("kind") != "ApplicationSet":
                continue
            for src in doc["spec"]["template"]["spec"].get("sources") or []:
                if not src.get("chart"):
                    continue
                chart, repo, pinned = src["chart"], src["repoURL"], str(src["targetRevision"])
                if repo.startswith("http"):
                    if repo not in indexes:
                        indexes[repo] = yaml.load(get(repo.rstrip("/") + "/index.yaml"), Loader=Loader)["entries"]
                    latest = newest([e["version"] for e in indexes[repo].get(chart, [])])
                else:
                    gh_repo, pattern = OCI_RELEASES[chart]
                    latest = newest(gh_releases(gh_repo, pattern))
                what = "chart %s" % chart
                if latest is None:
                    behind(what, "could not find any release upstream; the pin %s is unchanged" % pinned)
                elif semver(latest) > semver(pinned):
                    behind(what, "pinned %s, latest is %s" % (pinned, latest))
                else:
                    ok(what, pinned)


def imagetools(ref):
    return subprocess.run(["docker", "buildx", "imagetools", "inspect", ref], capture_output=True, text=True)


def digest_of(ref):
    """The digest the tag resolves to now; None if it does not resolve.
    Raises Unchecked when the registry is still throttling after three tries,
    or already did earlier in this run."""
    host, name = registry(ref)
    if host in throttled_hosts:
        raise Unchecked("could not check: %s throttled earlier in this run (%s)" % (name, throttled_hosts[host]))
    throttled = None
    for attempt in range(3):
        if attempt and throttled:
            time.sleep(WAITS[attempt - 1])
        r = imagetools(ref)
        m = re.search(r"^Digest:\s+(sha256:[0-9a-f]{64})", r.stdout, re.M)
        if m:
            return m.group(1)
        out = r.stdout + r.stderr
        throttled = last_line(out) if THROTTLED.search(out) else None
    if throttled:
        throttled_hosts[host] = throttled
        raise Unchecked("could not check: %s throttled, three tries over %d seconds (%s)" % (name, sum(WAITS), throttled))
    return None


def check_images():
    refs = set()
    files = glob.glob(os.path.join(ROOT, "platform", "values", "*", "images.yaml"))
    files += glob.glob(os.path.join(ROOT, "apps", "**", "*.yaml"), recursive=True)
    files += glob.glob(os.path.join(ROOT, "manifests", "**", "*.yaml"), recursive=True)
    # The e2e suite's own images (the probe pods, the load generator).
    files += glob.glob(os.path.join(ROOT, "tests", "e2e", "**", "*.yaml"), recursive=True)
    files += glob.glob(os.path.join(ROOT, "tests", "e2e", "*.sh"))
    for f in files:
        text = open(f, encoding="utf-8").read()
        refs.update(re.findall(r"([\w.-]+(?:/[\w.-]+)+:[\w.-]+@sha256:[0-9a-f]{64})", text))
        # values files that split repository, tag and digest
        def walk(n):
            if isinstance(n, dict):
                repo, tag = n.get("repository"), str(n.get("tag", ""))
                digest = n.get("digest") or (("sha256:" + n["sha"]) if n.get("sha") and not str(n["sha"]).startswith("sha256:") else n.get("sha"))
                if repo and tag and digest and "@" not in tag:
                    reg = n.get("registry")
                    refs.add("%s%s:%s@%s" % (reg + "/" if reg else "", repo, tag, digest))
                elif repo and "@sha256:" in tag:
                    reg = n.get("registry")
                    refs.add("%s%s:%s" % (reg + "/" if reg else "", repo, tag))
                for v in n.values():
                    walk(v)
            elif isinstance(n, list):
                for v in n:
                    walk(v)
        if f.endswith(".yaml"):
            for doc in yaml.safe_load_all(text):
                walk(doc)
    for ref in sorted(refs):
        name, _, pinned = ref.partition("@")
        try:
            now = digest_of(name)
        except Unchecked as e:
            unchecked("image %s" % name, str(e))
            continue
        if now is None:
            behind("image %s" % name, "did not resolve; the registry did not answer or the tag is gone")
        elif now != pinned:
            behind("image %s" % name, "pinned %s, the tag now points at %s" % (pinned, now))
        else:
            ok("image %s" % name, pinned[:19])


TOOL_RELEASES = {
    "kind": ("kubernetes-sigs/kind", r"(v\d+\.\d+\.\d+)"),
    "helm": ("helm/helm", r"(v\d+\.\d+\.\d+)"),
    "kubeconform": ("yannh/kubeconform", r"(v\d+\.\d+\.\d+)"),
    "kube-linter": ("stackrox/kube-linter", r"(v\d+\.\d+\.\d+)"),
    "kyverno": ("kyverno/kyverno", r"(v\d+\.\d+\.\d+)"),
    "pluto": ("FairwindsOps/pluto", r"(v\d+\.\d+\.\d+)"),
    "promtool": ("prometheus/prometheus", r"(v\d+\.\d+\.\d+)"),
}


def rendered_images(env, out, default_images):
    environ = dict(os.environ, RENDER_CHART_DEFAULT_IMAGES="1" if default_images else "0")
    r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "render.py"), env, out],
                       capture_output=True, text=True, env=environ)
    if r.returncode != 0:
        # render.py tries a throttled chart pull three times itself.
        if THROTTLED.search(r.stderr):
            raise Unchecked("could not check: the %s render was throttled pulling a chart (%s)" % (env, last_line(r.stderr)))
        raise RuntimeError("render.py %s exited %d: %s" % (env, r.returncode, last_line(r.stderr)))
    refs = set()
    for f in glob.glob(os.path.join(out, "*.yaml")):
        refs.update(re.findall(r"image: \"?([\w.-]+(?:/[\w.-]+)+:[\w.-]+)(?:@sha256:[0-9a-f]{64})?", open(f, encoding="utf-8").read()))
    return {r.rsplit(":", 1)[0]: r.rsplit(":", 1)[1] for r in refs}


def check_chart_images():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        for env in ("kind", "eks"):
            pinned = rendered_images(env, os.path.join(tmp, env + "-pinned"), False)
            default = rendered_images(env, os.path.join(tmp, env + "-default"), True)
            for repo, tag in sorted(default.items()):
                if repo in pinned and pinned[repo] != tag:
                    # A pin newer than the chart's default is a deliberate patch
                    # (velero v1.18.4 over the chart's 1.18.2); only older is behind.
                    # A chart that defaults to "latest" names no version to be
                    # behind (kyverno's readiness-checker); the pin is the version.
                    if tag == "latest":
                        ok("chart image %s (%s)" % (repo, env), "pinned %s; the chart's default is latest" % pinned[repo])
                    elif semver(pinned[repo]) and semver(tag) and semver(pinned[repo]) > semver(tag):
                        ok("chart image %s (%s)" % (repo, env), "pinned %s, newer than the chart's %s" % (pinned[repo], tag))
                    else:
                        behind("chart image %s (%s)" % (repo, env), "images.yaml pins %s, the chart now defaults to %s" % (pinned[repo], tag))


def check_tools():
    seen = {}
    for line in open(os.path.join(ROOT, "tools.lock"), encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            name, version = line.split()[:2]
            seen[name] = version
    for name, pinned in sorted(seen.items()):
        if name == "kubectl":
            # kubectl follows the targeted Kubernetes minor, not the newest one.
            minor = ".".join(pinned.lstrip("v").split(".")[:2])
            latest = get("https://dl.k8s.io/release/stable-%s.txt" % minor).decode().strip()
        else:
            repo, pattern = TOOL_RELEASES[name]
            latest = newest(gh_releases(repo, pattern))
        if latest and semver(latest) > semver(pinned):
            behind("tool %s" % name, "pinned %s, latest is %s" % (pinned, latest))
        else:
            ok("tool %s" % name, pinned)


def check_ci_images():
    for line in open(os.path.join(ROOT, "ci-images.pins"), encoding="utf-8"):
        m = re.match(r"^([A-Z_]+)=(.+)@(sha256:[0-9a-f]{64})$", line.strip())
        if not m:
            continue
        var, name, pinned = m.groups()
        try:
            now = digest_of(name)
        except Unchecked as e:
            unchecked("ci image %s" % var, str(e))
            continue
        if now != pinned:
            behind("ci image %s" % var, "pinned %s, %s now resolves to %s" % (pinned, name, now))
        else:
            ok("ci image %s" % var, name)


def check_kubernetes():
    target = re.search(r"^KUBE_VERSION=(\d+\.\d+)", open(os.path.join(ROOT, "scripts", "validate.sh")).read(), re.M).group(1)
    node = re.search(r"kindest/node:v(\d+\.\d+)\.\d+@", open(os.path.join(ROOT, "kind", "cluster.yaml")).read()).group(1)
    tf = re.search(r'variable "kubernetes_version".*?default\s*=\s*"([\d.]+)"',
                   open(os.path.join(ROOT, "terraform", "variables.tf")).read(), re.S).group(1)
    for what, v in (("kind node image", node), ("terraform kubernetes_version", tf)):
        if v != target:
            behind(what, "is %s, the platform targets %s" % (v, target))
        else:
            ok(what, v)
    cycles = json.loads(get("https://endoflife.date/api/amazon-eks.json"))
    newest_minor = max((c["cycle"] for c in cycles), key=lambda c: tuple(int(x) for x in c.split(".")))
    ours = next((c for c in cycles if c["cycle"] == target), None)
    if tuple(int(x) for x in newest_minor.split(".")) > tuple(int(x) for x in target.split(".")):
        behind("kubernetes", "the platform targets %s, EKS offers %s" % (target, newest_minor))
    else:
        ok("kubernetes", "%s is EKS's newest" % target)
    if ours and isinstance(ours.get("eol"), str):
        left = (datetime.date.fromisoformat(ours["eol"]) - datetime.date.today()).days
        if left < 90:
            behind("kubernetes %s support" % target, "standard support ends %s, in %d days" % (ours["eol"], left))


def check_terraform():
    lock = open(os.path.join(ROOT, "terraform", ".terraform.lock.hcl"), encoding="utf-8").read()
    for source, pinned in re.findall(r'provider "registry\.terraform\.io/([^"]+)" \{\s*version\s*=\s*"([^"]+)"', lock):
        latest = json.loads(get("https://registry.terraform.io/v1/providers/" + source))["version"]
        if semver(latest) > semver(pinned):
            behind("provider %s" % source, "locked %s, latest is %s" % (pinned, latest))
        else:
            ok("provider %s" % source, pinned)


def summary():
    if not_checked:
        print("%d pin(s) could not be checked, so how many are behind is not known; "
              "%d behind among the rest" % (len(not_checked), len(problems)))
    else:
        print("%d pin(s) behind upstream" % len(problems))
    return 1 if problems or not_checked else 0


def main(checks=(check_charts, check_images, check_chart_images, check_tools, check_ci_images, check_kubernetes, check_terraform)):
    for check in checks:
        try:
            check()
        except Unchecked as e:
            unchecked(check.__name__, str(e))
        except Exception as e:  # one unreachable upstream must not hide the others
            behind(check.__name__, "could not complete: %s" % e)
    return summary()


def selftest():
    """A registry that answers 429 every time must fail the run as not
    checked, after three tries, and stop asking that host; one that answers
    must still be checked."""
    global imagetools, WAITS
    calls = []

    def fake(ref):
        calls.append(ref)
        if ref.startswith("public.ecr.aws/"):
            return subprocess.CompletedProcess([], 1, "", "ERROR: unexpected status from HEAD request to "
                                               "https://public.ecr.aws/v2/x/manifests/1: 429 Too Many Requests\n"
                                               "toomanyrequests: Data limit exceeded\n")
        return subprocess.CompletedProcess([], 0, "Name: %s\nDigest: sha256:%s\n" % (ref, "a" * 64), "")

    imagetools, WAITS = fake, (0, 0)
    import io, contextlib
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main(checks=(lambda: [digest_of("public.ecr.aws/eks/a:1"), None],
                            lambda: [digest_of("public.ecr.aws/docker/library/b:2"), None],
                            lambda: digest_of("quay.io/c/d:3") == "sha256:" + "a" * 64 or behind("control", "an answering registry was not read")))
    text = out.getvalue()
    ok = (code == 1 and calls.count("public.ecr.aws/eks/a:1") == 3 and "public.ecr.aws/docker/library/b:2" not in calls
          and "quay.io/c/d:3" in calls and len(not_checked) == 2 and not problems
          and "could not check: ECR Public throttled" in text and "0 pin(s) behind upstream" not in text)
    print(text, end="")
    print("selftest: %s (exit %d, %d tries on the throttled host, %d not checked, %d behind)"
          % ("ok" if ok else "FAILED", code, len([c for c in calls if c.startswith("public.ecr.aws/")]), len(not_checked), len(problems)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["selftest"] else main())
