#!/usr/bin/env python3
"""pending-resources.py APP... | selftest - what each Argo CD Application waits on.

Argo CD 3 keeps a resource's health in its resource tree, not in the
Application (controller.resource.health.persist is off by default), so the
Application's .status.resources carries no health to read: on 22 November 2026
an install that waited 1500 s on platform-config, Synced and Degraded, printed
nothing about any of its resources. This reads each resource the Application
lists from the API server and prints the ones that say why it waits:

    <Kind> <namespace>/<name> sync OutOfSync
    <Kind> <namespace>/<name> health Degraded: <message>        (when persisted)
    <Kind> <namespace>/<name> Ready=False <reason>: <message>   (its own condition)
    <Kind> <namespace>/<name> not found

A condition counts when its type says readiness (Ready, Available,
Established, Programmed, Accepted) and its status is not True. At most LIMIT
lines per Application; it never fails, since it only explains a wait that has
already failed. `selftest` shows it the cases it exists for, without a cluster.
"""
import json
import subprocess
import sys

READY_TYPES = ("Ready", "Available", "Established", "Programmed", "Accepted")
LIMIT = 15


def kubectl_json(args):
    try:
        r = subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def one_line(text, width=200):
    return " ".join((text or "").split())[:width]


def report(app, get):
    """The lines that say what `app` (an Application object) waits on."""
    lines = []
    for r in (app.get("status") or {}).get("resources") or []:
        ref = f"{r.get('kind')} {r.get('namespace') or ''}/{r.get('name')}"
        if r.get("status") and r["status"] != "Synced":
            lines.append(f"{ref} sync {r['status']}")
        health = r.get("health") or {}
        if health.get("status") and health["status"] != "Healthy":
            lines.append(f"{ref} health {health['status']}: {one_line(health.get('message'))}".rstrip(": "))
            continue
        group = r.get("group") or ""
        what = f"{r.get('kind')}.{group}" if group else r.get("kind")
        args = ["get", what, r.get("name")] + (["-n", r["namespace"]] if r.get("namespace") else [])
        obj = get(args)
        if obj is None:
            lines.append(f"{ref} not found")
            continue
        for c in ((obj.get("status") or {}).get("conditions") or []):
            if c.get("type") in READY_TYPES and c.get("status") != "True":
                lines.append(f"{ref} {c.get('type')}={c.get('status')} {c.get('reason') or ''}: "
                             f"{one_line(c.get('message'))}".rstrip(": "))
    if len(lines) > LIMIT:
        lines = lines[:LIMIT] + [f"... and {len(lines) - LIMIT} more"]
    return lines


def selftest():
    def res(kind, name, ns="", group="", status="Synced", health=None):
        r = {"kind": kind, "name": name, "namespace": ns, "group": group, "status": status}
        if health:
            r["health"] = health
        return r

    app = {"status": {"resources": [
        res("ClusterSecretStore", "platform", group="external-secrets.io"),
        res("ClusterIssuer", "platform-ca", group="cert-manager.io"),
        res("ConfigMap", "settings", ns="argocd"),
        res("Gateway", "platform", ns="gateway", group="gateway.networking.k8s.io", status="OutOfSync"),
        res("Deployment", "old", ns="demo", group="apps", health={"status": "Degraded", "message": "Deadline\n exceeded"}),
        res("Secret", "gone", ns="demo"),
    ]}}
    objects = {
        ("ClusterSecretStore.external-secrets.io", "platform"): {"status": {"conditions": [
            {"type": "Ready", "status": "False", "reason": "InvalidProviderConfig", "message": "unable to validate store"}]}},
        ("ClusterIssuer.cert-manager.io", "platform-ca"): {"status": {"conditions": [
            {"type": "Ready", "status": "True", "reason": "KeyPairVerified"}]}},
        ("ConfigMap", "settings"): {"data": {}},
        ("Gateway.gateway.networking.k8s.io", "platform"): {"status": {"conditions": [
            {"type": "Accepted", "status": "True"}, {"type": "Programmed", "status": "Unknown", "reason": "Pending"},
            {"type": "ResolvedRefs", "status": "False"}]}},
    }
    calls = []

    def get(args):
        calls.append(args)
        return objects.get((args[1], args[2]))

    lines = report(app, get)
    want = [
        "ClusterSecretStore /platform Ready=False InvalidProviderConfig: unable to validate store",
        "Gateway gateway/platform sync OutOfSync",
        "Gateway gateway/platform Programmed=Unknown Pending",
        "Deployment demo/old health Degraded: Deadline exceeded",
        "Secret demo/gone not found",
    ]
    assert lines == want, lines
    assert ["get", "Gateway.gateway.networking.k8s.io", "platform", "-n", "gateway"] in calls, calls
    assert not any(a[1] == "Deployment.apps" for a in calls), "a persisted health is not read again"
    many = {"status": {"resources": [res("Secret", f"s{i}", ns="x") for i in range(LIMIT + 3)]}}
    out = report(many, lambda a: None)
    assert len(out) == LIMIT + 1 and out[-1] == "... and 3 more", out
    assert report({}, get) == [] and report({"status": {}}, get) == []
    print("selftest: ok (a store Ready=False, a Gateway not Programmed and OutOfSync, a persisted Degraded health, "
          "a missing resource; Ready=True, other condition types and objects without conditions stay quiet)")
    return 0


def main(apps):
    for name in apps:
        app = kubectl_json(["-n", "argocd", "get", "applications.argoproj.io", name])
        if app is None:
            print(f"{name}: could not read the Application")
            continue
        for line in report(app, kubectl_json):
            print(line)
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "selftest":
        sys.exit(selftest())
    sys.exit(main(sys.argv[1:]))
