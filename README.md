# CKA practice infrastructure

This Terraform configuration creates a single-node CKA practice lab:

- one small Ubuntu 24.04 LTS Compute Engine VM;
- an external IP address on the project's existing `default` network;
- OS Login for SSH access;
- containerd and a `kubeadm` Kubernetes 1.36 control plane;
- crictl v1.36.0, configured to inspect and debug the containerd runtime.
- Calico networking, with the control-plane taint removed so practice workloads can run on the node.
- Helm, installed from the current Buildkite-hosted Debian repository.
- standalone Kustomize v5.8.1, verified against its published SHA-256 checksum.
- Gateway API v1.5.1 standard CRDs and NGINX Gateway Fabric installed by Helm as a NodePort service.
- PostgreSQL 18.4 with generated credentials and persistent single-node storage.

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

Set at least `project_id` in `terraform.tfvars`, save the file, and close Notepad before running the deployment command. The script handles Terraform initialization, authentication checks, VM creation, Kubernetes bootstrap, and health verification.

When deployment finishes, it prints the exact `gcloud compute ssh` command. After connecting to the VM, verify the lab with:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top nodes
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top pods -A
```

When finished practising, return to PowerShell in the cloned repository and run:

```powershell
.\destroy.ps1
```

Type `DELETE` when prompted. Keep the cloned folder and its local Terraform state until destruction completes.

## Repository layout

| Path | Purpose |
| --- | --- |
| `main.tf` | Creates the Compute Engine API setting and Ubuntu VM |
| `variables.tf` | Defines configurable project, location, VM, disk, and label inputs |
| `terraform.tfvars.example` | Safe template for local configuration |
| `deploy.ps1` | One-command create, bootstrap, wait, and verification workflow |
| `destroy.ps1` | One-command destroy workflow with confirmation |
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
| `boot_disk_size_gb` | Boot disk size | `30` |

## One-command deployment

After configuring `terraform.tfvars` and authenticating, run:

```powershell
.\deploy.ps1
```

This one command initializes and validates Terraform, creates and applies a saved plan, runs the current bootstrap revision, and verifies the Kubernetes node, Metrics Server, Helm, standalone Kustomize, crictl, Gateway API CRDs, NGINX Gateway Fabric, and PostgreSQL. The complete VM-side installation code is [scripts/bootstrap-kubernetes.sh](scripts/bootstrap-kubernetes.sh); Terraform sends it to Compute Engine as startup-script metadata.

The automated health checks disable strict SSH host-key checking. This is intentional for the disposable lab: deleting and recreating a VM can assign a previously used IP address with a new host key. The destination IP is read directly from Terraform's authenticated GCP state, and no general SSH configuration on the laptop is changed.

On Windows, the deployment also removes only the PuTTY host-key cache entries associated with the Terraform-reported VM IP. This prevents a deliberately recreated VM from being rejected when GCP reuses its previous address. The initial SSH/bootstrap command retries while SSH and OS Login initialize instead of failing on the first connection attempt.

On Windows, the scripts use the Cloud SDK's `gcloud.cmd` launcher instead of its PowerShell wrapper. This allows the readiness loop to treat temporary SSH errors such as `Connection refused` as expected while the VM boots, retrying until the deployment timeout instead of terminating immediately.

The software installed inside the VM is defined in [`scripts/bootstrap-kubernetes.sh`](scripts/bootstrap-kubernetes.sh). To add another Ubuntu package later, place its repository setup and `apt-get install` command alongside the Helm installation block, then update `COMPLETION_MARKER` so an existing VM does not skip the changed bootstrap.

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

The final log line is `Kubernetes bootstrap completed successfully`. The script is idempotent and records successful completion under `/var/lib/cka-bootstrap/`.

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

Verify the Gateway API CRDs, NGINX Gateway Fabric, and PostgreSQL with:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf api-resources --api-group gateway.networking.k8s.io
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods,svc -n nginx-gateway
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods,service,pvc -n database
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf exec -n database deployment/postgres -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT version();"'
```

The PostgreSQL Service is cluster-internal at `postgres.database.svc.cluster.local:5432`. Its generated username, password, and database name are stored in the `postgres-credentials` Secret. The hostPath-backed volume is suitable for this disposable single-node practice cluster, not for a production database.

The default `e2-small` VM has only 2 GB RAM, which is Kubernetes' practical minimum. Change `machine_type` to `e2-medium` if mock workloads encounter memory pressure.

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

The script authenticates when necessary, creates a destroy plan, and requires you to type `DELETE` before applying it. For unattended automation, `.\destroy.ps1 -AutoApprove` skips that confirmation and should be used carefully.

Terraform intentionally leaves the Compute Engine API enabled when resources are destroyed. Terraform state is local to this folder, so keep the folder and its state file until resources have been destroyed.
