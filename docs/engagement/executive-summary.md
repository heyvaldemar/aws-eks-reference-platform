# Executive summary

**Situation.** About 40 services run as Docker Compose stacks on a dozen virtual machines. Every machine is configured by hand and no backup has ever been restored. The company cannot show an auditor which images run or how long a restore takes.

**Proposal.** Move the services onto this platform on Amazon EKS, one team at a time. Each team gets its own namespace and hostname, and deploys by pull request. The platform owns what should not be every team's problem, from admission rules to backups and upgrades.

**What changes for the auditor's two questions.**

- *Which code runs?* Every running image is referenced by digest, and the API server refuses one that is not. Signature and scan checks are added from [kubernetes-supply-chain-admission](https://github.com/heyvaldemar/kubernetes-supply-chain-admission) in phase 3.
- *How long does a restore take?* A drill deletes a tenant and its volume, restores it from backup and reads back data written before the backup. It runs on every change today; in the engagement it runs on the customer's cluster and its duration is recorded.

**What it costs.** About $235 a month for the cluster before workloads, and about $280 to $480 a month for the 40 services' nodes depending on how much runs on Spot; [sizing](sizing.md) shows the arithmetic. Traffic and logs come on top; phase 1 measures them.

**Timeline.** Twelve to sixteen weeks to the last wave, in five phases with exit criteria ([adoption plan](adoption-plan.md)). A pilot team goes first. The rest move in waves, each with its Compose stack kept warm for rollback.

**Risks the sponsor should know about.**

- The platform is proven daily on kind. Its EKS path is validated Terraform that has not yet run in a real account; phase 1 is where that happens, against the same suite.
- Stateful services move last. A database that runs on a VM today may belong in a managed service rather than in the cluster; discovery decides that service by service.
- Teams have to learn a pull request instead of SSH. The pilot measures how long that takes before the waves start.

**Decisions needed from the customer before phase 1:** who owns the AWS account, which identity provider engineers use, the RPO and RTO per service tier, and the monthly cost ceiling.
