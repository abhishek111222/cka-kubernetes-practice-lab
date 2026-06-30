# CKA practice infrastructure

This Terraform configuration creates a single-node CKA practice lab:

- one small Ubuntu 24.04 LTS Compute Engine VM;
- an external IP address on the project's existing `default` network;
- OS Login for SSH access;
- containerd and a `kubeadm` Kubernetes 1.36 control plane;
- Calico networking, with the control-plane taint removed so practice workloads can run on the node.

## Prerequisites

Install these tools on the laptop:

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install)
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.6 or later

The selected GCP project must have billing enabled and an existing `default` VPC with an SSH firewall rule. The signed-in account needs permission to enable project services and create Compute Engine resources.

## Authentication

The deployment and destruction scripts check both credential sets used by this project:

- Google Cloud CLI credentials, used by `gcloud`;
- Application Default Credentials, used by Terraform.

When valid cached credentials exist, authentication is automatic. If credentials are missing, expired, or revoked, the script opens Google's browser login flow and then continues. Google requires interactive approval in those cases; the project never stores passwords, access tokens, or service-account keys.

Application Default Credentials are stored outside this repository. Do not add credential JSON files here.

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

This one command initializes and validates Terraform, creates and applies a saved plan, waits for the VM startup script, and verifies both the Kubernetes node and Metrics Server. The complete VM-side installation code is [scripts/bootstrap-kubernetes.sh](scripts/bootstrap-kubernetes.sh); Terraform sends it to Compute Engine as startup-script metadata.

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

The default `e2-small` VM has only 2 GB RAM, which is Kubernetes' practical minimum. Change `machine_type` to `e2-medium` if mock workloads encounter memory pressure.

## Remove the billable resources

When testing is complete, run:

```powershell
.\destroy.ps1
```

The script authenticates when necessary, creates a destroy plan, and requires you to type `DELETE` before applying it. For unattended automation, `.\destroy.ps1 -AutoApprove` skips that confirmation and should be used carefully.

Terraform intentionally leaves the Compute Engine API enabled when resources are destroyed. Terraform state is local to this folder, so keep the folder and its state file until resources have been destroyed.
