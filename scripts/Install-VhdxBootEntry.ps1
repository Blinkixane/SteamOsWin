[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VhdxPath,
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
        throw (($output -join [Environment]::NewLine) + "`n$FilePath a echoue avec le code $LASTEXITCODE.")
    }
    return $output
}

$vhdx = Get-Item -LiteralPath $VhdxPath -ErrorAction Stop
if ($vhdx.Extension -notin @(".vhd", ".vhdx")) {
    throw "Le fichier doit etre un disque virtuel .vhd ou .vhdx."
}

$fullPath = $vhdx.FullName
if ($fullPath -notmatch "^[A-Za-z]:\\") {
    throw "Le VHDX doit etre stocke sur un volume local avec une lettre de lecteur."
}

$hostDrive = $fullPath.Substring(0, 2)
$vhdRelativePath = $fullPath.Substring(2)
$bcdVhdPath = "vhd=[$hostDrive]$vhdRelativePath"

if (-not $Apply) {
    Write-Host "MODE APERCU - aucune modification du BCD ne sera effectuee." -ForegroundColor Yellow
    Write-Host "VHDX : $fullPath"
    Write-Host "Parametre BCD : $bcdVhdPath"
    Write-Host "Description : $Description"
    Write-Host "Le VHDX doit deja contenir une installation Windows amorcable."
    Write-Host "Pour appliquer : .\Install-VhdxBootEntry.ps1 -VhdxPath `"$fullPath`" -Description `"$Description`" -Apply"
    exit 0
}

Assert-Administrator

$dataRoot = Join-Path ${env:ProgramData} "SteamOsWin"
$backupRoot = Join-Path $dataRoot "backups"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bcdBackup = Join-Path $backupRoot "BCD-$stamp"
Invoke-Native "bcdedit.exe" @("/export", $bcdBackup) | Out-Null

$copyOutput = Invoke-Native "bcdedit.exe" @("/copy", "{current}", "/d", $Description)
$guidPattern = [regex]::Escape("{") + "[0-9a-f-]{36}" + [regex]::Escape("}")
$entryMatch = [regex]::Match(($copyOutput -join [Environment]::NewLine), $guidPattern)
if (-not $entryMatch.Success) {
    throw "La copie BCD n'a pas pu etre identifiee automatiquement. Le BCD a ete sauvegarde dans $bcdBackup."
}

$entryGuid = $entryMatch.Value
Invoke-Native "bcdedit.exe" @("/set", $entryGuid, "device", $bcdVhdPath) | Out-Null
Invoke-Native "bcdedit.exe" @("/set", $entryGuid, "osdevice", $bcdVhdPath) | Out-Null
Invoke-Native "bcdedit.exe" @("/set", $entryGuid, "systemroot", "\Windows") | Out-Null
Invoke-Native "bcdedit.exe" @("/set", $entryGuid, "detecthal", "yes") | Out-Null
Invoke-Native "bcdedit.exe" @("/displayorder", $entryGuid, "/addlast") | Out-Null
Invoke-Native "bcdedit.exe" @("/timeout", "5") | Out-Null

New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
[ordered]@{
    InstalledAt = (Get-Date).ToString("o")
    EntryGuid = $entryGuid
    Description = $Description
    VhdxPath = $fullPath
    BcdVhdPath = $bcdVhdPath
    BcdBackup = $bcdBackup
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataRoot "vhdx-entry.json") -Encoding UTF8

Write-Host "Entree VHDX ajoutee : $Description ($entryGuid)" -ForegroundColor Green
Write-Host "Sauvegarde BCD : $bcdBackup" -ForegroundColor Green
Write-Host "Le menu Windows Boot Manager attendra 5 secondes."
