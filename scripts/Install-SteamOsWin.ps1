[CmdletBinding()]
param(
    [ValidateSet("normal", "steam")]
    [string]$Mode = "steam",
    [switch]$Apply,
    [switch]$Restore,
    [switch]$AllowMachineShell,
    [string]$PublishedPath = ""
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour installer le shell."
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath a échoué avec le code $LASTEXITCODE."
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = if ($PublishedPath) {
    (Resolve-Path -LiteralPath $PublishedPath).Path
} else {
    Join-Path $projectRoot "publish\win-x64"
}

$sourceExe = Join-Path $sourcePath "SteamOsWin.exe"
$installRoot = Join-Path ${env:ProgramFiles} "SteamOsWin"
$installedExe = Join-Path $installRoot "SteamOsWin.exe"
$dataRoot = Join-Path ${env:ProgramData} "SteamOsWin"
$backupRoot = Join-Path $dataRoot "backups"
$statePath = Join-Path $dataRoot "install-state.json"
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

if (-not $Apply) {
    Write-Host "MODE APERÇU — aucune modification ne sera effectuée." -ForegroundColor Yellow
    Write-Host "Mode d'installation : $Mode"
    Write-Host "Binaire attendu : $sourceExe"
    Write-Host "Installation : $installRoot"
    Write-Host "ATTENTION : ce script est legacy et modifie le shell global."
    Write-Host "Pour appliquer volontairement : .\Install-SteamOsWin.ps1 -Mode $Mode -AllowMachineShell -Apply"
    exit 0
}

if (-not $Restore -and -not $AllowMachineShell) {
    throw "Sécurité : ce script modifie le shell global HKLM Winlogon. Pour une seule installation Windows, utilise Install-PerUserSteamDispatcher.ps1. Pour forcer ce vieux mode global dans une installation de test, ajoute explicitement -AllowMachineShell."
}

Assert-Administrator

if ($Restore) {
    if (-not (Test-Path -LiteralPath $statePath)) {
        throw "Aucun état d'installation trouvé dans $statePath."
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $originalShell = if ([string]::IsNullOrWhiteSpace($state.OriginalShell)) { "explorer.exe" } else { $state.OriginalShell }
    Set-ItemProperty -LiteralPath $winlogonPath -Name Shell -Value $originalShell

    $modePath = Join-Path $dataRoot "mode.txt"
    if (Test-Path -LiteralPath $modePath) {
        Remove-Item -LiteralPath $modePath -Force
    }

    Write-Host "Shell Winlogon restauré : $originalShell" -ForegroundColor Green
    Write-Host "Le BCD n'a pas été modifié par ce script. La sauvegarde est conservée dans $($state.BcdBackup)"
    exit 0
}

if (-not (Test-Path -LiteralPath $sourceExe)) {
    throw "SteamOsWin.exe est introuvable : $sourceExe. Lance d'abord scripts\Publish.ps1."
}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bcdBackup = Join-Path $backupRoot "BCD-$stamp"
Invoke-Native "bcdedit.exe" @("/export", $bcdBackup)

$existingState = if (Test-Path -LiteralPath $statePath) {
    try { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $null }
} else {
    $null
}
$originalShell = if ($existingState -and -not [string]::IsNullOrWhiteSpace($existingState.OriginalShell)) {
    $existingState.OriginalShell
} else {
    (Get-ItemProperty -LiteralPath $winlogonPath -Name Shell -ErrorAction SilentlyContinue).Shell
}
if ([string]::IsNullOrWhiteSpace($originalShell) -or $originalShell -match "SteamOsWin\.exe") {
    $originalShell = "explorer.exe"
}

$state = [ordered]@{
    InstalledAt = (Get-Date).ToString("o")
    Mode = $Mode
    InstallRoot = $installRoot
    OriginalShell = $originalShell
    BcdBackup = $bcdBackup
}
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Get-ChildItem -LiteralPath $sourcePath -Force | Copy-Item -Destination $installRoot -Recurse -Force

$modePath = Join-Path $dataRoot "mode.txt"
Set-Content -LiteralPath $modePath -Value $Mode -Encoding ASCII
$shellCommand = if ($Mode -eq "steam") {
    '"{0}" --dispatcher' -f $installedExe
} else {
    "explorer.exe"
}
Set-ItemProperty -LiteralPath $winlogonPath -Name Shell -Value $shellCommand

Write-Host "SteamOsWin installé dans $installRoot" -ForegroundColor Green
Write-Host "Mode de cette installation : $Mode" -ForegroundColor Green
Write-Host "Shell Winlogon : $shellCommand" -ForegroundColor Green
Write-Host "Sauvegarde BCD : $bcdBackup" -ForegroundColor Green
Write-Host "Pour restaurer : .\Install-SteamOsWin.ps1 -Restore -Apply"
