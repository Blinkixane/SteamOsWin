[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WindowsRoot,
    [string]$Description = "SteamOS-Win",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour modifier le BCD."
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output -join [Environment]::NewLine) + "`n$FilePath a échoué avec le code $LASTEXITCODE.")
    }
    return $output
}

$windowsRootPath = (Resolve-Path -LiteralPath $WindowsRoot).Path
$windowsRootPath = $windowsRootPath.TrimEnd('\') + '\'
$windowsDirectory = Join-Path $windowsRootPath "Windows"
$winload = Join-Path $windowsDirectory "System32\winload.efi"
if (-not (Test-Path -LiteralPath $winload)) {
    throw "Installation Windows non trouvée dans $windowsRootPath : $winload"
}

if (-not $Apply) {
    Write-Host "MODE APERÇU — aucune modification du BCD ne sera effectuée." -ForegroundColor Yellow
    Write-Host "Installation ciblée : $windowsRootPath"
    Write-Host "Description : $Description"
    Write-Host "Pour appliquer : .\Install-BootEntry.ps1 -WindowsRoot $windowsRootPath -Description `"$Description`" -Apply"
    exit 0
}

Assert-Administrator

$targetDrive = $windowsRootPath.Substring(0, 2)
if ($targetDrive -ieq $env:SystemDrive) {
    throw "La cible doit être une autre installation Windows, sur un autre volume que $env:SystemDrive."
}

$dataRoot = Join-Path ${env:ProgramData} "SteamOsWin"
$backupRoot = Join-Path $dataRoot "backups"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bcdBackup = Join-Path $backupRoot "BCD-$stamp"
Invoke-Native "bcdedit.exe" @("/export", $bcdBackup) | Out-Null

$copyOutput = Invoke-Native "bcdedit.exe" @("/copy", "{current}", "/d", $Description)
$entryMatch = [regex]::Match(($copyOutput -join [Environment]::NewLine), "(?i)\{[0-9a-f-]{36}\}")
if (-not $entryMatch.Success) {
    throw "La copie BCD n'a pas pu être identifiée automatiquement. Le BCD a été sauvegardé dans $bcdBackup."
}

$entryGuid = $entryMatch.Value
Invoke-Native "bcdedit.exe" @("/set", $entryGuid, "device", "partition=$targetDrive") | Out-Null
Invoke-Native "bcdedit.exe" @("/set", $entryGuid, "osdevice", "partition=$targetDrive") | Out-Null
Invoke-Native "bcdedit.exe" @("/set", $entryGuid, "systemroot", "\Windows") | Out-Null
Invoke-Native "bcdedit.exe" @("/displayorder", $entryGuid, "/addlast") | Out-Null
Invoke-Native "bcdedit.exe" @("/timeout", "5") | Out-Null

New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
[ordered]@{
    InstalledAt = (Get-Date).ToString("o")
    EntryGuid = $entryGuid
    Description = $Description
    WindowsRoot = $windowsRootPath
    BcdBackup = $bcdBackup
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataRoot "boot-entry.json") -Encoding UTF8

Write-Host "Entrée de démarrage ajoutée : $Description ($entryGuid)" -ForegroundColor Green
Write-Host "Sauvegarde BCD : $bcdBackup" -ForegroundColor Green
Write-Host "Le menu Windows Boot Manager attendra 5 secondes."
