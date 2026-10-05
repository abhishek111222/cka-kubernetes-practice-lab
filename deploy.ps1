[CmdletBinding()]
param(
  [ValidateRange(5, 60)]
  [int]$TimeoutMinutes = 60,

  [string[]]$ZoneCandidates = @(),

  [string[]]$MachineTypeCandidates = @("e2-small", "e2-medium"),

  [ValidateSet("Prompt", "Cka", "KubeBuild", "Both")]
  [string]$Environment = "Prompt"
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

function Invoke-NativeCommandWithOutput {
  param(
    [Parameter(Mandatory)]
    [string]$Command,

    [Parameter(Mandatory)]
    [string[]]$Arguments
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    $output = & $Command @Arguments 2>&1
    $nativeExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  [PSCustomObject]@{
    ExitCode = $nativeExitCode
    Output   = @($output)
  }
}

function Test-GcpCapacityError {
  param(
    [Parameter(Mandatory)]
    [string]$Output
  )

  return $Output -match "does not have enough resources available" -or
    $Output -match "VM instance is currently unavailable" -or
    $Output -match "ZONE_RESOURCE_POOL_EXHAUSTED" -or
    $Output -match "resource.*unavailable"
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

function Select-LabEnvironment {
  param(
    [Parameter(Mandatory)]
    [ValidateSet("Prompt", "Cka", "KubeBuild", "Both")]
    [string]$RequestedEnvironment
  )

  if ($RequestedEnvironment -ne "Prompt") {
    return $RequestedEnvironment
  }

  Write-Host ""
  Write-Host "Select environment to create/deploy:"
  Write-Host "1. Existing CKA cluster only"
  Write-Host "2. Build-from-scratch VMs only"
  Write-Host "3. Both environments"
  Write-Host "4. Cancel"
  $selection = Read-Host "Enter 1, 2, 3, or 4"

  switch ($selection) {
    "1" { return "Cka" }
    "2" { return "KubeBuild" }
    "3" { return "Both" }
    "4" {
      Write-Host "Cancelled. No resources were changed."
      exit 0
    }
    default {
      throw "Invalid selection."
    }
  }
}

function Get-TerraformTargetArguments {
  param(
    [Parameter(Mandatory)]
    [ValidateSet("Cka", "KubeBuild", "Both")]
    [string]$SelectedEnvironment
  )

  $targets = switch ($SelectedEnvironment) {
    "Cka" {
      @(
        "google_project_service.compute",
        "google_compute_firewall.cka_internal",
        "google_compute_instance.control_plane",
        "google_compute_instance.worker"
      )
    }
    "KubeBuild" {
      @(
        "google_project_service.compute",
        "google_compute_firewall.kube_build_internal",
        "google_compute_instance.kube_build_control_plane",
        "google_compute_instance.kube_build_worker"
      )
    }
    "Both" {
      @()
    }
  }

  $arguments = @()
  foreach ($target in $targets) {
    $arguments += @("-target", $target)
  }

  return $arguments
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
$selectedEnvironment = Select-LabEnvironment -RequestedEnvironment $Environment
$targetArguments = Get-TerraformTargetArguments -SelectedEnvironment $selectedEnvironment

Write-Host "Selected environment: $selectedEnvironment"

Write-Host "Initializing and validating Terraform..."
Invoke-NativeCommand -Command "terraform" -Arguments @("init", "-input=false")
Invoke-NativeCommand -Command "terraform" -Arguments @("validate")

$tfvarsContent = Get-Content -LiteralPath "terraform.tfvars" -Raw
$region = if ($tfvarsContent -match '(?m)^\s*region\s*=\s*"([^"]+)"') { $Matches[1] } else { "europe-west2" }
$configuredZone = if ($tfvarsContent -match '(?m)^\s*zone\s*=\s*"([^"]+)"') { $Matches[1] } else { "${region}-a" }

if ($ZoneCandidates.Count -eq 0) {
  $ZoneCandidates = @($configuredZone, "${region}-b", "${region}-c") |
    Select-Object -Unique
}

$terraformApplySucceeded = $false
$lastApplyOutput = @()
$initialStateResult = Invoke-NativeCommandWithOutput -Command "terraform" -Arguments @("state", "list")
$initialStateLines = @($initialStateResult.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$initialStateHadInstances = @($initialStateLines | Where-Object { $_ -like "google_compute_instance.*" }).Count -gt 0

foreach ($candidateMachineType in $MachineTypeCandidates) {
  foreach ($candidateZone in $ZoneCandidates) {
    Write-Host "Creating the reviewed Terraform execution plan for zone ${candidateZone} and machine type ${candidateMachineType}..."
    $planArguments = @(
      "plan",
      "-input=false",
      "-out", "deploy.tfplan",
      "-var", "zone=${candidateZone}",
      "-var", "machine_type=${candidateMachineType}",
      "-var", "control_plane_machine_type=${candidateMachineType}",
      "-var", "worker_machine_type=${candidateMachineType}"
    ) + $targetArguments
    $planResult = Invoke-NativeCommandWithOutput -Command "terraform" -Arguments $planArguments

    if ($planResult.Output) {
      $planResult.Output | ForEach-Object { Write-Host $_ }
    }

    if ($planResult.ExitCode -ne 0) {
      throw "Terraform plan failed for zone ${candidateZone} and machine type ${candidateMachineType}."
    }

    Write-Host "Applying infrastructure and Kubernetes bootstrap metadata..."
    $applyResult = Invoke-NativeCommandWithOutput -Command "terraform" -Arguments @("apply", "-input=false", "deploy.tfplan")
    $lastApplyOutput = $applyResult.Output

    if ($lastApplyOutput) {
      $lastApplyOutput | ForEach-Object { Write-Host $_ }
    }

    if ($applyResult.ExitCode -eq 0) {
      $terraformApplySucceeded = $true
      break
    }

    $applyOutputText = $lastApplyOutput -join [Environment]::NewLine
    if (-not (Test-GcpCapacityError -Output $applyOutputText)) {
      throw "Terraform apply failed for a non-capacity reason in zone ${candidateZone} with machine type ${candidateMachineType}."
    }

    Write-Host "GCP capacity was unavailable in zone ${candidateZone} with machine type ${candidateMachineType}; trying the next option..."
    if ($initialStateHadInstances) {
      throw "Capacity was unavailable, and Terraform already had VM instances in state before this deploy. Refusing automatic fallback to avoid changing an existing cluster. Run .\destroy.ps1 first if you want a fresh fallback deploy."
    }
  }

  if ($terraformApplySucceeded) {
    break
  }
}

if (-not $terraformApplySucceeded) {
  if ($lastApplyOutput) {
    $lastApplyOutput | ForEach-Object { Write-Host $_ }
  }

  throw "Terraform apply failed because none of the configured zone/machine type combinations had capacity."
}

if ($selectedEnvironment -eq "KubeBuild") {
  Write-Host "Build-from-scratch VM deployment complete."
  Write-Host "These VMs intentionally have no Kubernetes installation or bootstrap applied."
  terraform output kube_build_ssh_commands
  exit 0
}

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

function Invoke-ControlPlaneCommand {
  param(
    [Parameter(Mandatory)]
    [string]$RemoteCommand,

    [ValidateRange(1, 20)]
    [int]$Retries = 6
  )

  $lastOutput = @()
  $lastExitCode = 0

  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
      $lastOutput = & $gcloudCommand compute ssh $instanceName `
        --project $projectId `
        --zone $zone `
        --strict-host-key-checking=no `
        --command $RemoteCommand `
        --quiet 2>&1
      $lastExitCode = $LASTEXITCODE
    }
    finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($lastExitCode -eq 0) {
      if ($lastOutput) {
        $lastOutput | ForEach-Object { Write-Host $_ }
      }
      return
    }

    if ($attempt -lt $Retries) {
      Write-Host "SSH verification command failed on attempt ${attempt}/${Retries}; retrying..."
      Clear-PuttyHostKeyForAddress -IpAddress $externalIp
      Start-Sleep -Seconds 10
    }
  }

  if ($lastOutput) {
    $lastOutput | ForEach-Object { Write-Host $_ }
  }

  throw "Command failed after ${Retries} attempt(s): gcloud compute ssh $instanceName --project $projectId --zone $zone --command $RemoteCommand"
}

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
Invoke-ControlPlaneCommand -RemoteCommand "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide"

Write-Host "Verifying expected Kubernetes node count..."
Invoke-ControlPlaneCommand -RemoteCommand "test `$(sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes --no-headers | wc -l) -eq $expectedNodeCount"

Write-Host "Verifying Metrics Server..."
Invoke-ControlPlaneCommand -RemoteCommand "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf top nodes"

Write-Host "Verifying Helm..."
Invoke-ControlPlaneCommand -RemoteCommand "helm version --short"

Write-Host "Verifying standalone Kustomize..."
Invoke-ControlPlaneCommand -RemoteCommand "kustomize version"

Write-Host "Verifying crictl and its containerd connection..."
Invoke-ControlPlaneCommand -RemoteCommand "sudo crictl ps -a"

Write-Host "Verifying etcdctl..."
Invoke-ControlPlaneCommand -RemoteCommand "etcdctl version"

Write-Host "Verifying Gateway API CRDs..."
Invoke-ControlPlaneCommand -RemoteCommand "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io"

Write-Host "Verifying cert-manager CRDs and practice resources..."
Invoke-ControlPlaneCommand -RemoteCommand "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get crd issuers.cert-manager.io clusterissuers.cert-manager.io certificates.cert-manager.io && sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get clusterissuer cka-selfsigned && sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get issuer,certificate -n cert-manager-practice"

Write-Host "Verifying NGINX Gateway Fabric..."
Invoke-ControlPlaneCommand -RemoteCommand "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods,svc -n nginx-gateway && sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get gatewayclass nginx"

Write-Host "Verifying Local Path Provisioner..."
Invoke-ControlPlaneCommand -RemoteCommand "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get storageclass local-path && sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n local-path-storage"

Write-Host "Verifying Argo CD..."
Invoke-ControlPlaneCommand -RemoteCommand "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get crd applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io && sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get pods,svc -n argocd"

Write-Host "Verifying PostgreSQL..."
Invoke-ControlPlaneCommand -RemoteCommand "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf exec -n database deployment/postgres -- psql -U cka -d cka -v ON_ERROR_STOP=1 -tAc SELECT/**/1"

Write-Host "Deployment complete."
Write-Host "Connect with: gcloud compute ssh $instanceName --project $projectId --zone $zone"
