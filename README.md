# CKA practice infrastructure

This Terraform configuration can manage two independent practice environments:

1. Existing CKA cluster environment:
   - `abhis-cka-vm-control-plane`
   - `abhis-cka-vm-worker-1`
   - `abhis-cka-vm-worker-2`
2. Build-from-scratch environment:
   - `abhis-kube-build-control-plane`
   - `abhis-kube-build-worker-1`

The existing CKA environment creates a multi-node CKA practice lab:

- one Ubuntu 24.04 LTS Compute Engine control-plane VM;
- two Ubuntu 24.04 LTS Compute Engine worker VMs by default;
- an external IP address on the project's existing `default` network;
- OS Login for SSH access;
- containerd and a `kubeadm` Kubernetes 1.36 control plane;
- crictl v1.36.0, configured to inspect and debug the containerd runtime.
- etcdctl from the Ubuntu `etcd-client` package for etcd backup and inspection practice.
- Calico networking, with the normal control-plane taint kept so practice workloads schedule on workers.
- Helm, installed from the current Buildkite-hosted Debian repository.
- standalone Kustomize v5.8.1, verified against its published SHA-256 checksum.
- Gateway API v1.5.1 standard CRDs and NGINX Gateway Fabric installed by Helm as a NodePort service.
- cert-manager v1.21.0 with `Issuer`, `ClusterIssuer`, and `Certificate` CRDs plus a self-signed practice certificate.
- Rancher Local Path Provisioner v0.0.32 with StorageClass `local-path` for PVC practice.
- Argo CD v3.4.2 in the `argocd` namespace for GitOps practice.
- PostgreSQL 18.4 with generated credentials and persistent single-node storage.

The build-from-scratch environment creates only two plain Ubuntu VMs. It intentionally does not install containerd configuration, kubeadm, kubelet, kubectl, Calico, or any Kubernetes cluster configuration. Use those VMs when you want to manually build a kubeadm cluster from zero.

## Prerequisites

Install these tools on the laptop:

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install)
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.6 or later

The selected GCP project must have billing enabled and an existing `default` VPC with an SSH firewall rule. The signed-in account needs permission to enable project services and create Compute Engine resources.

## Fresh-clone quick start

Open PowerShell and run:

```powershell
git clone https://github.com/abhishek111222/cka-kubernetes-practice-lab.git
Set-Location cka-kubernetes-practice-lab
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
.\deploy.ps1
```

Set at least `project_id` in `terraform.tfvars`, save the file, and close Notepad before running the deployment command. The script asks which environment to operate on:

1. Existing CKA cluster only
2. Build-from-scratch VMs only
3. Both environments
4. Cancel

For the CKA environment, the script handles Terraform initialization, authentication checks, VM creation, Kubernetes bootstrap, and health verification. For the build-from-scratch environment, it creates only the two blank Ubuntu VMs and prints SSH commands.

When deployment finishes, it prints the exact `gcloud compute ssh` command. After connecting to the VM, verify the lab with:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top nodes
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top pods -A
```

For a more exam-like workflow, the bootstrap also installs the cluster admin kubeconfig on each worker node. That means after SSH'ing into `abhis-cka-vm-worker-1` or `abhis-cka-vm-worker-2`, both of these work directly from the worker:

```bash
kubectl get nodes
sudo kubectl get nodes
```

This is intentionally convenient for disposable CKA practice clusters. Treat the VMs as trusted lab machines because the copied kubeconfig has cluster-admin access.

When finished practising, return to PowerShell in the cloned repository and run:

```powershell
.\destroy.ps1
```

The destroy script asks which environment to delete, prints the VM/disk names in scope, creates a scoped Terraform destroy plan, and requires `DELETE` before applying it. Keep the cloned folder and its local Terraform state until destruction completes.

## Repository layout

| Path | Purpose |
| --- | --- |
| `main.tf` | Creates the Compute Engine API setting, firewall rule, control-plane VM, and worker VMs |
| `variables.tf` | Defines configurable project, location, VM, disk, and label inputs |
| `terraform.tfvars.example` | Safe template for local configuration |
| `deploy.ps1` | One-command create, bootstrap, wait, and verification workflow |
| `destroy.ps1` | Scoped destroy workflow with environment selection and confirmation |
| `start.ps1` | Starts selected environment VMs |
| `stop.ps1` | Stops selected environment VMs |
| `scripts/gcp-auth.ps1` | Reuses credentials or launches Google login when required |
| `scripts/bootstrap-kubernetes.sh` | Installs Kubernetes and the cluster add-ons, including Gateway API and PostgreSQL |
| `outputs.tf` | Prints VM addresses, SSH command, and useful cluster commands |

`terraform.tfvars`, Terraform state, saved plans, credentials, and private keys are ignored by Git and must not be committed.

## Authentication

The deployment and destruction scripts check both credential sets used by this project:

- Google Cloud CLI credentials, used by `gcloud`;
- Application Default Credentials, used by Terraform.

When valid cached credentials exist, authentication is automatic. If credentials are missing, expired, or revoked, the script opens Google's browser login flow and then continues. Google requires interactive approval in those cases; the project never stores passwords, access tokens, or service-account keys.

Application Default Credentials are stored outside this repository. Do not add credential JSON files here.

Use `./deploy.ps1` and `./destroy.ps1` rather than invoking Terraform directly. The wrappers ignore `GOOGLE_APPLICATION_CREDENTIALS` for their process so that an unrelated or deleted service-account credential file cannot override the user Application Default Credentials created by `gcloud auth application-default login`. If that environment variable is configured persistently, the wrappers print a warning without changing your user or machine environment.

## Configure the deployment

Copy the example variables file:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set `project_id` to the GCP project ID, not its display name.

The reusable inputs are:

| Variable | Purpose | Default |
| --- | --- | --- |
| `project_id` | Billing-enabled GCP project ID | Required |
| `region` | GCP region | `europe-west2` |
| `zone` | VM zone | `europe-west2-a` |
| `instance_name` | VM name | `abhis-cka-vm` |
| `machine_type` | VM CPU and memory size | `e2-small` |
| `control_plane_machine_type` | Control-plane VM size | `e2-medium` |
| `worker_machine_type` | Optional worker VM size override | `null` |
| `worker_count` | Number of worker VMs | `2` |
| `boot_disk_size_gb` | Boot disk size | `30` |
| `kube_build_instance_name` | Base name for blank build-from-scratch VMs | `abhis-kube-build` |
| `kube_build_control_plane_machine_type` | Blank build control-plane VM size | `e2-medium` |
| `kube_build_worker_machine_type` | Blank build worker VM size | `e2-small` |
| `kube_build_boot_disk_size_gb` | Blank build VM boot disk size | `30` |

## Environment selection

The wrapper scripts intentionally do not silently operate on both environments.

Create/deploy:

```powershell
.\deploy.ps1
```

Non-interactive examples:

```powershell
.\deploy.ps1 -Environment Cka
.\deploy.ps1 -Environment KubeBuild
.\deploy.ps1 -Environment Both
```

Start or stop VMs for daily practice:

```powershell
.\start.ps1
.\stop.ps1
```

Non-interactive examples:

```powershell
.\start.ps1 -Environment Cka
.\stop.ps1 -Environment KubeBuild
.\stop.ps1 -Environment Both
```

Delete resources:

```powershell
.\destroy.ps1
```

Non-interactive environment selection is available, but deletion still requires confirmation unless `-AutoApprove` is supplied:

```powershell
.\destroy.ps1 -Environment KubeBuild
```

Deletion is scoped to the selected environment. The script prints the explicit VM/disk names it will inspect, applies a scoped Terraform destroy plan, checks for leftover selected-environment VMs/disks, and reports anything that remains. It does not delete broad name matches outside the selected environment.

## One-command deployment

After configuring `terraform.tfvars` and authenticating, run:

```powershell
.\deploy.ps1
```

This one command initializes and validates Terraform, creates and applies a saved plan, creates one control-plane VM plus `worker_count` worker VM(s), runs the current bootstrap revision, joins the workers, and verifies the Kubernetes nodes, Metrics Server, Helm, standalone Kustomize, crictl, etcdctl, Gateway API CRDs, cert-manager, NGINX Gateway Fabric, Local Path Provisioner, Argo CD, and PostgreSQL. The control-plane bootstrap is [scripts/bootstrap-kubernetes.sh](scripts/bootstrap-kubernetes.sh), and worker bootstrap is [scripts/bootstrap-worker.sh](scripts/bootstrap-worker.sh); Terraform sends them to Compute Engine as startup-script metadata.

When `KubeBuild` is selected, `deploy.ps1` creates only:

- `abhis-kube-build-control-plane`
- `abhis-kube-build-worker-1`

Those VMs use Ubuntu 24.04 LTS, OS Login, the default VPC, and an internal firewall tag that allows the two build VMs to communicate privately. They do not receive Kubernetes startup scripts. To avoid needing a fifth regional external IP, the kube-build worker is created without an external IP and is accessed through IAP:

```powershell
gcloud compute ssh abhis-kube-build-worker-1 --project <project-id> --zone <zone> --tunnel-through-iap
```

The automated health checks disable strict SSH host-key checking. This is intentional for the disposable lab: deleting and recreating a VM can assign a previously used IP address with a new host key. The destination IP is read directly from Terraform's authenticated GCP state, and no general SSH configuration on the laptop is changed.

On Windows, the deployment also removes only the PuTTY host-key cache entries associated with the Terraform-reported VM IP. This prevents a deliberately recreated VM from being rejected when GCP reuses its previous address. The initial SSH/bootstrap command retries while SSH and OS Login initialize instead of failing on the first connection attempt.

On Windows, the scripts use the Cloud SDK's `gcloud.cmd` launcher instead of its PowerShell wrapper. This allows the readiness loop to treat temporary SSH errors such as `Connection refused` as expected while the VM boots, retrying until the deployment timeout instead of terminating immediately.

The software installed inside the VM is defined in [`scripts/bootstrap-kubernetes.sh`](scripts/bootstrap-kubernetes.sh). To add another Ubuntu package later, place its repository setup and `apt-get install` command alongside the Helm installation block, then update `COMPLETION_MARKER` so an existing VM does not skip the changed bootstrap.

Private practice manifests can be placed at `local-practice/personal-practice.yaml`. Private VM-side setup commands can be placed at `local-practice/personal-practice.sh`. If either file exists on your laptop when you run `.\deploy.ps1`, Terraform embeds it into VM metadata and the bootstrap applies/runs it after the core cluster add-ons are ready. The `local-practice/` folder is ignored by Git, so personal exam-question setups stay off the public repo.

Cluster readiness is based on the node and managed workload rollouts rather than every historical pod. This avoids false failures when Kubernetes replaces a pod during an update and the superseded pod is still terminating.

If local PowerShell policy blocks scripts, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```

## Validate before creating anything

```powershell
terraform init
terraform fmt -check
terraform validate
terraform plan -out main.tfplan
```

Read the plan carefully. A plan does not create cloud resources.

## Create and test the VM

```powershell
terraform apply main.tfplan
terraform output ssh_command
```

Run the command printed by `terraform output -raw ssh_command` to connect:

```powershell
terraform output -raw ssh_command
```

After connecting, a basic test is:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A
```

The startup script runs asynchronously after the VM boots. Follow its progress with:

```bash
sudo tail -f /var/log/cka-bootstrap.log
```

The final control-plane log line is `Kubernetes bootstrap completed successfully`. Worker nodes write `/var/log/cka-worker-bootstrap.log` and finish with `Worker bootstrap completed successfully`. The scripts are idempotent and record successful completion under `/var/lib/cka-bootstrap/`.

Metrics Server is included, so resource usage commands work after bootstrap:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top nodes
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top pods -A
```

Verify Helm with:

```bash
helm version --short
```

Verify standalone Kustomize with:

```bash
kustomize version
```

Inspect containerd containers, pod sandboxes, images, and logs with crictl:

```bash
sudo crictl ps -a
sudo crictl pods
sudo crictl images
sudo crictl logs <container-id>
```

The bootstrap writes `/etc/crictl.yaml`, pointing both CRI endpoints to containerd's socket. Use `sudo crictl info` to inspect the runtime configuration.

Verify etcdctl with:

```bash
etcdctl version
```

Create PVCs for storage practice with:

```yaml
storageClassName: local-path
```

Verify the StorageClass with:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get storageclass local-path
```

Verify the Gateway API CRDs, cert-manager resources, NGINX Gateway Fabric, and PostgreSQL with:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf api-resources --api-group gateway.networking.k8s.io
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf api-resources --api-group cert-manager.io
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf api-resources --api-group argoproj.io
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get crd issuers.cert-manager.io clusterissuers.cert-manager.io certificates.cert-manager.io
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n cert-manager
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get clusterissuer cka-selfsigned
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get issuer,certificate,secret -n cert-manager-practice
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods,svc -n nginx-gateway
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods,svc -n argocd
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods,service,pvc -n database
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf exec -n database deployment/postgres -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT version();"'
```

The cert-manager practice namespace creates a self-signed `Certificate` named `cka-sample-cert` and stores its TLS material in the `cka-sample-tls` Secret. It is for CRD and certificate workflow practice only; it is not trusted by browsers or external clients.

Argo CD is installed from the official non-HA manifest into the `argocd` namespace. This is enough for GitOps and CRD practice in the lab cluster. To open the UI during practice, forward the API server service locally from the control-plane VM:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf port-forward svc/argocd-server -n argocd 8080:443
```

The PostgreSQL Service is cluster-internal at `postgres.database.svc.cluster.local:5432`. Its generated username, password, and database name are stored in the `postgres-credentials` Secret. The hostPath-backed volume is suitable for this disposable single-node practice cluster, not for a production database.

Worker VMs default to `e2-small`, but the control-plane defaults to `e2-medium`. This is intentional: `e2-small` has only about 2 GB RAM, and Helm/chart rendering plus the Kubernetes control-plane can trigger Linux OOM kills on that size. Use `worker_machine_type = "e2-medium"` too only if your practice workloads need more worker memory.

## Troubleshooting

If deployment times out, the error output prints the SSH command needed to inspect the bootstrap log. After connecting, run:

```bash
sudo tail -n 100 /var/log/cka-bootstrap.log
```

Useful local checks:

```powershell
terraform state list
terraform output
terraform plan
```

- `Connection refused` during initial boot is retried automatically.
- Recreated-VM SSH host-key changes are handled only for the automated lab checks.
- If Google has revoked or expired credentials, the script opens the required browser login flow.
- If VM creation reports that the `default` network is missing, create or select a project with a default VPC before retrying.
- Do not delete `terraform.tfstate` while resources exist; it is how `destroy.ps1` knows what to remove.

## Remove the billable resources

When testing is complete, run:

```powershell
.\destroy.ps1
```

The script authenticates when necessary, creates a destroy plan, and requires you to type `DELETE` before applying it. For unattended automation, `.\destroy.ps1 -AutoApprove` skips that confirmation and should be used carefully. After Terraform destroy, the wrapper checks for leftover lab-tagged VMs and lab-name-prefixed disks and deletes them so disposable lab resources do not keep billing accidentally.

Terraform intentionally leaves the Compute Engine API enabled when resources are destroyed. Terraform state is local to this folder, so keep the folder and its state file until resources have been destroyed.
