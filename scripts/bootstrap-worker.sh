#!/usr/bin/env bash

set -Eeuo pipefail

exec > >(tee -a /var/log/cka-worker-bootstrap.log) 2>&1

KUBERNETES_MINOR="v1.36"
CRICTL_VERSION="v1.36.0"
BOOTSTRAP_REVISION="worker-kubernetes-v1.36-crictl-v1.36.0-r2"
COMPLETION_MARKER="/var/lib/cka-bootstrap/${BOOTSTRAP_REVISION}.complete"

exec 9>/var/lock/cka-worker-bootstrap.lock
if ! flock -n 9; then
  echo "Another worker bootstrap process is already running."
  exit 0
fi

if [[ -f "${COMPLETION_MARKER}" ]]; then
  echo "Worker bootstrap has already completed."
  exit 0
fi

mkdir -p "$(dirname "${COMPLETION_MARKER}")"

metadata_value() {
  curl -fsS \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

download_file() {
  local url="$1"
  local output="$2"
  local attempts="${3:-8}"

  for attempt in $(seq 1 "${attempts}"); do
    if curl -fL --connect-timeout 20 --retry 5 --retry-delay 3 --retry-all-errors \
      "${url}" -o "${output}"; then
      return 0
    fi

    echo "Download failed (${attempt}/${attempts}): ${url}"
    sleep $((attempt * 5))
  done

  echo "Download failed after ${attempts} attempts: ${url}"
  return 1
}

CONTROL_PLANE_IP="$(metadata_value control-plane-ip)"

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
apt-get install -y apt-transport-https ca-certificates curl gpg openssl util-linux containerd etcd-client

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

echo "Installing crictl ${CRICTL_VERSION}"
case "$(dpkg --print-architecture)" in
  amd64) crictl_arch="amd64" ;;
  arm64) crictl_arch="arm64" ;;
  *)
    echo "Unsupported architecture for crictl: $(dpkg --print-architecture)"
    exit 1
    ;;
esac

crictl_archive="crictl-${CRICTL_VERSION}-linux-${crictl_arch}.tar.gz"
crictl_release_url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}"
crictl_tmp_dir="$(mktemp -d)"

download_file "${crictl_release_url}/${crictl_archive}" \
  "${crictl_tmp_dir}/${crictl_archive}"
download_file "${crictl_release_url}/${crictl_archive}.sha256" \
  "${crictl_tmp_dir}/${crictl_archive}.sha256"

(
  cd "${crictl_tmp_dir}"
  echo "$(cat "${crictl_archive}.sha256")  ${crictl_archive}" \
    | sha256sum --check --strict -
)

tar -xzf "${crictl_tmp_dir}/${crictl_archive}" \
  -C /usr/local/bin crictl
chmod 0755 /usr/local/bin/crictl
rm -rf "${crictl_tmp_dir}"

cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

crictl --version
crictl info >/dev/null

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

if [[ ! -f /etc/kubernetes/kubelet.conf ]]; then
  echo "Waiting for join command from control plane ${CONTROL_PLANE_IP}"
  for attempt in {1..120}; do
    if curl -fsS "http://${CONTROL_PLANE_IP}:8080/join.sh" -o /tmp/kubeadm-join.sh; then
      bash /tmp/kubeadm-join.sh
      break
    fi

    if [[ "${attempt}" -eq 120 ]]; then
      echo "Timed out waiting for kubeadm join command"
      exit 1
    fi

    sleep 5
  done
else
  echo "Worker already has kubelet configuration; skipping kubeadm join."
fi

echo "Installing cluster admin kubeconfig for exam-like kubectl access"
for attempt in {1..120}; do
  if curl -fsS "http://${CONTROL_PLANE_IP}:8080/admin.conf" -o /tmp/admin.conf; then
    mkdir -p /root/.kube /etc/kubernetes
    install -m 0600 /tmp/admin.conf /etc/kubernetes/admin.conf
    install -m 0600 /tmp/admin.conf /root/.kube/config

    for home_dir in /home/*; do
      [[ -d "${home_dir}" ]] || continue
      user_name="$(basename "${home_dir}")"
      mkdir -p "${home_dir}/.kube"
      install -m 0600 -o "${user_name}" -g "${user_name}" /tmp/admin.conf "${home_dir}/.kube/config" \
        || install -m 0600 /tmp/admin.conf "${home_dir}/.kube/config"
    done

    rm -f /tmp/admin.conf
    break
  fi

  if [[ "${attempt}" -eq 120 ]]; then
    echo "Timed out waiting for admin kubeconfig"
    exit 1
  fi

  sleep 5
done

touch "${COMPLETION_MARKER}"
echo "Worker bootstrap completed successfully"
