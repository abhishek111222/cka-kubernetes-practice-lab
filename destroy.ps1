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
Ensure-GcpAuthentication

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
Write-Host "Destruction complete."
