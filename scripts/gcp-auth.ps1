function Test-GcloudAuthentication {
  param(
    [Parameter(Mandatory)]
    [string]$GcloudCommand,

    [Parameter(Mandatory)]
    [string[]]$Arguments
  )

  & $GcloudCommand @Arguments 2>$null | Out-Null
  return $LASTEXITCODE -eq 0
}

function Get-GcloudCommand {
  # On Windows, prefer the CMD launcher. The PowerShell launcher inherits
  # ErrorActionPreference and can turn expected native stderr (for example,
  # SSH not being ready yet) into a terminating PowerShell error.
  $windowsLauncher = Get-Command "gcloud.cmd" -ErrorAction SilentlyContinue
  if ($null -ne $windowsLauncher) {
    return $windowsLauncher.Source
  }

  return "gcloud"
}

function Ensure-GcpAuthentication {
  param(
    [Parameter(Mandatory)]
    [string]$GcloudCommand
  )

  # Prefer user Application Default Credentials on a personal workstation.
  # This prevents an unrelated GOOGLE_APPLICATION_CREDENTIALS value from
  # silently selecting a stale service-account key.
  $env:GOOGLE_APPLICATION_CREDENTIALS = $null

  Write-Host "Checking Google Cloud CLI credentials..."
  if (-not (Test-GcloudAuthentication -GcloudCommand $GcloudCommand -Arguments @("auth", "print-access-token"))) {
    Write-Host "Google Cloud CLI login is required. Opening the browser login flow..."
    & $GcloudCommand auth login
    if ($LASTEXITCODE -ne 0) {
      throw "Google Cloud CLI login did not complete successfully."
    }
  }

  Write-Host "Checking Terraform Application Default Credentials..."
  if (-not (Test-GcloudAuthentication -GcloudCommand $GcloudCommand -Arguments @("auth", "application-default", "print-access-token"))) {
    Write-Host "Terraform credentials are missing or expired. Opening the browser login flow..."
    & $GcloudCommand auth application-default login
    if ($LASTEXITCODE -ne 0) {
      throw "Application Default Credentials login did not complete successfully."
    }
  }

  if (-not (Test-GcloudAuthentication -GcloudCommand $GcloudCommand -Arguments @("auth", "print-access-token"))) {
    throw "Google Cloud CLI credentials are still unavailable after login."
  }

  if (-not (Test-GcloudAuthentication -GcloudCommand $GcloudCommand -Arguments @("auth", "application-default", "print-access-token"))) {
    throw "Terraform Application Default Credentials are still unavailable after login."
  }
}
