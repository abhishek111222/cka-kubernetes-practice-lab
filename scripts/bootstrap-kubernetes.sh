#!/usr/bin/env bash

set -Eeuo pipefail

exec > >(tee -a /var/log/cka-bootstrap.log) 2>&1

KUBERNETES_MINOR="v1.36"
CALICO_VERSION="v3.32.0"
METRICS_SERVER_VERSION="v0.8.1"
POD_NETWORK_CIDR="192.168.0.0/16"
COMPLETION_MARKER="/var/lib/cka-bootstrap/kubernetes-${KUBERNETES_MINOR}-calico-${CALICO_VERSION}-metrics-${METRICS_SERVER_VERSION}.complete"

if [[ -f "${COMPLETION_MARKER}" ]]; then
  echo "Kubernetes bootstrap has already completed."
  exit 0
fi

mkdir -p "$(dirname "${COMPLETION_MARKER}")"

echo "Configuring kernel prerequisites"
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

cat >/etc/modules-load.d/kubernetes.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "Installing and configuring containerd"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gpg containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

echo "Installing Kubernetes ${KUBERNETES_MINOR} packages"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /
EOF

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  echo "Initializing the Kubernetes control plane"
  kubeadm init \
    --cri-socket unix:///run/containerd/containerd.sock \
    --pod-network-cidr "${POD_NETWORK_CIDR}"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

echo "Installing Calico ${CALICO_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "Allowing practice workloads on the single control-plane node"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "Installing Metrics Server ${METRICS_SERVER_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

if ! kubectl get deployment metrics-server -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | grep -q -- '--kubelet-insecure-tls'; then
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi

echo "Waiting for the node and system workloads"
kubectl wait --for=condition=Ready node --all --timeout=600s
kubectl wait --for=condition=Ready pod --all --all-namespaces --timeout=600s
kubectl rollout status deployment/metrics-server -n kube-system --timeout=300s

echo "Waiting for the Metrics API to return data"
for attempt in {1..36}; do
  if kubectl top nodes >/dev/null 2>&1; then
    break
  fi

  if [[ "${attempt}" -eq 36 ]]; then
    echo "Metrics API did not return data within the expected time"
    exit 1
  fi

  sleep 5
done

touch "${COMPLETION_MARKER}"
echo "Kubernetes bootstrap completed successfully"
