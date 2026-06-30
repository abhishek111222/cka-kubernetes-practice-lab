[CmdletBinding()]
param(
  [ValidateRange(5, 60)]
  [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)]
    [string]$Command,

    [Parameter(Mandatory)]
    [string[]]$Arguments
  )

  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $Command $($Arguments -join ' ')"
  }
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

if (-not (Test-Path -LiteralPath "terraform.tfvars")) {
  throw "terraform.tfvars is missing. Copy terraform.tfvars.example to terraform.tfvars and set your GCP values."
}

foreach ($command in @("terraform", "gcloud")) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "$command is not installed or is not available on PATH."
  }
}

. (Join-Path $root "scripts\gcp-auth.ps1")
Ensure-GcpAuthentication

Write-Host "Initializing and validating Terraform..."
Invoke-NativeCommand -Command "terraform" -Arguments @("init", "-input=false")
Invoke-NativeCommand -Command "terraform" -Arguments @("validate")

Write-Host "Creating the reviewed Terraform execution plan..."
Invoke-NativeCommand -Command "terraform" -Arguments @("plan", "-input=false", "-out", "deploy.tfplan")

Write-Host "Applying infrastructure and Kubernetes bootstrap metadata..."
Invoke-NativeCommand -Command "terraform" -Arguments @("apply", "-input=false", "deploy.tfplan")

$instanceName = (& terraform output -raw instance_name).Trim()
$projectId = (& terraform output -raw project_id).Trim()
$zone = (& terraform output -raw instance_zone).Trim()

if ($LASTEXITCODE -ne 0) {
  throw "Terraform outputs could not be read after apply."
}

Write-Host "Waiting for Kubernetes bootstrap on $instanceName..."
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$ready = $false

while ((Get-Date) -lt $deadline) {
  $marker = & gcloud compute ssh $instanceName `
    --project $projectId `
    --zone $zone `
    --strict-host-key-checking=no `
    --command "sudo find /var/lib/cka-bootstrap -maxdepth 1 -name '*.complete' -print -quit" `
    --quiet 2>$null

  if ($LASTEXITCODE -eq 0 -and $marker -match "/var/lib/cka-bootstrap/.+\.complete") {
    $ready = $true
    break
  }

  Write-Host "Cluster bootstrap is still running..."
  Start-Sleep -Seconds 10
}

if (-not $ready) {
  throw "Cluster did not become ready within $TimeoutMinutes minutes. Connect to the VM and run: sudo tail -n 100 /var/log/cka-bootstrap.log"
}

Write-Host "Verifying Kubernetes node health..."
Invoke-NativeCommand -Command "gcloud" -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide",
  "--quiet"
)

Write-Host "Verifying Metrics Server..."
Invoke-NativeCommand -Command "gcloud" -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top nodes",
  "--quiet"
)

Write-Host "Deployment complete."
Write-Host "Connect with: gcloud compute ssh $instanceName --project $projectId --zone $zone"
