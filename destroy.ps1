[CmdletBinding()]
param(
  [switch]$AutoApprove,

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

  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $Command $($Arguments -join ' ')"
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
  Write-Host "Select environment to delete:"
  Write-Host "1. Existing CKA cluster"
  Write-Host "2. Build-from-scratch cluster"
  Write-Host "3. Both"
  Write-Host "4. Cancel"
  $selection = Read-Host "Enter 1, 2, 3, or 4"

  switch ($selection) {
    "1" { return "Cka" }
    "2" { return "KubeBuild" }
    "3" { return "Both" }
    "4" {
      Write-Host "Destruction cancelled. No resources were changed."
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
        "google_compute_instance.worker",
        "google_compute_instance.control_plane",
        "google_compute_firewall.cka_internal"
      )
    }
    "KubeBuild" {
      @(
        "google_compute_instance.kube_build_worker",
        "google_compute_instance.kube_build_control_plane",
        "google_compute_firewall.kube_build_internal"
      )
    }
    "Both" {
      @(
        "google_compute_instance.worker",
        "google_compute_instance.control_plane",
        "google_compute_firewall.cka_internal",
        "google_compute_instance.kube_build_worker",
        "google_compute_instance.kube_build_control_plane",
        "google_compute_firewall.kube_build_internal"
      )
    }
  }

  $arguments = @()
  foreach ($target in $targets) {
    $arguments += @("-target", $target)
  }

  return $arguments
}

function Get-EnvironmentInstanceNames {
  param(
    [Parameter(Mandatory)]
    [ValidateSet("Cka", "KubeBuild", "Both")]
    [string]$SelectedEnvironment,

    [Parameter(Mandatory)]
    [string]$BaseName,

    [Parameter(Mandatory)]
    [string]$KubeBuildBaseName,

    [Parameter(Mandatory)]
    [int]$WorkerCount
  )

  $names = @()
  if ($SelectedEnvironment -in @("Cka", "Both")) {
    $names += "${BaseName}-control-plane"
    for ($index = 1; $index -le $WorkerCount; $index++) {
      $names += "${BaseName}-worker-${index}"
    }
  }

  if ($SelectedEnvironment -in @("KubeBuild", "Both")) {
    $names += "${KubeBuildBaseName}-control-plane"
    $names += "${KubeBuildBaseName}-worker-1"
  }

  return $names
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

if (-not (Test-Path -LiteralPath "terraform.tfvars")) {
  throw "terraform.tfvars is missing. Destruction requires the same project configuration used for deployment."
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

$tfvarsContent = Get-Content -LiteralPath "terraform.tfvars" -Raw
$projectId = if ($tfvarsContent -match '(?m)^\s*project_id\s*=\s*"([^"]+)"') { $Matches[1] } else { (& terraform output -raw project_id 2>$null).Trim() }
$baseName = if ($tfvarsContent -match '(?m)^\s*instance_name\s*=\s*"([^"]+)"') { $Matches[1] } else { "abhis-cka-vm" }
$kubeBuildBaseName = if ($tfvarsContent -match '(?m)^\s*kube_build_instance_name\s*=\s*"([^"]+)"') { $Matches[1] } else { "abhis-kube-build" }
$workerCount = if ($tfvarsContent -match '(?m)^\s*worker_count\s*=\s*([0-9]+)') { [int]$Matches[1] } else { 2 }
$expectedNames = Get-EnvironmentInstanceNames -SelectedEnvironment $selectedEnvironment -BaseName $baseName -KubeBuildBaseName $kubeBuildBaseName -WorkerCount $workerCount

Write-Host "Selected environment: $selectedEnvironment"
Write-Host "Expected VM/disk names in scope:"
$expectedNames | ForEach-Object { Write-Host " - $_" }

Write-Host "Initializing and validating Terraform..."
Invoke-NativeCommand -Command "terraform" -Arguments @("init", "-input=false")
Invoke-NativeCommand -Command "terraform" -Arguments @("validate")

Write-Host "Creating the scoped destroy plan..."
$destroyPlanArguments = @("plan", "-destroy", "-input=false", "-out", "destroy.tfplan") + $targetArguments
Invoke-NativeCommand -Command "terraform" -Arguments $destroyPlanArguments

Write-Host ""
Write-Host "Terraform destroy plan above is scoped to: $selectedEnvironment"
Write-Host "Post-destroy cleanup will inspect only the explicit names listed above."

if (-not $AutoApprove) {
  $confirmation = Read-Host "Type DELETE to apply this scoped destroy plan"
  if ($confirmation -cne "DELETE") {
    Write-Host "Destruction cancelled. No resources were changed."
    exit 0
  }
}

Write-Host "Applying the reviewed scoped destroy plan..."
Invoke-NativeCommand -Command "terraform" -Arguments @("apply", "-input=false", "destroy.tfplan")

if ($projectId) {
  Write-Host "Checking for leftover selected-environment VMs and disks..."

  $instances = & $gcloudCommand compute instances list `
    --project $projectId `
    --format "csv[no-heading](name,zone.basename())"

  foreach ($line in @($instances)) {
    if (-not $line) {
      continue
    }

    $parts = $line.Split(",", 2)
    if ($parts.Count -ne 2) {
      continue
    }

    $name = $parts[0]
    $zone = $parts[1]
    if ($expectedNames -notcontains $name) {
      continue
    }

    Write-Host "Deleting leftover selected VM ${name} in ${zone}..."
    Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
      "compute", "instances", "delete", $name,
      "--project", $projectId,
      "--zone", $zone,
      "--quiet"
    )
  }

  $disks = & $gcloudCommand compute disks list `
    --project $projectId `
    --format "csv[no-heading](name,zone.basename())"

  foreach ($line in @($disks)) {
    if (-not $line) {
      continue
    }

    $parts = $line.Split(",", 2)
    if ($parts.Count -ne 2) {
      continue
    }

    $name = $parts[0]
    $zone = $parts[1]
    if ($expectedNames -notcontains $name) {
      continue
    }

    Write-Host "Deleting leftover selected disk ${name} in ${zone}..."
    Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
      "compute", "disks", "delete", $name,
      "--project", $projectId,
      "--zone", $zone,
      "--quiet"
    )
  }

  Write-Host "Verifying selected environment leftovers..."
  $remainingInstances = @(& $gcloudCommand compute instances list --project $projectId --format "value(name)" | Where-Object { $expectedNames -contains $_ })
  $remainingDisks = @(& $gcloudCommand compute disks list --project $projectId --format "value(name)" | Where-Object { $expectedNames -contains $_ })

  if ($remainingInstances.Count -eq 0 -and $remainingDisks.Count -eq 0) {
    Write-Host "No selected-environment VM instances or persistent disks remain."
  }
  else {
    Write-Host "Selected-environment resources still remaining:"
    $remainingInstances | ForEach-Object { Write-Host " - VM: $_" }
    $remainingDisks | ForEach-Object { Write-Host " - Disk: $_" }
  }
}

Write-Host "Destruction complete."
