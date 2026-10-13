# kubectl-tenant

Onboards a team the way [onboarding a tenant](../../docs/onboarding-a-tenant.md) describes, and checks its manifests before review. On `PATH` it is a kubectl plugin.

```bash
(cd tools/kubectl-tenant && go build -o ../../.cache/bin/kubectl-tenant .)
export PATH="$PWD/.cache/bin:$PATH"

kubectl tenant new payments     # apps/payments from apps/_template
kubectl tenant check payments   # what admission would refuse, from the files alone
```

- `new` refuses the names the tenant chart refuses, before it writes anything: not a DNS label, `kube-` or `tenant-` first, or one of the names reserved in `platform/tenant/values.yaml`, which it reads so the two lists cannot drift apart.
- `check` reads `apps/<name>/base` and reports what the platform's admission policies (`policies/`) and Pod Security `restricted` would refuse: an image without a digest, missing CPU or memory requests, no memory limit, missing readiness or liveness probes, a privileged container, the host network. Exit status 1 when there is a finding.

The tests rebuild `apps/team-b`, which was made by hand from the template, and require the tool's result to match it; read the real reserved list; and plant each violation `check` exists for. CI runs them in the Verification workflow (`kubectl-tenant` job), with `gofmt` and `go vet`.
