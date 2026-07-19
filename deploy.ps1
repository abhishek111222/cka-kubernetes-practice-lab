[CmdletBinding()]
param(
  [ValidateRange(5, 60)]
  [int]$TimeoutMinutes = 30
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

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    & $Command @Arguments
    $nativeExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if ($nativeExitCode -ne 0) {
    throw "Command failed with exit code ${nativeExitCode}: $Command $($Arguments -join ' ')"
  }
}

function Clear-PuttyHostKeyForAddress {
  param(
    [Parameter(Mandatory)]
    [string]$IpAddress
  )

  if ($env:OS -ne "Windows_NT") {
    return
  }

  $puttyHostKeyPath = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
  if (-not (Test-Path -LiteralPath $puttyHostKeyPath)) {
    return
  }

  $cachedKeyNames = (Get-ItemProperty -LiteralPath $puttyHostKeyPath).PSObject.Properties |
    Where-Object { $_.Name -like "*@22:${IpAddress}" } |
    Select-Object -ExpandProperty Name

  foreach ($cachedKeyName in $cachedKeyNames) {
    Write-Host "Removing stale PuTTY host key for ${IpAddress}..."
    Remove-ItemProperty -LiteralPath $puttyHostKeyPath -Name $cachedKeyName
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
$gcloudCommand = Get-GcloudCommand
Ensure-GcpAuthentication -GcloudCommand $gcloudCommand

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
$externalIp = (& terraform output -raw external_ip).Trim()
$workerNamesJson = (& terraform output -json worker_names).Trim()

if ($LASTEXITCODE -ne 0) {
  throw "Terraform outputs could not be read after apply."
}

$bootstrapScript = Get-Content -LiteralPath (Join-Path $root "scripts\bootstrap-kubernetes.sh") -Raw
if ($bootstrapScript -notmatch '(?m)^BOOTSTRAP_REVISION="([^"]+)"$') {
  throw "BOOTSTRAP_REVISION could not be read from scripts/bootstrap-kubernetes.sh."
}

$bootstrapRevision = $Matches[1]
$completionMarker = "/var/lib/cka-bootstrap/${bootstrapRevision}.complete"
$workerNames = [string[]](ConvertFrom-Json -InputObject $workerNamesJson)
$expectedNodeCount = 1 + $workerNames.Count

Clear-PuttyHostKeyForAddress -IpAddress $externalIp

Write-Host "Starting bootstrap revision $bootstrapRevision..."
$sshDeadline = (Get-Date).AddMinutes([Math]::Min(5, $TimeoutMinutes))
$bootstrapStarted = $false

while ((Get-Date) -lt $sshDeadline) {
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"

  try {
    & $gcloudCommand compute ssh $instanceName `
      --project $projectId `
      --zone $zone `
      --strict-host-key-checking=no `
      --command "sudo sh -c 'nohup google_metadata_script_runner startup >/var/log/cka-bootstrap-runner.log 2>&1 </dev/null &'" `
      --quiet 2>$null
    $sshExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if ($sshExitCode -eq 0) {
    $bootstrapStarted = $true
    break
  }

  Write-Host "SSH and OS Login are not ready yet; retrying bootstrap start..."
  Start-Sleep -Seconds 10
}

if (-not $bootstrapStarted) {
  throw "SSH and OS Login did not become ready within five minutes. Run the printed gcloud SSH command with --troubleshoot."
}

Write-Host "Waiting for Kubernetes bootstrap on $instanceName and $($workerNames.Count) worker node(s)..."
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$ready = $false

while ((Get-Date) -lt $deadline) {
  # SSH can legitimately refuse connections while a new VM is still booting.
  # Temporarily suppress native stderr so the loop can inspect the exit code
  # and retry instead of ErrorActionPreference terminating the whole script.
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"

  try {
    $marker = & $gcloudCommand compute ssh $instanceName `
      --project $projectId `
      --zone $zone `
      --strict-host-key-checking=no `
      --command "sudo test -f '$completionMarker' && echo '$completionMarker'" `
      --quiet 2>$null
    $sshExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if ($sshExitCode -eq 0 -and $marker -eq $completionMarker) {
    $ready = $true
    break
  }

  Write-Host "Cluster bootstrap is still running..."
  Start-Sleep -Seconds 10
}

if (-not $ready) {
  throw "Cluster did not become ready within $TimeoutMinutes minutes. Connect to the VM and run: sudo tail -n 100 /var/log/cka-bootstrap.log"
}

Write-Host "Waiting for $expectedNodeCount Kubernetes node(s) to be registered..."
$nodeDeadline = (Get-Date).AddMinutes(10)
$nodeCountReady = $false

while ((Get-Date) -lt $nodeDeadline) {
  $nodeCountText = & $gcloudCommand compute ssh $instanceName `
    --project $projectId `
    --zone $zone `
    --strict-host-key-checking=no `
    --command "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes --no-headers 2>/dev/null | wc -l" `
    --quiet

  if ($LASTEXITCODE -eq 0 -and [int]($nodeCountText.Trim()) -eq $expectedNodeCount) {
    $nodeCountReady = $true
    break
  }

  Write-Host "Waiting for all expected nodes to register..."
  Start-Sleep -Seconds 10
}

if (-not $nodeCountReady) {
  throw "Expected $expectedNodeCount Kubernetes node(s), but they did not all register within 10 minutes."
}

Write-Host "Verifying Kubernetes node health..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide",
  "--quiet"
)

Write-Host "Verifying expected Kubernetes node count..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "test `$(sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes --no-headers | wc -l) -eq $expectedNodeCount",
  "--quiet"
)

Write-Host "Verifying Metrics Server..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top nodes",
  "--quiet"
)

Write-Host "Verifying Helm..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "helm version --short",
  "--quiet"
)

Write-Host "Verifying standalone Kustomize..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "kustomize version",
  "--quiet"
)

Write-Host "Verifying crictl and its containerd connection..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo crictl ps -a",
  "--quiet"
)

Write-Host "Verifying etcdctl..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "etcdctl version",
  "--quiet"
)

Write-Host "Verifying Gateway API CRDs..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io",
  "--quiet"
)

Write-Host "Verifying NGINX Gateway Fabric..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods,svc -n nginx-gateway && sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get gatewayclass nginx",
  "--quiet"
)

Write-Host "Verifying Local Path Provisioner..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get storageclass local-path && sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n local-path-storage",
  "--quiet"
)

Write-Host "Verifying PostgreSQL..."
Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
  "compute", "ssh", $instanceName,
  "--project", $projectId,
  "--zone", $zone,
  "--strict-host-key-checking=no",
  "--command", "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf exec -n database deployment/postgres -- psql -U cka -d cka -v ON_ERROR_STOP=1 -tAc SELECT/**/1",
  "--quiet"
)

Write-Host "Deployment complete."
Write-Host "Connect with: gcloud compute ssh $instanceName --project $projectId --zone $zone"
