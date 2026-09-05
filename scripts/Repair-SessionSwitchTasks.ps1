[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour reparer les taches de changement de session."
    }
}

if (-not $Apply) {
    Write-Host "MODE APERCU - aucune modification ne sera effectuee." -ForegroundColor Yellow
    Write-Host "Pour appliquer : .\Repair-SessionSwitchTasks.ps1 -Apply"
    exit 0
}

Assert-Administrator

$agent = Get-ScheduledTask -TaskPath "\SteamOsWin\" -TaskName "NormalUserHotkey" -ErrorAction Stop
$agent.Settings.ExecutionTimeLimit = "PT0S"
$agent.Settings.MultipleInstances = 2
Set-ScheduledTask -InputObject $agent | Out-Null

$broker = Get-ScheduledTask -TaskPath "\SteamOsWin\" -TaskName "SessionSwitch" -ErrorAction Stop
$broker.Settings.ExecutionTimeLimit = "PT2M"
$broker.Settings.MultipleInstances = 2
Set-ScheduledTask -InputObject $broker | Out-Null

$agentInfo = Get-ScheduledTask -TaskPath "\SteamOsWin\" -TaskName "NormalUserHotkey"
if ($agentInfo.Settings.ExecutionTimeLimit -ne "PT0S") {
    throw "La limite de temps de l'agent n'a pas pu etre retiree."
}

Write-Host "Reparation terminee : l'agent Ctrl+Alt+W reste actif jusqu'a la deconnexion." -ForegroundColor Green
