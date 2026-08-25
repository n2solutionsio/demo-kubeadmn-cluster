# Building a kubeadm cluster with Cilium

End to end: three bare Linux VMs become a working Kubernetes cluster — one control
plane, two workers, Cilium networking, no kube-proxy.

Node preparation is automated with Ansible. Installing Kubernetes and creating the
cluster is done by hand, deliberately: preparation is repeatable and dull, which is
what automation is good at, while bootstrap involves expiring tokens and ordering
that is worth watching happen.

Written to be followed without prior Kubernetes knowledge. Run one block at a time
and check the output matches. **If it does not match, stop** — later steps assume
earlier ones worked.

---

## The example environment

This runbook documents one specific cluster. **The addresses and versions below are
choices made for that environment, not requirements** — substitute your own in the
*Set your values* block and everything else follows.

| Setting | Used here | Why, and what to consider for yours |
|---|---|---|
| Control plane | `10.30.30.20` | A static address on a dedicated compute VLAN, chosen from outside the DHCP pool so it can never be reassigned |
| Workers | `10.30.30.21`, `10.30.30.22` | Consecutive addresses in the same range, purely for legibility |
| Pod network | `10.244.0.0/16` | Must not overlap any subnet routed on your network, **or any other cluster you might connect to**. This environment already had a cluster using `10.42.0.0/16`, so a different range was required |
| Kubernetes | `1.33` | Matched to an existing cluster in the same environment, so a single `kubectl` works against both — the version skew policy tolerates ±1 minor |
| Login user | `ubuntu` | The default user on Ubuntu cloud images |
| CNI | Cilium, replacing kube-proxy | Matches the other cluster in this environment |

Nothing here depends on those specific values. The three nodes need to reach each
other and a container registry; the rest is preference.

## Requirements

**On the hosts:**

- Debian-family Linux, x86_64 (Ubuntu 24.04 here)
- SSH access using a key, with passwordless `sudo`
- Network reachability between all three, and outbound access to `registry.k8s.io`

**On your own machine:**

- `ansible-core` >= 2.15
- `kubectl`, within one minor version of the Kubernetes you install
- The `cilium` CLI

**All commands run from your own machine.** You never log into the servers
directly; each command reaches them over SSH. If your prompt ever changes to
something like `user@server-name`, type `exit` before continuing.

---

## Set your values

Edit these, then paste the block. **Everything below depends on them.**

```bash
export CP_IP=10.30.30.20                        # control plane address
export WORKER_IPS="10.30.30.21 10.30.30.22"     # worker addresses, space separated
export SSH_USER=ubuntu                          # login user on the hosts
export POD_CIDR=10.244.0.0/16                   # pod network — see the table above
export CTX_NAME=demo-kubeadm                    # what to call this cluster locally
export STAGING_DIR=/opt/kubeadm-staging         # where Ansible stages the packages
```

> These are shell variables and last only for the current terminal window. Open a
> new one, paste the block again.

---

## Step 1 — Prepare the nodes (Ansible)

Everything a Kubernetes node needs *before* Kubernetes itself: container runtime,
kernel settings, swap disabled, packages downloaded.

### 1a. Install the collection

```bash
ansible-galaxy collection install \
  git+https://github.com/n2solutionsio/ansible-collection-kubeadm.git
```

### 1b. Write an inventory

Save as `inventory.ini`, substituting your own addresses and key:

```ini
[kubeadm_control_plane]
demo-cp-0 ansible_host=10.30.30.20

[kubeadm_workers]
demo-worker-1 ansible_host=10.30.30.21
demo-worker-2 ansible_host=10.30.30.22

[kubeadm_nodes:children]
kubeadm_control_plane
kubeadm_workers

[kubeadm_nodes:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_ed25519
ansible_python_interpreter=/usr/bin/python3
```

> The names on the left become the Kubernetes node names, so make them meaningful.
> Control plane and workers are prepared identically — the groups exist so later
> steps have something to target.

### 1c. Run it

```bash
ansible-playbook -i inventory.ini n2solutions.kubeadm.prepare_nodes
```

**Expected:** `failed=0` for every host. Run it twice if you like — the second run
should report `changed=0`, which is how you know it is idempotent.

### What that did

| | |
|---|---|
| Swap | Disabled at runtime, in `/etc/fstab`, and via systemd `.swap` units |
| Kernel modules | `overlay`, `br_netfilter` loaded and persisted |
| Sysctls | `bridge-nf-call-iptables`, `bridge-nf-call-ip6tables`, `ip_forward` |
| Container runtime | containerd installed, CRI enabled, systemd cgroup driver |
| eBPF groundwork | `bpffs` mounted, cgroup v2 verified — required by Cilium |
| OS prerequisites | `conntrack`, `socat` installed (nothing pulls these in automatically, and `kubeadm init` fails without `conntrack`) |
| Kubernetes packages | `kubelet`, `kubeadm`, `kubectl`, `cri-tools` **downloaded, not installed** |
| Notes | `INSTALL-NOTES.md` written to each host |

It deliberately does **not** install Kubernetes or create a cluster. That is
Steps 3 and 4.

### 1d. Verify

```bash
for h in $CP_IP $WORKER_IPS; do
  echo "--- $h ---"
  ssh -o BatchMode=yes -o ConnectTimeout=10 $SSH_USER@$h '
    printf "  hostname:   %s\n" "$(hostname)"
    printf "  containerd: %s\n" "$(systemctl is-active containerd)"
    printf "  swap off:   %s\n" "$([ "$(swapon --show --noheadings | wc -l)" -eq 0 ] && echo yes || echo NO)"
    printf "  staged:     %s packages\n" "$(ls /opt/kubeadm-staging/*.deb 2>/dev/null | wc -l)"
    printf "  registry:   %s\n" "$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://registry.k8s.io/v2/ || echo FAILED)"
  '
done
```

**Expected, for every host:**

```
  containerd: active
  swap off:   yes
  staged:     5 packages
  registry:   401
```

`401` is the correct answer for the registry check — it means the registry
responded. Anything else means that host cannot reach it, and Step 3 will fail.

---

## Step 2 — Install Kubernetes on the nodes

The packages are already on each host. This installs them.

```bash
for h in $CP_IP $WORKER_IPS; do
  echo "=== installing on $h ==="
  ssh $SSH_USER@$h "
    sudo apt-get install -y $STAGING_DIR/*.deb >/dev/null 2>&1
    sudo apt-mark hold kubelet kubeadm kubectl >/dev/null
    printf '  kubeadm: %s\n' \"\$(kubeadm version -o short)\"
    printf '  kubelet: %s\n' \"\$(systemctl is-active kubelet)\"
  "
done
```

**Expected, for every host:**

```
  kubeadm: v1.33.13
  kubelet: inactive
```

**`kubelet: inactive` is correct.** It has no cluster to join yet and starts during
the next two steps.

`apt-mark hold` prevents an automatic upgrade from moving kubelet out of step with
the control plane — a common way to break a cluster months later.

---

## Step 3 — Create the control plane

Takes two to five minutes, and will appear idle for much of it.

```bash
ssh $SSH_USER@$CP_IP "sudo kubeadm init \
  --apiserver-advertise-address=$CP_IP \
  --pod-network-cidr=$POD_CIDR \
  --skip-phases=addon/kube-proxy 2>&1 | sudo tee /root/kubeadm-init.log" | tail -25
```

**Expected, near the end:**

```
Your Kubernetes control-plane has initialized successfully!
```

The complete log stays on the server at `/root/kubeadm-init.log`.

**Ignore the `mkdir -p $HOME/.kube` instructions kubeadm prints.** Those configure
access on the server. Step 4 does something better.

**If you see `[ERROR]` lines, stop.** Do not run it again — a partially completed
initialisation must be reset first. See *Starting over*.

> `--skip-phases=addon/kube-proxy` is why Cilium can replace kube-proxy cleanly.
> This is decided here, at creation time; removing kube-proxy from a running
> cluster afterwards is considerably messier.

---

## Step 4 — Get admin access on your own machine

Adds the new cluster to your kubeconfig alongside anything already there, backing
up the existing file first.

```bash
ssh $SSH_USER@$CP_IP 'sudo cat /etc/kubernetes/admin.conf' > /tmp/newcluster.conf

# kubeadm names its context "kubernetes-admin@kubernetes"; rename it
CTX=$(KUBECONFIG=/tmp/newcluster.conf kubectl config current-context)
KUBECONFIG=/tmp/newcluster.conf kubectl config rename-context "$CTX" "$CTX_NAME"

# back up before touching the existing config
mkdir -p ~/.kube
[ -f ~/.kube/config ] && cp ~/.kube/config ~/.kube/config.bak-$(date +%Y%m%d-%H%M%S)

# merge and replace
KUBECONFIG=~/.kube/config:/tmp/newcluster.conf kubectl config view --flatten > /tmp/merged.conf
mv /tmp/merged.conf ~/.kube/config
chmod 600 ~/.kube/config
rm -f /tmp/newcluster.conf

kubectl config get-contexts
```

**Expected:** your new context listed alongside any existing ones.

```bash
kubectl config use-context $CTX_NAME
kubectl get nodes
```

**Expected:**

```
NAME              STATUS     ROLES           AGE   VERSION
<control-plane>   NotReady   control-plane   5m    v1.33.13
```

**`NotReady` is correct here.** There is no pod network yet — Step 5 installs it.

**If anything looks wrong**, restore:
`cp ~/.kube/config.bak-<timestamp> ~/.kube/config`

> kubeadm names its *cluster* `kubernetes` and its *user* `kubernetes-admin`.
> Those are generic, so a second kubeadm cluster added later will collide and need
> renaming too.

---

## Step 5 — Install Cilium

Pods cannot communicate until this is done. The command runs locally; it creates
workloads inside the cluster, and the hosts download the images themselves.

**Confirm which cluster you are pointing at first.** Running this against the wrong
cluster would try to install Cilium over an existing network layer.

```bash
kubectl config current-context      # must match your CTX_NAME
```

```bash
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=$CP_IP \
  --set k8sServicePort=6443 \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="{$POD_CIDR}"
```

**Expected** — confirming the kube-proxy decision took effect:

```
🔮 Auto-detected kube-proxy has not been installed
ℹ️  Cilium will fully replace all functionalities of kube-proxy
```

```bash
cilium status --wait
```

**Expected:** `OK` beside Cilium, Operator, and Envoy DaemonSet. Takes a few
minutes.

```bash
kubectl get nodes
```

**Expected:** the control plane is now **`Ready`**. If it is still `NotReady` after
five minutes, stop.

---

## Step 6 — Join the workers

```bash
JOIN=$(ssh $SSH_USER@$CP_IP 'sudo kubeadm token create --print-join-command')
[ -n "$JOIN" ] && echo "Join command obtained (hidden)" || echo "FAILED — empty"
```

**Expected:** `Join command obtained (hidden)`

The command is deliberately not displayed. It contains a token and certificate hash
that would let any machine join your cluster for the next 24 hours, so it stays in
a shell variable rather than on screen or in your terminal history.

**If it reports FAILED, stop** — the next block would run an empty command.

```bash
for h in $WORKER_IPS; do
  echo "=== joining $h ==="
  ssh $SSH_USER@$h "sudo $JOIN" 2>&1 | tail -3
done
```

**Expected, for each host:**

```
Run 'kubectl get nodes' on the control-plane to see this node join the cluster.
```

```bash
kubectl get nodes
```

**Expected** — workers show `NotReady` for up to a minute while Cilium starts on
them, then all three report `Ready`.

Now revoke the token. Nothing needs it once the workers are in; they received their
own certificates during the join.

```bash
TOKEN_ID=$(echo "$JOIN" | grep -oE 'token [a-z0-9]{6}' | awk '{print $2}')
ssh $SSH_USER@$CP_IP "sudo kubeadm token delete $TOKEN_ID"
```

**Expected:** `bootstrap token "<id>" deleted`

> Tokens expire on their own after 24 hours. Revoking early closes the window
> immediately. Adding another worker later just means repeating this step.

---

## Step 7 — Sanity test

Proves scheduling, networking, and DNS work together.

```bash
kubectl create deployment sanity --image=nginx --replicas=3
kubectl expose deployment sanity --port=80
kubectl rollout status deployment/sanity --timeout=180s
```

**Expected:** `deployment "sanity" successfully rolled out`

```bash
kubectl get pods -o wide
```

**Expected:** three pods `Running`, more than one distinct name in the `NODE`
column, and pod addresses inside your `POD_CIDR`. Pods appear only on workers —
the control plane carries a `NoSchedule` taint by design.

```bash
kubectl run testbox --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c 'wget -qO- --timeout=5 http://sanity | head -4'
```

**Expected:** `<!DOCTYPE html>` and `<title>Welcome to nginx!</title>`

This single command is the real test: DNS resolved the service name, Cilium routed
traffic between hosts, and the service load-balanced to a pod.

```bash
kubectl get pods -n kube-system | grep -c kube-proxy      # expect: 0
```

Clean up:

```bash
kubectl delete deployment sanity
kubectl delete service sanity
```

---

## Optional — Hubble

Cilium's traffic-flow observability, including a web UI.

```bash
cilium hubble enable --ui
cilium status --wait
cilium hubble ui
```

---

## If something goes wrong

First check you are pointing at the right cluster:

```bash
kubectl config current-context
```

| Symptom | Command |
|---|---|
| Node stuck `NotReady` | `kubectl describe node <name> \| tail -20` |
| Pod will not start | `kubectl describe pod <name>` |
| kubelet unhealthy | `ssh $SSH_USER@$CP_IP 'sudo journalctl -u kubelet -n 50 --no-pager'` |
| Containers at runtime level | `ssh $SSH_USER@$CP_IP 'sudo crictl ps -a'` |
| Cilium unhealthy | `cilium status` |

### Two traps worth knowing

**Never paste an `ssh` line together with the commands meant to run after it.**
SSH consumes the following lines as input while connecting, so they silently never
execute — and the step looks like it succeeded. Every command here is a
self-contained one-liner for exactly that reason.

**A `NotReady` node immediately after cluster creation is normal.** It means no pod
network is installed yet, not that something failed.

### Starting over

Destructive — removes cluster membership from that host.

```bash
ssh $SSH_USER@<host> 'sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d'
```

Then repeat Step 3 for the control plane, or Step 6 for a worker.
