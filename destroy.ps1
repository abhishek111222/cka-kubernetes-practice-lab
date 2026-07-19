[CmdletBinding()]
param(
  [switch]$AutoApprove
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

$projectId = (& terraform output -raw project_id 2>$null).Trim()
$controlPlaneName = (& terraform output -raw instance_name 2>$null).Trim()
$baseName = $controlPlaneName -replace "-control-plane$", ""

Write-Host "Initializing and validating Terraform..."
Invoke-NativeCommand -Command "terraform" -Arguments @("init", "-input=false")
Invoke-NativeCommand -Command "terraform" -Arguments @("validate")

Write-Host "Creating the destroy plan..."
Invoke-NativeCommand -Command "terraform" -Arguments @("plan", "-destroy", "-input=false", "-out", "destroy.tfplan")

if (-not $AutoApprove) {
  $confirmation = Read-Host "Type DELETE to apply this destroy plan"
  if ($confirmation -cne "DELETE") {
    Write-Host "Destruction cancelled. No resources were changed."
    exit 0
  }
}

Write-Host "Applying the reviewed destroy plan..."
Invoke-NativeCommand -Command "terraform" -Arguments @("apply", "-input=false", "destroy.tfplan")

if ($projectId -and $baseName) {
  Write-Host "Checking for leftover lab VMs and disks..."

  $leftoverInstances = & $gcloudCommand compute instances list `
    --project $projectId `
    --format "csv[no-heading](name,zone.basename(),tags.items)"

  foreach ($line in @($leftoverInstances)) {
    if (-not $line) {
      continue
    }

    $parts = $line.Split(",", 3)
    if ($parts.Count -lt 3) {
      continue
    }

    $name = $parts[0]
    $zone = $parts[1]
    $tags = $parts[2]
    if ($name -like "$baseName*" -and $tags -like "*cka-practice*") {
      Write-Host "Deleting leftover lab VM ${name} in ${zone}..."
      Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
        "compute", "instances", "delete", $name,
        "--project", $projectId,
        "--zone", $zone,
        "--quiet"
      )
    }
  }

  $leftoverDisks = & $gcloudCommand compute disks list `
    --project $projectId `
    --format "csv[no-heading](name,zone.basename())"

  foreach ($line in @($leftoverDisks)) {
    if (-not $line) {
      continue
    }

    $parts = $line.Split(",", 2)
    if ($parts.Count -ne 2) {
      continue
    }

    $name = $parts[0]
    $zone = $parts[1]
    if ($name -notlike "$baseName*") {
      continue
    }

    Write-Host "Deleting leftover lab disk ${name} in ${zone}..."
    Invoke-NativeCommand -Command $gcloudCommand -Arguments @(
      "compute", "disks", "delete", $name,
      "--project", $projectId,
      "--zone", $zone,
      "--quiet"
    )
  }
}

Write-Host "Destruction complete."
