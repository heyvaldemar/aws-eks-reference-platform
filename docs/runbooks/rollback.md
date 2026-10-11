# Rollback

A cluster runs exactly one commit of this repository: the `platform_revision` annotation on its Argo CD cluster Secret and the root Application's `targetRevision`. Rolling back is moving it to an earlier one.

## The whole platform

```bash
# what it runs now
kubectl -n argocd get secret in-cluster -o jsonpath='{.metadata.annotations.platform_revision}'; echo

# back to the previous release
PLATFORM_REVISION=v1.0.0 ./bootstrap/bootstrap.sh kind   # or eks
make wait
```

Argo CD syncs every Application to the older revision, charts and values included.

## What a rollback cannot undo

- **CRDs.** A newer chart may have upgraded a CustomResourceDefinition. Argo CD applies the older CRD, but objects already stored in a newer API version stay in it. Check the component's notes before rolling back across a CRD change.
- **Data migrations.** A component that migrated its own data (Argo CD's Redis cache is fine; a database is not) does not migrate it back.
- **Velero backups** taken by the newer version of Velero can be newer than the older Velero reads.

When one of these applies, restore from a backup taken before the upgrade instead ([restore.md](restore.md)).

## One component only

Pause the generator for it, then pin the Application by hand:

```bash
kubectl -n argocd patch application kyverno --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application kyverno --type json \
  -p '[{"op":"replace","path":"/spec/sources/0/targetRevision","value":"3.9.0"}]'
```

The ApplicationSet leaves `syncPolicy` alone (its `ignoreApplicationDifferences`), but it will put `targetRevision` back on its next reconcile. That is deliberate: a hand-pinned component is an incident, not a state. Revert the version in Git the same day.
