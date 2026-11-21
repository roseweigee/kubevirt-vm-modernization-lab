#!/usr/bin/env bash
# Install KubeVirt (VMs on Kubernetes) and CDI (disk image import) on the current cluster.
# OpenShift Virtualization is Red Hat's supported build of these same two projects.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

KV_VERSION="${KV_VERSION:-$(curl -fsSL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)}"
CDI_VERSION="${CDI_VERSION:-$(basename "$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/kubevirt/containerized-data-importer/releases/latest)")}"
echo "KubeVirt $KV_VERSION · CDI $CDI_VERSION"

say "1/3 KubeVirt operator + CR"
# server-side apply: the KubeVirt CRD is too large for client-side apply's annotation
kubectl apply --server-side --force-conflicts -f "https://github.com/kubevirt/kubevirt/releases/download/$KV_VERSION/kubevirt-operator.yaml"
kubectl wait crd kubevirts.kubevirt.io --for=condition=Established --timeout=120s
kubectl apply --server-side --force-conflicts -f "https://github.com/kubevirt/kubevirt/releases/download/$KV_VERSION/kubevirt-cr.yaml"

# Hardware virtualization check: without /dev/kvm on the node, fall back to software emulation
NODE_CONTAINER="${NODE_CONTAINER:-}"
if [[ -n "$NODE_CONTAINER" ]] && ! docker exec "$NODE_CONTAINER" test -e /dev/kvm; then
  echo "  /dev/kvm not available on the node → enabling software emulation (slower)"
  kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
else
  echo "  /dev/kvm available → hardware-accelerated VMs"
fi
kubectl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=15m
kubectl -n kubevirt rollout status deploy/virt-api --timeout=5m
kubectl -n kubevirt rollout status deploy/virt-controller --timeout=5m
kubectl -n kubevirt rollout status ds/virt-handler --timeout=5m

say "2/3 CDI operator + CR"
kubectl apply --server-side --force-conflicts -f "https://github.com/kubevirt/containerized-data-importer/releases/download/$CDI_VERSION/cdi-operator.yaml"
kubectl wait crd cdis.cdi.kubevirt.io --for=condition=Established --timeout=120s
kubectl apply --server-side --force-conflicts -f "https://github.com/kubevirt/containerized-data-importer/releases/download/$CDI_VERSION/cdi-cr.yaml"
kubectl wait cdi cdi --for=condition=Available --timeout=15m
kubectl -n cdi rollout status deploy/cdi-apiserver --timeout=5m
kubectl -n cdi rollout status deploy/cdi-deployment --timeout=5m

say "3/3 virtctl CLI"
if ! command -v virtctl >/dev/null; then
  os=$(uname | tr '[:upper:]' '[:lower:]'); arch=$(uname -m); [[ $arch == x86_64 ]] && arch=amd64; [[ $arch == aarch64 ]] && arch=arm64
  curl -fsSL -o /tmp/virtctl "https://github.com/kubevirt/kubevirt/releases/download/$KV_VERSION/virtctl-$KV_VERSION-$os-$arch"
  chmod +x /tmp/virtctl && sudo mv /tmp/virtctl /usr/local/bin/virtctl
fi
virtctl version --client
kubectl get pods -n kubevirt
kubectl get pods -n cdi
