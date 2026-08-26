#!/usr/bin/env bash
#
# Bootstraps the platform layer that cannot be managed declaratively, then
# applies the manifests that can.
#
# Everything here runs before GitOps can take over, and most of it is
# unavoidable: the CNI cannot be reconciled by a controller that needs the CNI
# to reach the API server, and CRDs must exist before the resources that use
# them can be validated.
#
# Idempotent -- safe to re-run.
#
# Usage:  ./scripts/bootstrap-platform.sh
#
set -euo pipefail

GATEWAY_API_VERSION="v1.4.1"   # pinned: Cilium 1.19 targets this exact version
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# --- guard against applying to the wrong cluster ------------------------------
CURRENT_CTX="$(kubectl config current-context)"
say "Target cluster: ${CURRENT_CTX}"
read -rp "Continue? [y/N] " reply
[[ "${reply}" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }

# --- Gateway API CRDs ---------------------------------------------------------
# Must precede enabling Cilium's Gateway controller: without them the controller
# starts, finds no CRDs, and produces no GatewayClass.
say "Installing Gateway API CRDs (${GATEWAY_API_VERSION})"
BASE="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd"
for crd in \
  standard/gateway.networking.k8s.io_gatewayclasses.yaml \
  standard/gateway.networking.k8s.io_gateways.yaml \
  standard/gateway.networking.k8s.io_httproutes.yaml \
  standard/gateway.networking.k8s.io_referencegrants.yaml \
  standard/gateway.networking.k8s.io_grpcroutes.yaml \
  experimental/gateway.networking.k8s.io_tlsroutes.yaml
do
  kubectl apply --server-side -f "${BASE}/${crd}"
done

# --- Cilium ------------------------------------------------------------------
# gatewayAPI provides the Gateway controller. l2announcements is what makes a
# LoadBalancer address actually reachable -- without it an address is allocated
# from the pool but never answered for on the network, which presents as a
# Service with an EXTERNAL-IP that nothing can connect to.
if helm get values cilium -n kube-system 2>/dev/null | grep -q 'gatewayAPI'; then
  say "Cilium already has Gateway API enabled, skipping upgrade"
else
  say "Enabling Gateway API and L2 announcements in Cilium"
  cilium upgrade \
    --set gatewayAPI.enabled=true \
    --set l2announcements.enabled=true

  kubectl -n kube-system rollout restart deployment/cilium-operator
  kubectl -n kube-system rollout restart ds/cilium
  kubectl -n kube-system rollout status ds/cilium --timeout=300s
fi

say "Waiting for GatewayClass to be accepted"
kubectl wait --for=condition=Accepted gatewayclass/cilium --timeout=120s

# --- cert-manager -------------------------------------------------------------
if kubectl get ns cert-manager >/dev/null 2>&1; then
  say "cert-manager namespace exists, skipping install"
else
  CM_VER="$(curl -fsSL https://api.github.com/repos/cert-manager/cert-manager/releases/latest \
    | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)"
  say "Installing cert-manager ${CM_VER}"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CM_VER}/cert-manager.yaml"
  kubectl -n cert-manager rollout status deployment/cert-manager --timeout=300s
  kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=300s
fi

# --- Cloudflare credentials ---------------------------------------------------
# A secret, so it is deliberately not in this repository. Sourced from a
# password manager at apply time.
if kubectl -n cert-manager get secret cloudflare-api-token >/dev/null 2>&1; then
  say "Cloudflare API token secret already present"
else
  say "Creating Cloudflare API token secret"
  if ! command -v op >/dev/null 2>&1; then
    echo "ERROR: 1Password CLI not found."
    echo "Create the secret manually, then re-run:"
    echo "  kubectl -n cert-manager create secret generic cloudflare-api-token \\"
    echo "    --from-literal=api-token='<token>'"
    exit 1
  fi
  kubectl -n cert-manager create secret generic cloudflare-api-token \
    --from-literal=api-token="$(op read 'op://homelab/cloudflare-dns/api-token')"
fi

# --- declarative manifests ----------------------------------------------------
say "Applying LoadBalancer IP pool and L2 announcement policy"
kubectl apply -k "${REPO_ROOT}/manifests/infrastructure/cilium-lb"

say "Applying ClusterIssuer"
kubectl apply -k "${REPO_ROOT}/manifests/infrastructure/cert-manager"

say "Waiting for ClusterIssuer to become ready"
kubectl wait --for=condition=Ready clusterissuer/letsencrypt-production --timeout=120s

say "Bootstrap complete"
kubectl get gatewayclass
kubectl get ciliumloadbalancerippool
kubectl get clusterissuer
