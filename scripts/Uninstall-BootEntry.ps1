[CmdletBinding()]
param(
    [string]$EntryGuid = "",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu administrateur pour modifier le BCD."
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath a echoue avec le code $LASTEXITCODE."
    }
}

$statePaths = @(
    (Join-Path ${env:ProgramData} "SteamOsWin\boot-entry.json"),
    (Join-Path ${env:ProgramData} "SteamOsWin\vhdx-entry.json")
)
if ([string]::IsNullOrWhiteSpace($EntryGuid)) {
    $statePath = $statePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $statePath) {
        throw "Aucune entree SteamOS-Win enregistree. Passe -EntryGuid avec l identifiant affiche par bcdedit."
    }
    $EntryGuid = (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).EntryGuid
}

if ($EntryGuid -notmatch "^\{[0-9a-f-]{36}\}$") {
    throw "EntryGuid invalide : $EntryGuid"
}

if (-not $Apply) {
    Write-Host "MODE APERCU - l entree $EntryGuid serait retiree du menu et du BCD." -ForegroundColor Yellow
    Write-Host "Pour appliquer : .\Uninstall-BootEntry.ps1 -EntryGuid $EntryGuid -Apply"
    exit 0
}

Assert-Administrator
$backupRoot = Join-Path ${env:ProgramData} "SteamOsWin\backups"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bcdBackup = Join-Path $backupRoot "BCD-before-delete-$stamp"
Invoke-Native "bcdedit.exe" @("/export", $bcdBackup)
Invoke-Native "bcdedit.exe" @("/displayorder", $EntryGuid, "/remove")
Invoke-Native "bcdedit.exe" @("/delete", $EntryGuid)
Write-Host "Entree BCD supprimee : $EntryGuid" -ForegroundColor Green
Write-Host "Sauvegarde BCD : $bcdBackup" -ForegroundColor Green
