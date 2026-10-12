# 6. Every image by digest, every pin watched

- Status: accepted
- Date: 2026-10-11

## Context

A tag is a name that can be moved to different bytes after the image was reviewed. Charts reference their images by tag, and some images are passed to operators as flags, never appearing in an `image:` field. Pins, once set, go stale without a sound.

## Decision

- Each add-on has a `platform/values/<add-on>/images.yaml` that overrides every image the chart would run with `tag@sha256:` or the chart's digest field, including images passed as flags (the Prometheus operator's config reloader and Thanos sidecar, cert-manager's ACME solver).
- `scripts/check-images.py` scans every string of every rendered object, not only `image:` fields, and fails on any reference without a digest. The e2e suite checks every running pod as well.
- `tools.lock` pins each CLI tool by version and sha256 per platform; `ci-images.pins` pins CI containers by digest; GitHub Actions are pinned by commit SHA.
- `scripts/check-freshness.py` runs weekly and reports, without changing anything: a chart with a newer version, a tag that now points at different bytes, a tool or provider behind its latest release, and a chart whose default image moved ahead of the pin in `images.yaml`.

## Consequences

- What was tested is what runs, down to the byte.
- A chart upgrade is two changes, the chart version and its image pins; the upgrade runbook shows how to list the new defaults.
- A freshness failure is a to-do, not an outage: fleet triage opens the bump and the bump passes the same gates as any change.
- `images.yaml` can pin an image newer than the chart's default (Velero v1.18.4 over the chart's v1.18.2). The freshness check treats newer as deliberate and older as behind.

## Alternatives

- **Tags with `imagePullPolicy: Always`.** Pulls whatever the tag points at today.
- **Admission-time digest mutation** (Kyverno resolving tags to digests). Pins at deploy time, but what CI rendered and what runs can still differ.
- **Renovate.** Can update many of these pins; the fleet already has triage that reads failed freshness runs, so a second bot would duplicate it.

## How to explain this to a customer

Everything that runs is identified by a fingerprint of its exact contents, not by a version label someone could reuse. So what passed testing is byte for byte what runs in your cluster. A weekly job tells you which of those fingerprints have newer upstream releases, and every update goes through the same tests before it reaches a cluster.
