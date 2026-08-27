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

## Verification

At this point the platform is ready, though nothing is deployed on it yet.

```bash
kubectl get gatewayclass
kubectl get ciliumloadbalancerippool
kubectl get clusterissuer
```

**Expected:** `cilium` accepted, `demo-pool` not conflicting, issuer ready.
