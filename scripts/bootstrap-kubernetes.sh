#!/usr/bin/env bash

set -Eeuo pipefail

exec > >(tee -a /var/log/cka-bootstrap.log) 2>&1

KUBERNETES_MINOR="v1.36"
CRICTL_VERSION="v1.36.0"
CALICO_VERSION="v3.32.0"
METRICS_SERVER_VERSION="v0.8.1"
GATEWAY_API_VERSION="v1.5.1"
NGINX_GATEWAY_FABRIC_CHART="oci://ghcr.io/nginx/charts/nginx-gateway-fabric"
LOCAL_PATH_PROVISIONER_VERSION="v0.0.32"
POSTGRES_VERSION="18.4-bookworm"
HELM_APT_KEY_FINGERPRINT="DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6"
KUSTOMIZE_VERSION="v5.8.1"
POD_NETWORK_CIDR="192.168.0.0/16"
BOOTSTRAP_REVISION="kubernetes-v1.36-crictl-v1.36.0-etcd-client-calico-v3.32.0-metrics-v0.8.1-gateway-v1.5.1-nginx-gateway-fabric-local-path-v0.0.32-postgres-18.4-bookworm-kustomize-v5.8.1-multinode-r11"
COMPLETION_MARKER="/var/lib/cka-bootstrap/${BOOTSTRAP_REVISION}.complete"

exec 9>/var/lock/cka-bootstrap.lock
if ! flock -n 9; then
  echo "Another Kubernetes bootstrap process is already running."
  exit 0
fi

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

# Remove the retired BaltoCDN Helm repository if it was configured manually or
# by an older version of this lab. The current repository is added below.
rm -f /etc/apt/sources.list.d/helm-stable-debian.list

apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg openssl util-linux containerd etcd-client python3
etcdctl version

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

curl -fsSL "${crictl_release_url}/${crictl_archive}" \
  -o "${crictl_tmp_dir}/${crictl_archive}"
curl -fsSL "${crictl_release_url}/${crictl_archive}.sha256" \
  -o "${crictl_tmp_dir}/${crictl_archive}.sha256"

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

echo "Installing Helm"
helm_key_file="$(mktemp)"
curl -fsSL "https://packages.buildkite.com/helm-linux/helm-debian/gpgkey" \
  -o "${helm_key_file}"

helm_key_fingerprint="$(
  gpg --show-keys --with-colons "${helm_key_file}" \
    | awk -F: '$1 == "fpr" { print $10; exit }'
)"

if [[ "${helm_key_fingerprint}" != "${HELM_APT_KEY_FINGERPRINT}" ]]; then
  rm -f "${helm_key_file}"
  echo "Unexpected Helm APT signing-key fingerprint: ${helm_key_fingerprint}"
  exit 1
fi

gpg --dearmor --yes -o /usr/share/keyrings/helm.gpg "${helm_key_file}"
rm -f "${helm_key_file}"

cat >/etc/apt/sources.list.d/helm-stable-debian.list <<'EOF'
deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main
EOF

apt-get update
apt-get install -y helm
helm version --short

echo "Installing standalone Kustomize ${KUSTOMIZE_VERSION}"
case "$(dpkg --print-architecture)" in
  amd64) kustomize_arch="amd64" ;;
  arm64) kustomize_arch="arm64" ;;
  *)
    echo "Unsupported architecture for Kustomize: $(dpkg --print-architecture)"
    exit 1
    ;;
esac

kustomize_archive="kustomize_${KUSTOMIZE_VERSION}_linux_${kustomize_arch}.tar.gz"
kustomize_release_url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}"
kustomize_tmp_dir="$(mktemp -d)"

curl -fsSL "${kustomize_release_url}/${kustomize_archive}" \
  -o "${kustomize_tmp_dir}/${kustomize_archive}"
curl -fsSL "${kustomize_release_url}/checksums.txt" \
  -o "${kustomize_tmp_dir}/checksums.txt"

(
  cd "${kustomize_tmp_dir}"
  grep "  ${kustomize_archive}$" checksums.txt | sha256sum --check --strict -
)

tar -xzf "${kustomize_tmp_dir}/${kustomize_archive}" \
  -C /usr/local/bin kustomize
chmod 0755 /usr/local/bin/kustomize
rm -rf "${kustomize_tmp_dir}"
kustomize version

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

echo "Publishing worker join command"
join_dir="/var/lib/cka-bootstrap/join"
mkdir -p "${join_dir}"
join_command="$(kubeadm token create --ttl 2h --print-join-command)"
cat >"${join_dir}/join.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
${join_command} --cri-socket unix:///run/containerd/containerd.sock
EOF
chmod 0755 "${join_dir}/join.sh"

if ! pgrep -f "python3 -m http.server 8080 --bind 0.0.0.0 --directory ${join_dir}" >/dev/null; then
  (
    exec 9>&-
    nohup python3 -m http.server 8080 --bind 0.0.0.0 --directory "${join_dir}" \
      >/var/log/cka-join-server.log 2>&1 &
  )
fi

echo "Installing Calico ${CALICO_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "Keeping the control-plane scheduling taint for multi-node CKA practice"

echo "Installing Metrics Server ${METRICS_SERVER_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

if ! kubectl get deployment metrics-server -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | grep -q -- '--kubelet-insecure-tls'; then
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi

echo "Installing Local Path Provisioner ${LOCAL_PATH_PROVISIONER_VERSION}"
kubectl apply -f \
  "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml"

echo "Installing Gateway API ${GATEWAY_API_VERSION} standard CRDs"
kubectl apply --server-side=true -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "Installing NGINX Gateway Fabric"
helm upgrade --install ngf "${NGINX_GATEWAY_FABRIC_CHART}" \
  --create-namespace \
  --namespace nginx-gateway \
  --set nginx.service.type=NodePort \
  --wait \
  --timeout 10m

echo "Installing PostgreSQL ${POSTGRES_VERSION}"
kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get secret postgres-credentials -n database >/dev/null 2>&1; then
  postgres_password="$(openssl rand -hex 24)"
  kubectl create secret generic postgres-credentials \
    --namespace database \
    --from-literal=username=cka \
    --from-literal=password="${postgres_password}" \
    --from-literal=database=cka \
    --dry-run=client -o yaml | kubectl apply -f -
fi

mkdir -p /var/lib/cka-postgres
chown 999:999 /var/lib/cka-postgres

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-data
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: cka-hostpath
  hostPath:
    path: /var/lib/cka-postgres
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: database
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: cka-hostpath
  volumeName: postgres-data
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: database
spec:
  selector:
    app.kubernetes.io/name: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: database
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:${POSTGRES_VERSION}
          imagePullPolicy: IfNotPresent
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: password
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: database
          ports:
            - name: postgres
              containerPort: 5432
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"\${POSTGRES_USER}\" -d postgres"]
            initialDelaySeconds: 5
            periodSeconds: 5
          startupProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"\${POSTGRES_USER}\" -d postgres"]
            periodSeconds: 5
            failureThreshold: 60
          livenessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"\${POSTGRES_USER}\" -d postgres"]
            initialDelaySeconds: 20
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
EOF

echo "Waiting for the node and system workloads"
kubectl wait --for=condition=Ready node --all --timeout=600s
echo "Waiting for worker nodes to join"
for attempt in {1..120}; do
  ready_worker_count="$(
    kubectl get nodes --no-headers 2>/dev/null \
      | awk '$3 !~ /control-plane/ && $2 == "Ready" { count++ } END { print count + 0 }'
  )"

  if [[ "${ready_worker_count}" -ge 1 ]]; then
    break
  fi

  if [[ "${attempt}" -eq 120 ]]; then
    echo "No worker node became Ready within the expected time"
    kubectl get nodes -o wide || true
    exit 1
  fi

  sleep 5
done
kubectl rollout status daemonset/calico-node -n kube-system --timeout=600s
kubectl rollout status deployment/calico-kube-controllers -n kube-system --timeout=600s
kubectl rollout status deployment/coredns -n kube-system --timeout=600s
kubectl rollout status deployment/metrics-server -n kube-system --timeout=300s
kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=300s
kubectl rollout status deployment -n nginx-gateway \
  -l app.kubernetes.io/instance=ngf --timeout=600s
kubectl wait --for=condition=Accepted gatewayclass/nginx --timeout=300s
kubectl rollout status deployment/postgres -n database --timeout=600s

echo "Ensuring the PostgreSQL practice database exists"
if ! kubectl exec -n database deployment/postgres -- \
  sh -c 'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT datname FROM pg_database" | grep -Fxq "$POSTGRES_DB"'; then
  kubectl exec -n database deployment/postgres -- \
    sh -c 'createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
fi

echo "Verifying Gateway API CRDs"
for crd in gatewayclasses gateways httproutes grpcroutes referencegrants; do
  kubectl get "customresourcedefinition/${crd}.gateway.networking.k8s.io" >/dev/null
done

echo "Verifying NGINX Gateway Fabric"
helm status ngf --namespace nginx-gateway >/dev/null
kubectl get pods -n nginx-gateway -l app.kubernetes.io/instance=ngf >/dev/null
kubectl get gatewayclass/nginx >/dev/null

echo "Verifying Local Path Provisioner"
kubectl get storageclass/local-path >/dev/null
kubectl get deployment/local-path-provisioner -n local-path-storage >/dev/null

echo "Checking for local personal practice manifests"
personal_practice_manifest="$(
  curl -fsS \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/personal-practice-manifest" \
    || true
)"

if [[ -n "${personal_practice_manifest}" ]]; then
  echo "Applying local personal practice manifests"
  printf '%s\n' "${personal_practice_manifest}" | kubectl apply -f -
else
  echo "No local personal practice manifests found"
fi

echo "Checking for local personal practice script"
personal_practice_script="$(
  curl -fsS \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/personal-practice-script" \
    || true
)"

if [[ -n "${personal_practice_script}" ]]; then
  echo "Running local personal practice script"
  printf '%s\n' "${personal_practice_script}" | bash
else
  echo "No local personal practice script found"
fi

echo "Verifying PostgreSQL"
kubectl exec -n database deployment/postgres -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "SELECT 1;"' >/dev/null

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
