# Infrastructure

How the environment beneath the cluster is built and operated. Supporting
material for [`design.md`](design.md); not required to reproduce the cluster.

## The stack

The three VMs are not hand-built. They are declared as infrastructure-as-code and
applied through a gated CI pipeline, on hardware I run.

```
  Dell server (bare metal)
        └── Proxmox VE — hypervisor
              └── 3 × Ubuntu 24.04 VMs, declared in OpenTofu/Terragrunt
                    └── prepared by Ansible
                          └── kubeadm cluster  ← this document
```

| Layer | How |
| --- | --- |
| Hardware | Dell server, single Proxmox VE host |
| Virtualisation | Proxmox, VMs on a dedicated compute VLAN |
| VM provisioning | OpenTofu + Terragrunt, via [`terraform-proxmox-vm`](https://github.com/n2solutionsio/terraform-proxmox-vm) |
| State | Cloudflare R2, S3-compatible, with native OpenTofu locking |
| Node preparation | [`n2solutions.kubeadm`](https://github.com/n2solutionsio/ansible-collection-kubeadm) |

## GitOps for infrastructure, with a human gate

Changes to the VMs follow a pull-request workflow:

- **`terragrunt plan` runs automatically on every PR** that touches a module, and
  the plan is posted back as a comment on the pull request
- **apply is never automatic.** It requires a manual workflow dispatch, recorded
  against a deployment environment for audit

The apply gate is deliberate. Plan-on-PR gives review of exactly what will
change; requiring a human to trigger apply means no merge can alter
infrastructure on its own.

## No static credentials in CI

The runners are self-hosted, inside the Kubernetes k3s hub cluster. At job time they
authenticate to OpenBao using their **Kubernetes ServiceAccount token**, and
exchange it for short-lived credentials — object storage keys, the Proxmox API
token, the DNS provider token.

There are **no long-lived secrets stored in the CI system**. Nothing to leak from
a settings page, and every credential is scoped by policy to the specific paths
that job needs.

This is the same argument the rest of this document makes about user access,
applied to machine identity: prefer a short-lived credential derived from a
verifiable identity over a static one that must be stored, distributed, and
somehow revoked.

**Trade-off, and it is a real one:** the runners and the secret store both live
inside a Kubernetes cluster. If that cluster is down, the pipeline that provisions
infrastructure is also down. Recovering from a total outage means falling back to
running OpenTofu locally with credentials pulled by hand. A bootstrap dependency
like this is worth knowing about before you need it.

## Why bare metal, and why it does not matter

I ran this on my own hardware because I keep a properly built environment —
segmented VLANs, a hypervisor, managed DNS, a secret store, CI runners — and it
lets me demonstrate the whole stack rather than a cluster that appears from
nowhere. It also costs nothing to run and nothing to leave running (except electricity).

The practices are the ones I would apply at any scale: declared infrastructure,
reviewed changes with a human gate before apply, workload identity instead of
stored credentials, network segmentation with explicit policy, and observability
that is present before it is needed. The environment is small; none of the
methods are specific to it.

**Nothing in the solution depends on that choice.** Everything above the VMs is
standard Kubernetes and would run unchanged on any conformant cluster — bare
metal, OpenShift, Rancher, EKS, GKE, AKS. The manifests reference no Proxmox
concept and no homelab-specific resource.

Two caveats worth stating honestly rather than claiming universal portability:

- **The cluster build is kubeadm-specific**, because the exercise requires it.
  On a managed service the provider builds the control plane and Steps 1–6 of
  the cluster runbook do not apply. The application layer is unaffected.
- **The CSR identity flow needs a cluster that will sign client certificates.**
  Managed providers commonly restrict or disable the
  `kubernetes.io/kube-apiserver-client` signer, so this exact user-creation flow
  may not work on EKS, GKE or AKS. The `Role` and `RoleBinding` are entirely
  portable — only the identity layer would change, which is the same conclusion
  reached in *Where this model breaks down*.

Two environment-specific choices would need revisiting elsewhere: the
LoadBalancer address pool with L2 announcement exists because bare metal has no
cloud load balancer, and DNS-01 was chosen because the service has a private
address. A managed cluster would use a provider load balancer, and a public
service could use HTTP-01.

## A note on reproducing this

The live configuration for my environment is in a private repository. It contains
no credentials — everything is fetched at runtime from a secret store — but it is
an accurate map of a real network: VLANs, firewall rules, host addresses, and a
full service inventory. None of that is secret, and none of it is exploitable on
its own, but publishing an accurate map of a private network offers reconnaissance
value with no corresponding benefit. The reusable modules are public; only the
environment-specific composition is not. Representative extracts are in
*Configuration extracts* below.

**None of this is required to reproduce the cluster.** The build documented here
needs three Debian-family hosts that can reach each other and a container
registry — Proxmox VMs, cloud instances, or anything else. The IaC layer explains
how *these* hosts came to exist; it is not a dependency of the result.

## Configuration extracts

Representative extracts from the private live configuration, included so the
claims above are inspectable. Unmodified apart from trimming.

### CI authenticates with a ServiceAccount, not a stored secret

The runners are pods in a Kubernetes cluster. Each job presents its projected
ServiceAccount token to OpenBao, exchanges it for a short-lived token, and reads
only the paths its policy allows.

```bash
jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
tok="$(curl -s --request POST \
  --data "{\"role\":\"terraform-ci\",\"jwt\":\"$jwt\"}" \
  "${BAO_ADDR}/v1/auth/kubernetes/login" | jq -r '.auth.client_token // empty')"
if [ -z "$tok" ]; then
  echo "::error::OpenBao Kubernetes login failed (role terraform-ci)"; exit 1
fi
echo "::add-mask::$tok"

rd() { curl -sf -H "X-Vault-Token: $tok" "${BAO_ADDR}/v1/secret/data/$1" \
        | jq -r --arg k "$2" '.data.data[$k]'; }

r2_ak="$(rd tfstate-r2 access_key_id)"
px_ep="$(rd proxmox-automation-token-secret endpoint)"
px_tok="$(rd proxmox-automation-token-secret token_id)=$(rd proxmox-automation-token-secret Secret)"
```

Nothing is stored in the CI system. There is no secrets page to leak, and the
credential is valid for twenty minutes. The identity is the pod's, verified by
the Kubernetes API rather than asserted by a stored string.

The bound policy is read-only on five explicit paths. Adding the SSH public key
during this exercise required extending it — a failure that surfaced as a bare
`curl` exit code, since `curl -sf` returns the same status for a 403 as for a
404. The setup step now reports which path was refused.

### Apply requires a human; plan does not

```yaml
apply:
  needs: detect
  if: >-
    needs.detect.outputs.dirs != '[]' &&
    github.event_name == 'workflow_dispatch' && inputs.apply
  runs-on: terraform-runner
  environment: homelab-prod     # records a deployment for audit
  strategy:
    fail-fast: true
    max-parallel: 1             # apply modules one at a time
```

`plan` runs automatically on every pull request touching a module and posts its
output as a comment. `apply` runs only on an explicit manual dispatch. No merge
can change infrastructure by itself.

The run that produced the three virtual machines for this cluster:

```console
event: pull_request   conclusion: success

  detect:                      success
  plan (compute/demo-kubeadm): success
  apply:                       skipped     ← gated; runs only on manual dispatch

Plan: 3 to add, 0 to change, 0 to destroy
```

`apply: skipped` on a pull-request event is the whole control. The plan is
reviewed on the PR; applying it is a separate, deliberate act by a person, and is
recorded against a deployment environment for audit.

The plan body itself is long and not reproduced here — the interesting part is
not what it proposed but that nothing applied it automatically.

The honest reason apply is not gated by required reviewers: the repository is
private on a plan that does not enforce environment protection rules (not github enterprise - free plan), so the
manual dispatch *is* the gate. On a plan that supports it, a required reviewer
would sit on top.

### The VMs as declared

```hcl
locals {
  vms = {
    "homelab-demo-cp-0"     = { cpu_cores = 4, memory =  8192, disk_size = 60,
                                ip = "10.30.30.20", role = "control-plane" }
    "homelab-demo-worker-1" = { cpu_cores = 4, memory = 12288, disk_size = 80,
                                ip = "10.30.30.21", role = "worker" }
    "homelab-demo-worker-2" = { cpu_cores = 4, memory = 12288, disk_size = 80,
                                ip = "10.30.30.22", role = "worker" }
  }
}

module "vm" {
  source   = "git::https://github.com/n2solutionsio/terraform-proxmox-vm.git?ref=v0.3.2"
  for_each = local.vms

  node_name    = var.proxmox_node
  vm_name      = each.key
  cpu_cores    = each.value.cpu_cores
  memory       = each.value.memory
  disk_size    = each.value.disk_size
  disk_storage = var.disk_storage
  import_from  = var.cloud_image_volid

  cloud_init_enabled  = true
  cloud_init_user     = var.cloud_init_user
  cloud_init_ssh_keys = var.ssh_keys
  cloud_init_ip       = "${each.value.ip}/24"
}
```

`for_each` over an explicit map rather than `count`, because the workers are
numbered 1 and 2 — there is no worker-0, and `count.index` cannot produce that.

The module is pinned to `v0.3.2` rather than the higher `v0.4.0`. Those two tags
are divergent branches off a common ancestor, not sequential releases: `v0.4.0`
adds a feature but drops a `lifecycle` block, without which a re-rendered
cloud-init drive is applied to a running VM and the hypervisor rejects it. A
higher version number is not always a later one.

No credentials appear here. The Proxmox endpoint and API token arrive as
environment variables from the secret exchange above.
