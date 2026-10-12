# 4. Gateway API, implemented by Envoy Gateway

- Status: proposed
- Date: 2026-10-11

## Context

Traffic enters through one place that terminates TLS and routes by host and path. The Ingress API is frozen; the Gateway API is its successor and separates the infrastructure owner (Gateway) from the application owner (HTTPRoute). The same objects have to work on kind, EKS and, next, GKE and AKS.

## Decision

One `GatewayClass` (`envoy`), one `Gateway` in its own namespace with an HTTPS listener for `*.<domain>` and an HTTP listener that only redirects. Routes attach only from namespaces labelled as tenants. Envoy Gateway runs the data plane; an `EnvoyProxy` resource decides how it is exposed: a ClusterIP Service on kind, an internet-facing Network Load Balancer with IP targets on EKS (made by the AWS Load Balancer Controller). cert-manager issues the wildcard certificate: the platform's own CA on kind, Let's Encrypt over Route 53 DNS-01 on EKS.

## Consequences

- An application team writes an HTTPRoute and nothing cloud-specific. The demo's route is the same file on every cluster; only the hostname is patched in.
- The Gateway refuses routes from namespaces that are not tenants, which is a boundary Ingress cannot express.
- TLS terminates at Envoy, inside the cluster, so the load balancer is a plain layer-4 NLB.
- One more controller to run and upgrade (Envoy Gateway), and one NLB per cluster rather than per application.

## Alternatives

- **Ingress with ingress-nginx.** Feature-frozen API, annotations per controller for anything beyond host and path.
- **The AWS Load Balancer Controller's own Gateway API support.** Provisions AWS load balancers per Gateway directly; works only on AWS, which defeats the shared core.
- **Cilium's Gateway API.** Attractive once Cilium is the CNI. On EKS that means replacing the VPC CNI, a larger decision than ingress.

## How to explain this to a customer

There is one front door per cluster, and it speaks the Kubernetes standard for routing, so your teams describe their routes the same way on AWS, Google Cloud, Azure or a laptop. Certificates are issued and renewed automatically. Only namespaces you have marked as tenants can publish a hostname, so a test namespace cannot quietly take over a production address.
