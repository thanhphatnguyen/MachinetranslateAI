$ErrorActionPreference = "Stop"

$Port = if ($env:ADMIN_PORT) { [int]$env:ADMIN_PORT } else { 8080 }
$RuleName = "Machine Translate Admin API $Port"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Run this script from an elevated PowerShell window: Run as Administrator."
}

$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if (-not $existing) {
  New-NetFirewallRule `
    -DisplayName $RuleName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $Port `
    -Profile Any | Out-Null
  Write-Host "Created inbound firewall rule for TCP port $Port."
} else {
  Set-NetFirewallRule -DisplayName $RuleName -Enabled True -Action Allow -Profile Any
  Write-Host "Updated existing inbound firewall rule for TCP port $Port."
}

Get-NetFirewallRule -DisplayName $RuleName |
  Format-Table -AutoSize DisplayName,Enabled,Direction,Action,Profile
