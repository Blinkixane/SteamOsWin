[CmdletBinding()]
param(
    [ValidateSet("fast", "logoff")]
    [string]$Mode = "logoff",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour changer le mode de session."
    }
}

if (-not $Apply) {
    Write-Host "MODE APERCU - le mode cible serait : $Mode" -ForegroundColor Yellow
    exit 0
}

Assert-Administrator
$configPath = Join-Path ${env:ProgramData} "SteamOsWin\session-switch.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Configuration introuvable : $configPath"
}

$configuration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$configuration | Add-Member -NotePropertyName SwitchMode -NotePropertyValue $Mode -Force
$configuration | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding ASCII

Write-Host "Mode applique : $Mode" -ForegroundColor Green
if ($Mode -eq "logoff") {
    Write-Host "Ctrl+Alt+W fermera la session courante. La session suivante demandera son mot de passe et aucune RAM ne sera conservee." 
}
