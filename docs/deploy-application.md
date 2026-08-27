# Deploying the application

Takes a working kubeadm cluster and adds the platform services and access
control needed to run an application, then deploys it.

Prerequisite: a cluster built per [`build-cluster.md`](build-cluster.md).

Every command runs from your own machine. Run one block at a time and check the
output. **If it does not match, stop** — later steps assume earlier ones worked.

## What this builds

```
                          browser
                             │  https://nginx.demo.…
                             ▼
                     ┌───────────────┐
                     │    Gateway    │  LoadBalancer address,
                     │  (Cilium)     │  announced on the LAN by Cilium L2
                     └───────┬───────┘
                             │  HTTPRoute
                             ▼
                     ┌───────────────┐
                     │ nginx Service │
                     │  + Deployment │  ← deployed by a scoped, non-admin user
                     └───────────────┘

   cert-manager ──issues──▶ TLS certificate, via Let's Encrypt DNS-01
```

## Why these choices

| Decision | Reasoning |
|---|---|
| **Gateway API, not Ingress** | The community `ingress-nginx` controller was retired in March 2026 — archived, no security patches. Gateway API is the endorsed successor |
| **Cilium as the Gateway controller** | Already the CNI, so no additional controller to run or explain. Conformant on Gateway API core |
| **LoadBalancer + L2 announcement** | Gives the Gateway a stable LAN address, so DNS and the certificate have something durable to point at |
| **DNS-01 rather than HTTP-01** | The site is on a private address that Let's Encrypt cannot reach. Proving control of DNS instead yields a genuinely trusted certificate on a host that is never exposed |

Applied manifests live in [`../manifests`](../manifests) and are applied from the
repository, not pasted — so what ran is what is committed.

---

## Step 1 — Gateway API CRDs

These define `Gateway`, `HTTPRoute` and friends. They must exist **before**
Cilium's Gateway controller starts, or it finds nothing to reconcile and no
`GatewayClass` appears.

The version is not interchangeable: Cilium 1.19 targets Gateway API **v1.4.1**.
Newer CRDs paired with an older Cilium fail in confusing ways.

```bash
kubectl config use-context demo-kubeadm

BASE=https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd
for c in standard/gateway.networking.k8s.io_gatewayclasses.yaml \
         standard/gateway.networking.k8s.io_gateways.yaml \
         standard/gateway.networking.k8s.io_httproutes.yaml \
         standard/gateway.networking.k8s.io_referencegrants.yaml \
         standard/gateway.networking.k8s.io_grpcroutes.yaml \
         experimental/gateway.networking.k8s.io_tlsroutes.yaml; do
  kubectl apply --server-side -f "$BASE/$c"
done

kubectl get crd | grep -c gateway.networking.k8s.io
```

**Expected:** `6`

---

## Step 2 — Enable Gateway API and L2 announcements in Cilium

Two settings, and both are needed:

- `gatewayAPI.enabled` runs the Gateway controller
- `l2announcements.enabled` makes an assigned LoadBalancer address answerable on
  the network. Without it the address is allocated but never announced, so the
  Service shows an `EXTERNAL-IP` that nothing can reach — a genuinely puzzling
  failure, because everything looks correct

```bash
cilium upgrade \
  --set gatewayAPI.enabled=true \
  --set l2announcements.enabled=true
```

Confirm the upgrade preserved the original settings:

```bash
helm get values cilium -n kube-system
```

**Expected:** still lists `kubeProxyReplacement: true`, `k8sServiceHost`, and the
`ipam` block, **plus** the two new settings. **If `kubeProxyReplacement`
disappeared, stop** — the cluster has no service proxy.

```bash
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s
cilium status --wait
```

**Expected:** all `OK`, DaemonSet 3/3.

```bash
kubectl get gatewayclass
```

**Expected:**

```
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       30s
```

**`ACCEPTED: True` is the gate.** If it is `False` or absent, stop — usually a
CRD version mismatch from Step 1.

---

## Step 3 — Address pool for LoadBalancer services

The Gateway asks for a `LoadBalancer` Service. On a bare-metal cluster nothing
provides one by default, so Cilium is given a range to allocate from and told to
announce it.

Pick a range that is free on your network — outside any DHCP pool and clear of
statically assigned hosts. The committed values sit between the node addresses
and the start of DHCP.

```bash
kubectl apply -k manifests/infrastructure/cilium-lb
kubectl get ciliumloadbalancerippool
```

**Expected:**

```
NAME        DISABLED   CONFLICTING   IPS AVAILABLE   AGE
demo-pool   false      False         10              5s
```

`CONFLICTING: False` matters — `True` means the range overlaps something Cilium
already knows about.

> The two resources use different API versions: `CiliumLoadBalancerIPPool` has
> graduated to `cilium.io/v2`, while `CiliumL2AnnouncementPolicy` is still
> `v2alpha1` in Cilium 1.19.

---

## Step 4 — Install cert-manager

```bash
CM_VER=$(curl -s https://api.github.com/repos/cert-manager/cert-manager/releases/latest \
  | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
echo "installing cert-manager $CM_VER"

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CM_VER}/cert-manager.yaml

kubectl -n cert-manager rollout status deployment/cert-manager --timeout=300s
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=300s
kubectl -n cert-manager get pods
```

**Expected:** three pods `Running` — `cert-manager`, `cert-manager-cainjector`,
`cert-manager-webhook`.

The webhook matters: until it is ready, creating a `ClusterIssuer` fails
validation. Wait for it rather than pressing on.

---

## Step 5 — Cloudflare API credentials

cert-manager proves control of the DNS zone by creating a TXT record, so it needs
a Cloudflare token with **Zone:DNS:Edit** on the zone.

**This is a secret and is deliberately not in the repository.** Everything else
here is committed; this one value is supplied at apply time.

```bash
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$(op read 'op://homelab/cloudflare-dns/api-token')"

kubectl -n cert-manager get secret cloudflare-api-token
```

Substitute your own retrieval if you do not use the 1Password CLI. Avoid typing
the token directly into the command — it lands in your shell history.

**Expected:** the secret listed with `DATA: 1`.

---

## Step 6 — ClusterIssuer

```bash
kubectl apply -k manifests/infrastructure/cert-manager
kubectl get clusterissuer letsencrypt-production
```

**Expected:** `READY: True` within a minute.

If `False`:

```bash
kubectl describe clusterissuer letsencrypt-production
```

The cause is nearly always the token secret — wrong name, wrong key, or
insufficient Cloudflare permissions.

---

## Platform checkpoint

The platform is ready, though nothing is deployed on it yet.

```bash
kubectl get gatewayclass
kubectl get ciliumloadbalancerippool
kubectl get clusterissuer
```

**Expected:** `cilium` accepted, `demo-pool` not conflicting, issuer ready.

---

## Step 7 — Namespace and access control

Creates the namespace, a least-privilege `Role`, and a `RoleBinding` targeting
the group `nginx-deployers`.

```bash
kubectl apply -k manifests/rbac
kubectl -n nginx-demo get role,rolebinding
```

**Expected:** `nginx-deployer` role and rolebinding.

Read [`manifests/rbac/role.yaml`](../manifests/rbac/role.yaml) before moving on —
the comments record what is withheld and why, which is the substance of this
exercise. In short: no `secrets` (the namespace holds the site's TLS private
key), no `pods/exec` or `pods/portforward` (both bypass the Gateway and any
network policy), and no ability to modify the `Gateway` itself.

---

## Step 8 — Gateway and certificate

Applied by the **administrator**, not the deployer. Doing this now gives
cert-manager time to complete the DNS-01 challenge while you set up the user.

```bash
kubectl apply -k manifests/infrastructure/gateway
kubectl -n nginx-demo get certificate,gateway
```

Issuance takes a few minutes — cert-manager writes a TXT record, waits for DNS
to propagate, then Let's Encrypt validates it.

```bash
kubectl -n nginx-demo wait --for=condition=Ready certificate/demo-wildcard-tls --timeout=600s
```

**Expected:** `certificate.cert-manager.io/demo-wildcard-tls condition met`

If it stalls, watch the chain of objects it creates:

```bash
kubectl -n nginx-demo describe certificate demo-wildcard-tls
kubectl -n nginx-demo get challenge
```

A `challenge` stuck `pending` is almost always the Cloudflare token lacking
**Zone:DNS:Edit** on the zone.

Once the certificate is ready, the Gateway gets an address:

```bash
kubectl -n nginx-demo get gateway demo-gateway
```

**Expected:** `PROGRAMMED: True` and an `ADDRESS` from `10.30.30.30–39`.
**Note that address — you need it for DNS in Step 12.**

---

## Step 9 — Create a user with a Certificate Signing Request

Kubernetes has no user objects. An identity is a signed client certificate: the
**Common Name becomes the username**, and each **Organization becomes a group**.
The cluster's own CA signs it through the CSR API.

Generate a key and request. **The key never leaves this machine and is never
committed** — it *is* the identity.

```bash
mkdir -p credentials && cd credentials

openssl genrsa -out nginx-deployer.key 2048
openssl req -new -key nginx-deployer.key -out nginx-deployer.csr \
  -subj "/CN=nginx-deployer/O=nginx-deployers"

cd ..
```

`CN=nginx-deployer` is who they are; `O=nginx-deployers` is the group the
`RoleBinding` grants access to.

Submit it:

```bash
CSR_B64=$(base64 < credentials/nginx-deployer.csr | tr -d '\n')
sed "s|\${CSR_B64}|${CSR_B64}|" manifests/rbac/csr-template.yaml | kubectl apply -f -
kubectl get csr nginx-deployer
```

**Expected:** `CONDITION: Pending`

Nothing is signed until an administrator approves it — that approval is the
control point:

```bash
kubectl certificate approve nginx-deployer
kubectl get csr nginx-deployer
```

**Expected:** `CONDITION: Approved,Issued`

Extract the signed certificate:

```bash
kubectl get csr nginx-deployer -o jsonpath='{.status.certificate}' \
  | base64 -d > credentials/nginx-deployer.crt

openssl x509 -in credentials/nginx-deployer.crt -noout -subject -dates
```

**Expected:** `subject=CN=nginx-deployer, O=nginx-deployers`, valid for 7 days.

That expiry is deliberate, and worth calling out in the demo: **Kubernetes cannot
revoke a client certificate.** There is no CRL and no deny list. A short lifetime
is the only bound on how long a leaked credential stays usable.

---

## Step 10 — Build the user's kubeconfig

```bash
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > credentials/ca.crt

SERVER=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
KCFG=credentials/nginx-deployer.kubeconfig

kubectl config set-cluster demo-kubeadm \
  --server="$SERVER" --certificate-authority=credentials/ca.crt \
  --embed-certs=true --kubeconfig="$KCFG"

kubectl config set-credentials nginx-deployer \
  --client-certificate=credentials/nginx-deployer.crt \
  --client-key=credentials/nginx-deployer.key \
  --embed-certs=true --kubeconfig="$KCFG"

kubectl config set-context nginx-deployer \
  --cluster=demo-kubeadm --user=nginx-deployer \
  --namespace=nginx-demo --kubeconfig="$KCFG"

kubectl config use-context nginx-deployer --kubeconfig="$KCFG"
```

Confirm the cluster recognises the identity:

```bash
kubectl --kubeconfig=credentials/nginx-deployer.kubeconfig auth whoami
```

**Expected:**

```
ATTRIBUTE   VALUE
Username    nginx-deployer
Groups      [nginx-deployers system:authenticated]
```

The username and group come straight from the certificate's subject — nothing
else was configured.

---

## Step 11 — Prove least privilege

This is the part worth demonstrating live. It shows exactly where the boundary
sits, in seconds.

```bash
KCFG=credentials/nginx-deployer.kubeconfig

echo "--- should be allowed ---"
kubectl --kubeconfig=$KCFG auth can-i create deployments -n nginx-demo
kubectl --kubeconfig=$KCFG auth can-i create httproutes -n nginx-demo
kubectl --kubeconfig=$KCFG auth can-i get pods/log -n nginx-demo

echo "--- should be denied ---"
kubectl --kubeconfig=$KCFG auth can-i get secrets -n nginx-demo
kubectl --kubeconfig=$KCFG auth can-i update gateways -n nginx-demo
kubectl --kubeconfig=$KCFG auth can-i create deployments -n kube-system
kubectl --kubeconfig=$KCFG auth can-i list nodes
kubectl --kubeconfig=$KCFG auth can-i list namespaces
```

**Expected:** `yes` for the first three, `no` for all five others.

Each denial maps to a specific decision:

| Denied | Why it matters |
|---|---|
| `secrets` in its own namespace | The site's TLS private key lives here |
| `gateways` | Shared infrastructure — a deployer must not swap the certificate or hijack a listener |
| anything in `kube-system` | The Role is namespaced; no ClusterRole is bound |
| `nodes`, `namespaces` | Cluster-scoped resources are invisible to this identity |

Try one for real, so it is not just a policy query:

```bash
kubectl --kubeconfig=$KCFG get secrets -n nginx-demo
```

**Expected:** `Error from server (Forbidden): secrets is forbidden: User
"nginx-deployer" cannot list resource "secrets"`

---

## Step 12 — Deploy the application as that user

The requirement is that the application is deployed **by a user with role
access, not the default admin**. Note the `--kubeconfig` on every command.

```bash
KCFG=credentials/nginx-deployer.kubeconfig

kubectl --kubeconfig=$KCFG apply -k manifests/apps/nginx
kubectl --kubeconfig=$KCFG -n nginx-demo rollout status deployment/nginx --timeout=180s
kubectl --kubeconfig=$KCFG -n nginx-demo get pods,svc,httproute
```

**Expected:** two pods `Running`, the `nginx` Service, and the `nginx` HTTPRoute.

Confirm the route attached to the Gateway:

```bash
kubectl -n nginx-demo get httproute nginx -o jsonpath='{.status.parents[0].conditions[*].type}{"\n"}'
```

**Expected:** `Accepted ResolvedRefs`

---

## Step 13 — DNS

Point the cluster's zone at the Gateway address from Step 8.

Create an **A record** in your DNS provider:

```
*.demo.homelab.n2solutions.io   →   <Gateway ADDRESS>
```

A wildcard at this depth is more specific than a broader `*.homelab…` record, so
it wins resolution for everything under `demo.` without needing an entry per
application.

```bash
dig +short nginx.demo.homelab.n2solutions.io
```

**Expected:** the Gateway's address. If it still returns something else, a
broader wildcard is winning — check for a more specific record actually existing,
and allow for DNS caching.

---

## Step 14 — Verify end to end

```bash
curl -sS -o /dev/null -w 'http=%{http_code} ip=%{remote_ip}\n' \
  https://nginx.demo.homelab.n2solutions.io/

echo | openssl s_client -connect nginx.demo.homelab.n2solutions.io:443 \
  -servername nginx.demo.homelab.n2solutions.io 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

**Expected:** `http=200`, the Gateway's address, and a certificate issued by
Let's Encrypt covering `*.demo.homelab.n2solutions.io`.

Then open <https://nginx.demo.homelab.n2solutions.io> — a valid padlock and the
demo page.

---

## Files not in this repository

Generated during Step 9 and deliberately untracked:

| File | Why |
|---|---|
| `credentials/nginx-deployer.key` | The private key **is** the identity. Committing it would hand anyone the deployer's access |
| `credentials/nginx-deployer.crt` | The signed certificate — usable with the key |
| `credentials/nginx-deployer.kubeconfig` | Embeds both |
| `credentials/ca.crt` | Cluster CA; harmless, but travels with the rest |

This is itself a finding worth stating in the demo: certificate-based user
management leaves credentials outside the cluster and outside version control,
with no mechanism to revoke them and no record of who holds one.

---

## Teardown

```bash
kubectl --kubeconfig=credentials/nginx-deployer.kubeconfig delete -k manifests/apps/nginx
kubectl delete -k manifests/infrastructure/gateway
kubectl delete -k manifests/rbac
kubectl delete csr nginx-deployer
rm -rf credentials
```
