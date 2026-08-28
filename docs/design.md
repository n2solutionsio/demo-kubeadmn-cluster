# Design document

## What was built

A three-node Kubernetes cluster installed with `kubeadm`, serving a static nginx
site over HTTPS. The application is deployed by a namespace-scoped user
authenticated with a client certificate issued through the Kubernetes CSR API —
not by a cluster administrator.

```
                          browser
                             │  https://nginx.demo.…
                             ▼
                   ┌─────────────────────┐
                   │  Gateway (Cilium)   │  10.30.30.30, announced on the
                   │  :80 → 301 → :443   │  LAN by Cilium L2
                   └──────────┬──────────┘
                              │  HTTPRoute
                              ▼
                   ┌─────────────────────┐
                   │  nginx Service      │  ← deployed by nginx-deployer,
                   │  + Deployment (x2)  │    a non-admin identity
                   └─────────────────────┘

  cert-manager ──issues──▶ *.demo.homelab…  (Let's Encrypt, DNS-01)
```

| Layer | Choice |
| --- | --- |
| Hosts | 3 × Ubuntu 24.04 VMs — 1 control plane, 2 workers |
| Cluster | kubeadm, Kubernetes 1.33 |
| Networking | Cilium 1.19, kube-proxy replaced |
| Ingress | Gateway API, Cilium as controller |
| Certificates | cert-manager → Let's Encrypt via DNS-01 |
| Identity | Kubernetes CSR API, client certificates |

---

## How the environment is provisioned

The three VMs run on a Proxmox host on my own hardware, declared as
infrastructure-as-code and applied through a pull-request pipeline: plan runs
automatically on every PR, apply requires a human, and CI holds no stored
credentials.

None of that is a dependency of this solution — the cluster needs three
Debian-family hosts and nothing more. See
[`infrastructure.md`](infrastructure.md) for the detail, the portability
caveats, and extracts from the configuration.

---

## Design decisions

### Node preparation is automated; cluster bootstrap is not

Host preparation — container runtime, kernel modules, sysctls, swap, staging
packages — is an Ansible collection
([`n2solutions.kubeadm`](https://github.com/n2solutionsio/ansible-collection-kubeadm),
public, MIT). It is idempotent and was verified to run twice with no changes on
the second pass.

`kubeadm init` and `kubeadm join` are run by hand, from a documented runbook.

The split is deliberate. Preparation is repeatable and uninteresting (to some), which is
what automation is for. Bootstrap involves join tokens that expire, an ordering
constraint between control plane and workers, and a CA that does not exist until
the first command completes. Automating that hides exactly the part worth
understanding — and the exercise asks for the steps used, not a script that
conceals them.

**Trade-off:** cluster creation is not reproducible by a single command. For a
production fleet I would push the bootstrap into automation too, most likely
Cluster API, and accept the loss of visibility.

### Gateway API rather than Ingress

The community `ingress-nginx` controller was **retired in March 2026** — the
repository is archived and read-only, with no further releases and no security
patches. Its intended successor, InGate, did not mature and is also being
retired. Gateway API is the endorsed replacement.

Deploying an unmaintained, unpatched ingress controller on a cluster being
evaluated for security would be difficult to defend.

Gateway API also models the ownership split this exercise is about. `Gateway` is
infrastructure; `HTTPRoute` is an application concern. Ingress conflates the two
into one object, which makes "the app team can publish a route but cannot change
TLS" awkward to express.

**Trade-off:** more objects than an Ingress — `GatewayClass`, `Gateway`,
`HTTPRoute` — and a smaller body of community examples to draw on.

### Cilium as the Gateway controller

Cilium is already the CNI, and it implements Gateway API core conformance. Using
it means no second controller to deploy, monitor, or explain.

**Trade-off:** worth naming honestly. Published benchmarks show Cilium's Gateway
API implementation can be fragile under high route churn or heavy connection
load, entering states where traffic drops until components restart. It is also
tied into the CNI rather than being a standalone controller, so it behaves
differently from what people expect. Neither matters at three nodes and one
site; both would need evaluating at scale.

### kube-proxy replaced, decided at bootstrap

`kubeadm init --skip-phases=addon/kube-proxy`, with Cilium running
`kubeProxyReplacement=true`. eBPF-based service handling avoids iptables rule
growth, and Cilium's Gateway API support requires it.

This had to be decided before the cluster was created. Removing kube-proxy from a
running cluster is considerably messier than never installing it — a good example
of a decision that is cheap at the start and expensive later.

### DNS-01 for certificates, not HTTP-01

The site is served on a private address that Let's Encrypt cannot reach, so an
HTTP-01 challenge is impossible. DNS-01 proves control of the DNS zone instead,
which yields a genuinely trusted certificate for a host that is never exposed to
the internet.

It also permits wildcards — Let's Encrypt only issues those via DNS-01 — so one
certificate covers `*.demo.homelab.n2solutions.io` and every future application
in this cluster, rather than triggering an issuance per hostname.

**Trade-off:** cert-manager needs a DNS provider API token with write access to
the zone. That is a real credential with real blast radius, and it lives in the
cluster.

### Per-cluster DNS zones

Each cluster owns a subdomain: `*.demo.…` for this one, `*.hub.…` for the
existing k3s cluster. A wildcard at that depth is more specific than a broader
one, so it wins resolution without a record per application.

---

## Authentication and authorization

### How the user is authenticated

**Kubernetes has no user objects.** There is no `User` resource to create, list,
or delete. An identity is a client certificate signed by the cluster's CA, and
the API server reads it directly:

- **`CN`** (Common Name) becomes the **username** — `nginx-deployer`
- each **`O`** (Organization) becomes a **group** — `nginx-deployers`

The flow:

1. The user generates a private key and a CSR locally. **The key never leaves
   their machine** — it *is* the identity, so it is never committed and never
   transmitted.
2. The CSR is submitted as a `CertificateSigningRequest` with
   `signerName: kubernetes.io/kube-apiserver-client`.
3. An **administrator approves it**. This is the only control point in the
   entire flow.
4. The cluster CA signs it. The user builds a kubeconfig from the certificate.

`kubectl auth whoami` then reports the username and groups, derived entirely from
the certificate subject. Nothing else was configured.

### How access is granted

A namespaced `Role` in `nginx-demo`, bound to the **group** `nginx-deployers`.

Binding to a group rather than a username means a second person gets access by
being issued a certificate with the same `O` — no manifest change. Binding to a
`CN` would need a new `RoleBinding` per person.

What the Role grants: deployments, replicasets, pods, services, configmaps, pod
logs, events, and HTTPRoutes.

**What it withholds is the more interesting half:**

| Withheld | Reason |
| --- | --- |
| `secrets` | cert-manager writes the site's TLS **private key** into this namespace. A deployer who can read secrets can exfiltrate the certificate |
| `pods/exec` | A shell inside a container sidesteps every other control |
| `pods/portforward` | Tunnels past the Gateway and any network policy |
| `gateways` | Shared infrastructure. A deployer may attach a route but must not swap the certificate or hijack a listener |
| anything cluster-scoped | No `ClusterRole` is bound, so nodes and namespaces are invisible |

No `ClusterRoleBinding` exists for this identity. Its authority stops at the
namespace boundary.

---

## Where this model breaks down

This is the part worth dwelling on, because the mechanism is elegant and its
operational properties are poor.

### Certificates cannot be revoked

Kubernetes has **no certificate revocation list and no deny list**. Once the CA
signs a certificate it is valid until it expires!

If a deployer leaves the company, or a laptop is stolen, there is no Kubernetes
operation that withdraws that access. The options are:

- Wait for expiry — hence the deliberately short 7-day lifetime here
- Delete the `RoleBinding`, which revokes *everyone* in that group, not one person
- Rotate the cluster CA, which invalidates every certificate including the
  control plane's

None of these is "revoke this person's access." That is the central weakness.

### There is no record of who holds credentials

Because there is no user object, the cluster cannot answer "who can deploy to
this namespace?" It can only answer "what does the group `nginx-deployers`
have?" Mapping that group to actual people happens somewhere outside Kubernetes —
in this case, nowhere.

### Credentials live outside the cluster and outside version control

Everything else in this submission is in git. The user's key, certificate and
kubeconfig cannot be, and are `.gitignore`d. They exist on one laptop, with no
tracking of where copies have been made.

### Approval does not scale

Each new user requires an administrator to run `kubectl certificate approve`.
That is a reasonable control at three users and unworkable at three hundred.

### Group membership is baked into the certificate

Changing someone's groups means issuing a new certificate. There is no way to
adjust an existing identity's group membership — the subject is signed.

### What production does instead

Delegate authentication to an external identity provider — OIDC, or a system
like Teleport that issues short-lived credentials tied to a real identity, keeps
an audit trail of who accessed what, and can revoke immediately. The Kubernetes
RBAC model stays exactly as designed here; only the identity layer changes.

The RBAC work in this exercise is not wasted by that swap. `Role` and
`RoleBinding` bind to groups, and an OIDC provider supplies groups just as a
certificate does. **The authorization model is sound; the authentication model is
what needs replacing.**

---

## Cluster management observations

### A single control plane

One control plane node, so etcd has no quorum and the API server no redundancy.
Correct for a demo, unacceptable in production, where three (or more) control plane nodes
would be the minimum.

### Split-horizon DNS caused the one genuinely hard failure

The public DNS record was correct and every external resolver agreed. An internal
resolver held a broader wildcard for the parent domain that shadowed it, so
internal clients silently reached a *different cluster* — presenting as a 404
from an application that was working perfectly.

It took several rounds to find because the symptom pointed at the application,
the certificate, and the Gateway before the resolver. The lesson I learned is that two
systems with overlapping authority over the same namespace fail quietly rather
than loudly. The same class of problem is why the pod CIDR was deliberately
chosen not to overlap the other cluster's.

### Routes attach to every listener unless pinned

An `HTTPRoute` whose `parentRef` omits `sectionName` attaches to *all* listeners
on a Gateway. After adding an HTTP listener for redirects, the application route
attached to it too and served the site in cleartext, taking precedence over the
redirect. Everything reported healthy; the only signal was `curl` returning 200
on `http://`.

Both routes are now pinned with `sectionName`.

---

## Reproducing this

| Document | Covers |
| --- | --- |
| [`build-cluster.md`](build-cluster.md) | Node prep through to a working cluster |
| [`deploy-application.md`](deploy-application.md) | Platform, RBAC, CSR user, application, DNS |
| [`../manifests`](../manifests) | Everything applied, as tracked files |

Manifests are applied with `kubectl apply -k` and carry ArgoCD sync-wave
annotations, so an app-of-apps root can adopt them without restructuring.

The only value not in the repository is the DNS provider API token.

---

## Advanced objectives not implemented

The brief lists two optional objectives beyond the minimum requirements. Neither
is implemented here, and the reason is time rather than approach — I chose to make
the required work solid rather than start extras I could not finish and verify.

### GitOps with ArgoCD

Not deployed. The repository is, however, laid out for it rather than
retrofitted later:

- every directory under `manifests/` carries a `kustomization.yaml`, so an
  ArgoCD `Application` points at the same path that `kubectl apply -k` uses
  today, unchanged
- resources carry `argocd.argoproj.io/sync-wave` annotations, so ordering that
  currently depends on running steps in sequence — issuer before certificate,
  certificate before Gateway — is already declared
- an `argocd/` directory is scaffolded for an app-of-apps root

Adding it should be a matter of installing ArgoCD and pointing a root
`Application` at this repository, with no manifest changes.

Worth noting what could *not* be managed that way: the CNI, the Gateway API
CRDs, and the cluster bootstrap. ArgoCD needs a working network to reach the API
server, so it cannot reconcile the thing it depends on. That bootstrap layer
stays imperative regardless.

I run ArgoCD in the neighbouring cluster in this environment — see
[`homelab-gitops`](https://github.com/n2solutionsio/homelab-gitops), where it
manages the platform and application workloads including cert-manager, monitoring
and external-secrets. The gap here is time, not familiarity.

### Teleport on the cluster

Not deployed. This one is directly relevant to the weaknesses described above:
the entire *Where this model breaks down* section argues that certificate-based
user management has no revocation, no record of credential holders, and manual
approval that does not scale — and short-lived, identity-backed credentials are
the answer to all three.

Deploying it would have changed the demo from "here is why this model is
limited" to "here is the limitation and here is what replaces it." That is the
obvious next step, and the RBAC built here carries over unchanged: `Role` and
`RoleBinding` bind to groups, and an external identity provider supplies groups
just as a certificate subject does.

---

## What I would do differently

- **Three control plane nodes** for etcd quorum.
- **An external identity provider** rather than client certificates, for the
  revocation and audit reasons above.
- **GitOps from the start.** ArgoCD would manage everything except the bootstrap
  layer — the CNI cannot be reconciled by a controller that needs the CNI to
  reach the API server.
- **Network policy.** The namespace currently has none; a default-deny with
  explicit allows would match the least-privilege approach taken with RBAC.
- **Automated certificate rotation for users.** Seven-day certificates are the
  right instinct but create a manual renewal burden that nothing currently
  handles.
