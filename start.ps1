[CmdletBinding()]
param(
  [ValidateSet("Prompt", "Cka", "KubeBuild", "Both")]
  [string]$Environment = "Prompt"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
  Write-Host "Select environment to start:"
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

. (Join-Path $root "scripts\gcp-auth.ps1")
$gcloudCommand = Get-GcloudCommand
Ensure-GcpAuthentication -GcloudCommand $gcloudCommand

$tfvarsContent = Get-Content -LiteralPath "terraform.tfvars" -Raw
$projectId = if ($tfvarsContent -match '(?m)^\s*project_id\s*=\s*"([^"]+)"') { $Matches[1] } else { (& terraform output -raw project_id 2>$null).Trim() }
$baseName = if ($tfvarsContent -match '(?m)^\s*instance_name\s*=\s*"([^"]+)"') { $Matches[1] } else { "abhis-cka-vm" }
$kubeBuildBaseName = if ($tfvarsContent -match '(?m)^\s*kube_build_instance_name\s*=\s*"([^"]+)"') { $Matches[1] } else { "abhis-kube-build" }
$workerCount = if ($tfvarsContent -match '(?m)^\s*worker_count\s*=\s*([0-9]+)') { [int]$Matches[1] } else { 2 }
$selectedEnvironment = Select-LabEnvironment -RequestedEnvironment $Environment
$expectedNames = Get-EnvironmentInstanceNames -SelectedEnvironment $selectedEnvironment -BaseName $baseName -KubeBuildBaseName $kubeBuildBaseName -WorkerCount $workerCount

Write-Host "Selected environment: $selectedEnvironment"

$instances = & $gcloudCommand compute instances list `
  --project $projectId `
  --format "csv[no-heading](name,zone.basename(),status)"

foreach ($line in @($instances)) {
  if (-not $line) {
    continue
  }

  $parts = $line.Split(",", 3)
  if ($parts.Count -ne 3) {
    continue
  }

  $name = $parts[0]
  $zone = $parts[1]
  $status = $parts[2]
  if ($expectedNames -notcontains $name) {
    continue
  }

  if ($status -eq "RUNNING") {
    Write-Host "${name} is already RUNNING."
    continue
  }

  Write-Host "Starting ${name} in ${zone}..."
  Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
    "compute", "instances", "start", $name,
    "--project", $projectId,
    "--zone", $zone
  )
}

Write-Host "Start operation complete."
