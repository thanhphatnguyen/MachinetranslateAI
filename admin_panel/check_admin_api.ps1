$ErrorActionPreference = "Continue"

$Port = if ($env:ADMIN_PORT) { [int]$env:ADMIN_PORT } else { 8080 }
$LocalUrl = "http://127.0.0.1:$Port/api/health"

Write-Host "== Machine Translate Admin API check =="
Write-Host "Directory: $PSScriptRoot"
Write-Host "Port: $Port"
Write-Host ""

Write-Host "== Python packages =="
python -c "import fastapi, uvicorn; print('fastapi/uvicorn OK')"
if ($LASTEXITCODE -ne 0) {
  Write-Host "Missing FastAPI/Uvicorn. Run: pip install -r requirements.txt" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "== Local listener =="
$listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listeners) {
  $listeners | Format-Table -AutoSize LocalAddress,LocalPort,OwningProcess
  foreach ($listener in $listeners) {
    Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue |
      Format-Table -AutoSize Id,ProcessName,Path
  }
} else {
  Write-Host "No process is listening on port $Port." -ForegroundColor Yellow
  Write-Host "Start it with: .\run_admin.ps1"
}
Write-Host ""

Write-Host "== Local health check =="
try {
  Invoke-RestMethod -Uri $LocalUrl -TimeoutSec 5 | ConvertTo-Json -Compress
} catch {
  Write-Host "Local health check failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "== Firewall rules containing $Port or Machine Translate =="
Get-NetFirewallRule -Enabled True -Direction Inbound -ErrorAction SilentlyContinue |
  Where-Object {
    $_.DisplayName -match "Machine Translate|Admin|8080" -or
    (Get-NetFirewallPortFilter -AssociatedNetFirewallRule $_ -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalPort -eq "$Port" })
  } |
  Format-Table -AutoSize DisplayName,Enabled,Direction,Action,Profile

Write-Host ""
Write-Host "If local health works but phone/browser times out, open Windows Firewall and VPS provider firewall for TCP port $Port."
