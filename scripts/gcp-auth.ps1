function Test-GcloudAuthentication {
  param(
    [Parameter(Mandatory)]
    [string[]]$Arguments
  )

  & gcloud @Arguments 2>$null | Out-Null
  return $LASTEXITCODE -eq 0
}

function Ensure-GcpAuthentication {
  # Prefer user Application Default Credentials on a personal workstation.
  # This prevents an unrelated GOOGLE_APPLICATION_CREDENTIALS value from
  # silently selecting a stale service-account key.
  $env:GOOGLE_APPLICATION_CREDENTIALS = $null

  Write-Host "Checking Google Cloud CLI credentials..."
  if (-not (Test-GcloudAuthentication -Arguments @("auth", "print-access-token"))) {
    Write-Host "Google Cloud CLI login is required. Opening the browser login flow..."
    & gcloud auth login
    if ($LASTEXITCODE -ne 0) {
      throw "Google Cloud CLI login did not complete successfully."
    }
  }

  Write-Host "Checking Terraform Application Default Credentials..."
  if (-not (Test-GcloudAuthentication -Arguments @("auth", "application-default", "print-access-token"))) {
    Write-Host "Terraform credentials are missing or expired. Opening the browser login flow..."
    & gcloud auth application-default login
    if ($LASTEXITCODE -ne 0) {
      throw "Application Default Credentials login did not complete successfully."
    }
  }

  if (-not (Test-GcloudAuthentication -Arguments @("auth", "print-access-token"))) {
    throw "Google Cloud CLI credentials are still unavailable after login."
  }

  if (-not (Test-GcloudAuthentication -Arguments @("auth", "application-default", "print-access-token"))) {
    throw "Terraform Application Default Credentials are still unavailable after login."
  }
}
