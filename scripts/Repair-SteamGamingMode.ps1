[CmdletBinding()]
param(
    [string]$UserName = "SteamGaming",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour reparer SteamGaming."
    }
}

if (-not $Apply) {
    Write-Host "MODE APERCU - aucune modification ne sera effectuee." -ForegroundColor Yellow
    Write-Host "Pour appliquer : .\Repair-SteamGamingMode.ps1 -Apply"
    exit 0
}

Assert-Administrator

$projectRoot = Split-Path -Parent $PSScriptRoot
$publishedRoot = Join-Path $projectRoot "publish\win-x64"
$installRoot = Join-Path ${env:ProgramFiles} "SteamOsWin"
$publishedExe = Join-Path $publishedRoot "SteamOsWin.exe"
$installedExe = Join-Path $installRoot "SteamOsWin.exe"
$brokerSource = Join-Path $PSScriptRoot "Switch-SteamOsWinSession.ps1"
$brokerInstalled = Join-Path $installRoot "Switch-SteamOsWinSession.ps1"

if (-not (Test-Path -LiteralPath $publishedExe)) {
    throw "Publication introuvable : $publishedExe"
}
if (-not (Test-Path -LiteralPath $brokerSource)) {
    throw "Broker introuvable : $brokerSource"
}

# No SteamOsWin process should survive the reboot.  Copy the known-good build
# again, then restore standard Program Files permissions recursively so the
# normal Euxane task can execute it.
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Get-ChildItem -LiteralPath $publishedRoot -Force | Copy-Item -Destination $installRoot -Recurse -Force
Copy-Item -LiteralPath $brokerSource -Destination $brokerInstalled -Force
& icacls.exe $installRoot /reset /T /C | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Reinitialisation des droits de $installRoot echouee (code $LASTEXITCODE)."
}

$account = Get-LocalUser -Name $UserName -ErrorAction Stop
$sid = $account.SID.Value
$registryPath = "$sid\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
$userWinlogon = [Microsoft.Win32.Registry]::Users.CreateSubKey($registryPath)
if ($null -eq $userWinlogon) {
    throw "Impossible d'ouvrir le registre de $UserName."
}

$shellCommand = '"{0}" --shell --user-session' -f $installedExe
try {
    $userWinlogon.SetValue("Shell", $shellCommand, [Microsoft.Win32.RegistryValueKind]::String)
    $effectiveValue = [string]$userWinlogon.GetValue("Shell")
}
finally {
    $userWinlogon.Dispose()
}

if ($effectiveValue -ne $shellCommand) {
    throw "Le shell de $UserName n'a pas pu etre enregistre."
}

# The machine-wide shell is deliberately left untouched: Euxane must keep
# Explorer and its normal desktop.
$machineShell = [string](Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name Shell).Shell
if ($machineShell -notmatch '(?i)^explorer\.exe$') {
    throw "Securite : le shell global n'est pas Explorer ($machineShell)."
}

Start-ScheduledTask -TaskPath "\SteamOsWin\" -TaskName "NormalUserHotkey"
Start-Sleep -Seconds 2
$currentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$agent = Get-CimInstance Win32_Process -Filter "Name='SteamOsWin.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.SessionId -eq $currentSessionId -and $_.CommandLine -match '--switch-agent' } |
    Select-Object -First 1
if (-not $agent) {
    throw "L'agent Ctrl+Alt+W n'a pas demarre."
}

Write-Host "Reparation terminee." -ForegroundColor Green
Write-Host "Euxane conserve Explorer. SteamGaming utilisera SteamOS-Win a sa prochaine connexion complete."
Write-Host "Agent Ctrl+Alt+W actif (PID $($agent.ProcessId))."
