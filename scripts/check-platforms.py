#!/usr/bin/env python3
"""Fail if a pinned image cannot run on the nodes it would be scheduled on.

    scripts/check-platforms.py out/kind out/eks
    scripts/check-platforms.py selftest

A digest pins bytes, not architectures. On 11 November 2026 the weekly EKS
run failed: kube-prometheus-stack 93.1.1 had brought prometheus-operator
v0.95.1, whose image index lists five manifests, every one for linux/amd64
(upstream's own report: prometheus-operator/prometheus-operator#8953). The
arm64 system nodes could not pull it, and every check before AWS had passed,
because every runner here is amd64.

For each image reference scripts/check-images.py finds in out/<env>, this
asks the registry for the manifest its digest names and reads the platforms
it lists (a single-platform manifest through its config blob), and requires
every platform that env's nodes can run:

  kind  linux/amd64: the kind node is a container on the amd64 GitHub runner.
  eks   the architecture of the system node group's AMI (`ami_type` in
        terraform/nodes.tf) and every `kubernetes.io/arch` the rendered
        Karpenter NodePools allow (amd64 where a NodePool sets none, which
        is Karpenter's default).

The registries are asked anonymously over the registry HTTP API, so no
docker login is read and none is needed. A request that is throttled (429),
fails on the server (5xx) or times out is tried three times; a reference
still unanswered is reported as not checked, and fails the check, because
nothing is known about where it can run. `selftest` runs the same code
against a registry made of fixtures and needs no network.
"""
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("check_images", os.path.join(ROOT, "scripts", "check-images.py"))
check_images = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_images)

ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
INDEXES = ("application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json")
WAITS = (20, 60)  # between the three tries of one request
TIMEOUT = 30
KIND_PLATFORMS = {"linux/amd64"}
AMI_ARCH = (("ARM_64", "arm64"), ("x86_64", "amd64"))


class Unchecked(Exception):
    """The registry did not answer, so the platforms are not known."""


# --- references -------------------------------------------------------------

def parse(ref):
    """'quay.io/a/b:v1@sha256:..' -> ('quay.io', 'a/b', 'sha256:..'), with
    Docker Hub's short names spelled out the way its API wants them."""
    name, _, digest = ref.partition("@")
    first, _, rest = name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        host, repo = first, rest
    else:
        host, repo = "docker.io", name
    repo = re.sub(r":[\w.-]+$", "", repo)
    if host == "docker.io":
        host = "registry-1.docker.io"
        if "/" not in repo:
            repo = "library/" + repo
    return host, repo, digest


# --- the registry -----------------------------------------------------------

class Registry:
    """Anonymous reads of manifests and blobs, with one bearer token per
    realm and scope, kept in memory only."""

    def __init__(self, waits=WAITS):
        self.tokens = {}
        self.waits = waits

    def _token(self, challenge):
        params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
        realm = params.pop("realm", None)
        if not realm:
            raise Unchecked("no realm in the registry's challenge")
        key = (realm, params.get("scope"))
        if key not in self.tokens:
            url = realm + ("&" if "?" in realm else "?") + urllib.parse.urlencode(params)
            with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
                body = json.load(r)
            self.tokens[key] = body.get("token") or body.get("access_token")
        return self.tokens[key]

    def _get_once(self, url, accept):
        req = urllib.request.Request(url, headers={"Accept": accept, "User-Agent": "check-platforms"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return r.headers.get("Content-Type", ""), r.read()
        except urllib.error.HTTPError as e:
            if e.code != 401:
                raise
            challenge = e.headers.get("WWW-Authenticate", "")
            final = e.geturl()
        if not challenge.lower().startswith("bearer"):
            raise Unchecked("the registry asks for %s, not an anonymous token" % (challenge.split(" ")[0] or "nothing"))
        req = urllib.request.Request(final, headers={"Accept": accept, "User-Agent": "check-platforms"})
        # Not forwarded on a redirect: a blob is served from another host.
        req.add_unredirected_header("Authorization", "Bearer " + self._token(challenge))
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.headers.get("Content-Type", ""), r.read()

    def get(self, url, accept):
        last = None
        for attempt in range(len(self.waits) + 1):
            if attempt:
                time.sleep(self.waits[attempt - 1])
            try:
                return self._get_once(url, accept)
            except urllib.error.HTTPError as e:
                if e.code != 429 and e.code < 500:
                    raise Unchecked("HTTP %d" % e.code)
                last = "HTTP %d" % e.code
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = str(getattr(e, "reason", e))
        raise Unchecked("%s, %d tries over %d seconds" % (last, len(self.waits) + 1, sum(self.waits)))

    def platforms(self, host, repo, digest):
        base = "https://%s/v2/%s" % (host, repo)
        ctype, body = self.get("%s/manifests/%s" % (base, digest), ACCEPT)
        doc = json.loads(body)
        if doc.get("mediaType", ctype.split(";")[0]) in INDEXES or "manifests" in doc:
            return platforms_of_index(doc)
        config = (doc.get("config") or {}).get("digest")
        if not config:
            raise Unchecked("a manifest with no config")
        _, blob = self.get("%s/blobs/%s" % (base, config), "application/octet-stream, */*")
        cfg = json.loads(blob)
        return {"%s/%s" % (cfg.get("os"), cfg.get("architecture"))}


def platforms_of_index(doc):
    # Attestation manifests sit in the index as unknown/unknown.
    return {"%s/%s" % (m["platform"]["os"], m["platform"]["architecture"])
            for m in doc.get("manifests", [])
            if m.get("platform") and m["platform"].get("architecture") not in (None, "unknown")}


# --- where each environment runs --------------------------------------------

def eks_platforms(nodes_tf, eks_dir):
    archs, sources = set(), []
    for ami in re.findall(r'^\s*ami_type\s*=\s*"([^"]+)"', nodes_tf, re.M):
        arch = next((a for key, a in AMI_ARCH if key in ami), None)
        if arch is None:
            raise SystemExit("terraform/nodes.tf: ami_type %s names no architecture this check knows" % ami)
        archs.add(arch)
        sources.append("ami_type %s" % ami)
    if not archs:
        raise SystemExit("terraform/nodes.tf: no ami_type, so the system nodes' architecture is not known")
    for d in eks_dir:
        for fname in sorted(os.listdir(d)):
            if not fname.endswith(".yaml"):
                continue
            with open(os.path.join(d, fname), encoding="utf-8") as f:
                for doc in yaml.load_all(f, Loader=check_images.Loader):
                    if not isinstance(doc, dict) or doc.get("kind") != "NodePool":
                        continue
                    reqs = (((doc.get("spec") or {}).get("template") or {}).get("spec") or {}).get("requirements") or []
                    allowed = [v for r in reqs if r.get("key") == "kubernetes.io/arch" and r.get("operator") == "In"
                               for v in r.get("values") or []]
                    archs.update(allowed or ["amd64"])
                    sources.append("NodePool %s: %s" % (doc["metadata"]["name"], ", ".join(allowed) or "amd64 by default"))
    return {"linux/" + a for a in archs}, sources


# --- the check --------------------------------------------------------------

def check(envs, registry, out=print):
    """envs: [(name, required platforms, [references])]. Returns the number of
    references that lack a platform or could not be read."""
    known, missing, unchecked = {}, 0, 0
    for env, need, refs in envs:
        for ref in sorted(refs):
            key = parse(ref)
            if key not in known:
                try:
                    known[key] = registry.platforms(*key)
                except Unchecked as e:
                    known[key] = e
            got = known[key]
            short = re.sub(r"(@sha256:[0-9a-f]{12})[0-9a-f]+$", r"\1", ref)
            if isinstance(got, Unchecked):
                out("UNCHECKED  %-4s %s: could not read its manifest (%s)" % (env, short, got))
                unchecked += 1
            elif need - got:
                out("MISSING    %-4s %s: lists %s; %s nodes run %s" % (
                    env, short, ", ".join(sorted(got)) or "no platform", env, ", ".join(sorted(need))))
                missing += 1
            else:
                out("ok         %-4s %s" % (env, short))
    total = sum(len(r) for _, _, r in envs)
    out("%d references: %d lack a platform their nodes run, %d could not be checked" % (total, missing, unchecked))
    return missing + unchecked


def main(dirs):
    envs = []
    for d in dirs:
        env = os.path.basename(os.path.normpath(d))
        refs = {ref for _, _, _, ref in check_images.references(d) if "@sha256:" in ref}
        if env == "kind":
            need, sources = KIND_PLATFORMS, ["the amd64 GitHub runner"]
        elif env == "eks":
            with open(os.path.join(ROOT, "terraform", "nodes.tf"), encoding="utf-8") as f:
                need, sources = eks_platforms(f.read(), [d])
        else:
            raise SystemExit("%s: no platforms known for environment %s" % (d, env))
        print("%s nodes run %s (%s)" % (env, ", ".join(sorted(need)), "; ".join(sources)))
        envs.append((env, need, refs))
    return 1 if check(envs, Registry()) else 0


# --- selftest ---------------------------------------------------------------

def selftest():
    import io
    import tempfile

    digest = lambda c: "sha256:" + c * 64
    full = {"linux/amd64", "linux/arm64", "linux/arm"}
    calls = {}

    class Fake(Registry):
        def _get_once(self, url, accept):
            calls[url] = calls.get(url, 0) + 1
            if "throttled.example" in url:
                raise urllib.error.HTTPError(url, 429, "Too Many Requests", {}, None)
            if url.endswith(digest("a")):  # an index for every platform, and an attestation
                return INDEXES[0], json.dumps({"mediaType": INDEXES[0], "manifests": [
                    {"platform": {"os": p.split("/")[0], "architecture": p.split("/")[1]}} for p in sorted(full)]
                    + [{"platform": {"os": "unknown", "architecture": "unknown"}}]}).encode()
            if url.endswith(digest("b")):  # v0.95.1: five manifests, all linux/amd64
                return INDEXES[0], json.dumps({"mediaType": INDEXES[0], "manifests": [
                    {"platform": {"os": "linux", "architecture": "amd64"}}] * 5}).encode()
            if url.endswith(digest("c")):  # one arm64 image, read through its config
                return ("application/vnd.oci.image.manifest.v1+json",
                        json.dumps({"mediaType": "application/vnd.oci.image.manifest.v1+json",
                                    "config": {"digest": digest("d")}}).encode())
            if url.endswith("/blobs/" + digest("d")):
                return "application/octet-stream", json.dumps({"os": "linux", "architecture": "arm64"}).encode()
            raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)

    fails = []
    want = lambda cond, what: fails.append(what) if not cond else None

    want(parse("busybox:1.37@" + digest("a")) == ("registry-1.docker.io", "library/busybox", digest("a")), "busybox")
    want(parse("otel/collector:0.1@" + digest("a"))[:2] == ("registry-1.docker.io", "otel/collector"), "otel")
    want(parse("registry.k8s.io/kubectl:v1.37.0@" + digest("a"))[:2] == ("registry.k8s.io", "kubectl"), "k8s")
    want(parse("public.ecr.aws/karpenter/controller:1.15.1@" + digest("a"))[:2]
         == ("public.ecr.aws", "karpenter/controller"), "ecr")

    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "karpenter.yaml"), "w").write(
            "kind: NodePool\nmetadata: {name: default}\nspec:\n  template:\n    spec:\n      requirements:\n"
            "        - {key: kubernetes.io/arch, operator: In, values: [arm64, amd64]}\n---\n"
            "kind: NodePool\nmetadata: {name: plain}\nspec: {template: {spec: {requirements: []}}}\n")
        need, _ = eks_platforms('  ami_type        = "AL2023_ARM_64_STANDARD"\n', [d])
        want(need == {"linux/arm64", "linux/amd64"}, "eks platforms from ami_type and NodePools: %s" % need)
        need, _ = eks_platforms('ami_type = "AL2023_ARM_64_STANDARD"\n', [tempfile.mkdtemp(dir=d)])
        want(need == {"linux/arm64"}, "eks platforms from ami_type alone: %s" % need)

    eks = {"linux/amd64", "linux/arm64"}
    a, b, c = "quay.io/x/a:1@" + digest("a"), "quay.io/x/b:1@" + digest("b"), "quay.io/x/c:1@" + digest("c")
    t = "throttled.example/x/t:1@" + digest("e")
    log = io.StringIO()
    out = lambda s: log.write(s + "\n")
    reg = Fake(waits=(0, 0))
    want(check([("kind", KIND_PLATFORMS, [a, b])], reg, out) == 0, "an amd64-only index passes kind")
    want(check([("eks", eks, [a])], reg, out) == 0, "a full index passes eks")
    want(check([("eks", eks, [b])], reg, out) == 1, "the v0.95.1 index fails eks")
    want("MISSING    eks  quay.io/x/b:1@sha256:bbbbbbbbbbbb: lists linux/amd64; eks nodes run linux/amd64, linux/arm64"
         in log.getvalue(), "the miss names what the index lists and what the nodes run")
    want(check([("kind", KIND_PLATFORMS, [c])], reg, out) == 1, "a single arm64 manifest fails kind")
    want(check([("eks", {"linux/arm64"}, [c])], reg, out) == 0, "a single arm64 manifest passes arm64 nodes")
    want(check([("eks", eks, [t])], reg, out) == 1, "a throttled registry fails, not passes")
    want(calls.get("https://throttled.example/v2/x/t/manifests/" + digest("e")) == 3, "a throttled request is tried 3 times")
    want(check([("eks", eks, ["quay.io/x/gone:1@" + digest("f")])], reg, out) == 1, "a digest the registry lacks fails")

    if fails:
        print(log.getvalue())
        print("selftest: FAILED: " + "; ".join(fails))
        return 1
    print("selftest: ok (amd64-only index fails eks and passes kind; arm64-only manifest read through its config; "
          "throttled registry tried 3 times and fails; node platforms read from ami_type and NodePools)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1:] == ["selftest"]:
        sys.exit(selftest())
    sys.exit(main(sys.argv[1:]))
