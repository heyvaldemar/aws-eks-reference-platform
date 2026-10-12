# 7. Velero file-system backup on kind and on EKS

- Status: accepted
- Date: 2026-10-11

## Context

A backup that has never been restored is a belief. The restore has to run on every change, which means on kind, at no cloud cost; and it should be the same mechanism a real restore on EKS would use.

## Decision

- Velero with Kopia file-system backup (`defaultVolumesToFsBackup: true`) on both kind and EKS. Snapshots are off.
- The target is an S3 bucket: on EKS a versioned bucket encrypted with the platform's KMS key, reached through Pod Identity; on kind a single SeaweedFS server in the cluster, with keys generated at bootstrap that exist only in the cluster. (MinIO's latest community release on GitHub dates from October 2025.)
- A nightly schedule backs up tenant namespaces and keeps 7 days.
- The helper Velero injects into a restored pod is configured to pass the tenant's admission policies.
- The e2e suite writes a marker into the demo backend's volume, backs up, deletes the namespace, restores, and reads the marker back through the Gateway. The status of the restore is not the test; the marker is.

## Consequences

- The daily drill is the real mechanism, not a stand-in.
- File-system backup is slower than an EBS snapshot for large volumes, and it reads through the node.
- Velero's node agent needs host access, so the `velero` namespace runs at the privileged Pod Security level; nothing else runs there.
- kind's default StorageClass makes `hostPath` volumes, which Velero skips without failing the backup. The first version of the drill restored "Completed" with an empty volume. The demo now asks for a `kind-local` class whose volumes Velero can copy, and the restore runbook warns about the trap.

## Alternatives

- **EBS snapshots through the CSI driver** (with the data mover for portability). Faster on EKS, but cannot run on kind, so the daily drill would test a different path from the real one.
- **AWS Backup for EKS.** Managed, but AWS-only and not something CI can exercise for free.

## How to explain this to a customer

Your applications are backed up every night, volumes included, to storage encrypted with your key. More importantly, the restore is rehearsed every day: a test writes data, deletes the whole application, restores it and checks the data came back. That rehearsal is how we found a case where the backup tool reported success while silently skipping the data, and it is why we trust the restore, not the status message.
