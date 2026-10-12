# Restore

Velero backs up the demo tenant every night at 03:00 UTC (`schedules.daily-tenants` in `platform/values/velero/common.yaml`, kept 7 days) and copies its volumes file by file with Kopia. The kind e2e run does exactly this procedure every day: write a marker, back up, delete the namespace, restore, read the marker back. While this repository was being built it caught a restore that reported success over an empty disk. Status is not data.

## Restore a namespace

1. **Stop Argo CD from recreating it.** Otherwise it rebuilds the namespace empty the moment you delete it, and the restore collides with it. A tenant has two Applications: `tenant-<team>` owns the namespace, its quota and its project; `<team>` owns what runs inside. Pause both.

   ```bash
   for app in tenant-demo demo; do
     kubectl -n argocd patch application "$app" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
   done
   ```

2. **Pick the backup.**

   ```bash
   kubectl -n velero get backups --sort-by=.metadata.creationTimestamp
   kubectl -n velero get backup <name> -o jsonpath='{.status.phase} {.status.progress}'; echo
   kubectl -n velero get podvolumebackups -l velero.io/backup-name=<name>
   ```

   A backup with no PodVolumeBackup for a volume did not copy that volume. Read [the hostPath note](#volumes-velero-skips) before trusting it.

3. **Remove what is there**, if anything is.

   ```bash
   kubectl delete namespace demo --wait=true
   ```

4. **Restore.**

   ```bash
   kubectl apply -f - <<EOF2
   apiVersion: velero.io/v1
   kind: Restore
   metadata:
     name: demo-$(date +%Y%m%d-%H%M)
     namespace: velero
   spec:
     backupName: <name>
     includedNamespaces: [demo]
   EOF2
   kubectl -n velero get restore -w
   ```

5. **Check the data, not the status.** `Completed` means Velero did what it was asked; it does not mean the volume held what you needed.

   ```bash
   kubectl -n demo rollout status statefulset/backend
   ```

   Then read something you know was there, through the Gateway (`make tunnel`).

6. **Give the namespace back to Argo CD**, the namespace's owner first.

   ```bash
   for app in tenant-demo demo; do
     kubectl -n argocd patch application "$app" --type merge \
       -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   done
   ```

   Both should report `Synced` without changing anything: the restored objects are the ones in Git.

## Volumes Velero skips

Velero's file-system backup skips `hostPath` volumes without failing the backup. kind's default StorageClass makes hostPath volumes, which is why the demo backend asks for `kind-local` (`manifests/overlays/kind/storageclass.yaml`). On EKS every volume is an EBS volume and is backed up.

## A restore that is refused

Restored pods go through admission like any other. The helper Velero injects to write volume data back is configured to pass the tenant's policies (pinned image, restricted security context, requests and limits) in `platform/values/velero/images.yaml`. A restore that ends `PartiallyFailed` with admission errors usually means that configuration and a policy no longer agree:

```bash
kubectl -n velero get restore <name> -o jsonpath='{.status.errors}'; echo
kubectl -n demo get events --field-selector type=Warning
```
