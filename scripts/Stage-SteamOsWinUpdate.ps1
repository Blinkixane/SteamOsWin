[CmdletBinding()]
param(
    [string]$PublishedPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "publish\win-x64"),
    [string]$InstallPath = (Join-Path ${env:ProgramFiles} "SteamOsWin"),
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour preparer la mise a jour."
    }
}

if (-not $Apply) {
    Write-Host "MODE APERCU - aucune modification ne sera effectuee." -ForegroundColor Yellow
    Write-Host "Les fichiers seront remplaces proprement au prochain redemarrage."
    exit 0
}

Assert-Administrator
if (-not (Test-Path -LiteralPath (Join-Path $PublishedPath "SteamOsWin.exe"))) {
    throw "Publication introuvable : $PublishedPath"
}

$stageRoot = Join-Path ${env:ProgramData} ("SteamOsWin\pending-update-" + (Get-Date -Format "yyyyMMddHHmmss"))
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
# Files moved into Program Files at reboot keep this ACL.  Users therefore
# need read/execute access or the normal-session hotkey task will be denied.
& icacls.exe $stageRoot /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" "*S-1-5-32-545:(OI)(CI)(RX)" /C | Out-Null

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class SteamOsWinPendingMove
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
}
"@

$moveFlags = 0x1 -bor 0x4 # replace existing + delay until reboot
$files = Get-ChildItem -LiteralPath $PublishedPath -Recurse -File
foreach ($file in $files) {
    $relative = $file.FullName.Substring($PublishedPath.TrimEnd('\\').Length).TrimStart('\\')
    $staged = Join-Path $stageRoot $relative
    $target = Join-Path $InstallPath $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $staged),(Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $staged -Force
    if (-not [SteamOsWinPendingMove]::MoveFileEx($staged, $target, $moveFlags)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Le remplacement differe a echoue pour $relative (code Windows $errorCode)."
    }
}

Write-Host "Mise a jour preparee : $($files.Count) fichiers seront appliques au prochain redemarrage." -ForegroundColor Green
