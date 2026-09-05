[CmdletBinding()]
param(
    [string]$PublishedPath = "",
    [switch]$RequireGameDrives,
    [switch]$Apply,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"

function Resolve-PublishedPath {
    param([string]$RequestedPath)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates += $RequestedPath
    }
    $candidates += @(
        (Join-Path $PSScriptRoot "..\publish\win-x64"),
        "D:\SteamOsWin\payload\publish\win-x64",
        "E:\SteamOsWin\payload\publish\win-x64"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "SteamOsWin.exe")) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-GameDriveReport {
    $report = @()
    foreach ($letter in @("D", "E")) {
        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        $root = "{0}:\" -f $letter
        $libraries = @()

        if ($volume) {
            foreach ($name in @("SteamLibrary", "Games", "Steam", "Vortex Mods")) {
                $candidate = Join-Path $root $name
                if (Test-Path -LiteralPath $candidate) {
                    $libraries += $candidate
                }
            }
        }

        $report += [ordered]@{
            DriveLetter = $letter
            Accessible = [bool]$volume
            FileSystem = if ($volume) { $volume.FileSystem } else { $null }
            Label = if ($volume) { $volume.FileSystemLabel } else { $null }
            SizeGB = if ($volume) { [math]::Round($volume.Size / 1GB, 1) } else { $null }
            FreeGB = if ($volume) { [math]::Round($volume.SizeRemaining / 1GB, 1) } else { $null }
            SteamRoots = @($libraries | Select-Object -Unique)
        }
    }
    return $report
}

$installRoot = Join-Path $env:LOCALAPPDATA "SteamOsWin"
$installedExe = Join-Path $installRoot "SteamOsWin.exe"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runName = "SteamOsWinGaming"
$statePath = Join-Path $installRoot "user-session-state.json"
$storagePath = Join-Path $installRoot "game-drive-report.json"
$storageReport = Get-GameDriveReport

if (-not $Apply -and -not $Restore) {
    $published = Resolve-PublishedPath $PublishedPath
    Write-Host "MODE APERCU - aucune modification ne sera effectuee." -ForegroundColor Yellow
    Write-Host "Compte courant : $env:USERNAME"
    Write-Host "Installation par utilisateur : $installRoot"
    Write-Host "Payload detecte : $published"
    $storageReport | Format-Table -AutoSize
    Write-Host "Le mode Steam sera lance avec --shell --user-session."
    Write-Host "Pour appliquer : .\Install-UserSteamSession.ps1 -Apply -RequireGameDrives"
    exit 0
}

if ($Restore) {
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    Write-Host "Lancement automatique SteamOsWin retire pour $env:USERNAME." -ForegroundColor Green
    exit 0
}

$published = Resolve-PublishedPath $PublishedPath
if (-not $published) {
    throw "SteamOsWin.exe est introuvable. Passe -PublishedPath vers publish\win-x64."
}

if ($RequireGameDrives) {
    $missing = @($storageReport | Where-Object { -not $_.Accessible })
    if ($missing.Count -gt 0) {
        $names = $missing | ForEach-Object { "$($_.DriveLetter):" }
        throw "Volumes de jeux introuvables : $($names -join ', '). Aucun changement applique."
    }
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Get-ChildItem -LiteralPath $published -Force | Copy-Item -Destination $installRoot -Recurse -Force

$command = '"{0}" --shell --user-session' -f $installedExe
New-Item -Path $runKey -Force | Out-Null
New-ItemProperty -Path $runKey -Name $runName -PropertyType String -Value $command -Force | Out-Null

$storageReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $storagePath -Encoding UTF8
[ordered]@{
    InstalledAt = (Get-Date).ToString("o")
    UserName = $env:USERNAME
    InstallRoot = $installRoot
    RunCommand = $command
    GameDriveReport = $storagePath
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-Host "Session SteamGaming configuree pour $env:USERNAME." -ForegroundColor Green
Write-Host "Lancement : $command"
Write-Host "Rapport D/E : $storagePath"
Write-Host "Deconnecte-toi puis reconnecte-toi pour tester la session."
