# Tenant template

Copy this directory to `apps/<team>/` and follow docs/onboarding-a-tenant.md.
The ApplicationSets in platform/appsets/tenants.yaml and
tenant-guardrails.yaml ignore `_template` itself; every other directory under
apps/ becomes a tenant. The namespace is not in here: the platform creates
it, with its labels, its quota and the tenant's Argo CD project
(platform/tenant).
