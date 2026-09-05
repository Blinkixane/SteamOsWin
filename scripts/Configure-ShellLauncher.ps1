[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UserName,
    [string]$ShellPath = "",
    [switch]$Apply,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour configurer Shell Launcher."
    }
}

function Get-UserSid([string]$AccountName) {
    $account = [System.Security.Principal.NTAccount]::new($AccountName)
    return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Invoke-ShellLauncherMethod {
    param([object]$Result, [string]$MethodName)
    $returnValue = if ($Result.PSObject.Properties.Name -contains "ReturnValue") {
        [int]$Result.ReturnValue
    } else {
        [int]$Result
    }

    if ($returnValue -ne 0) {
        throw "$MethodName a renvoyé le code WMI $returnValue."
    }
}

$namespace = "root\standardcimv2\embedded"
$dataRoot = Join-Path ${env:ProgramData} "SteamOsWin"
$statePath = Join-Path $dataRoot "shell-launcher.json"
$installPath = Join-Path ${env:ProgramFiles} "SteamOsWin\SteamOsWin.exe"
$shell = if ($ShellPath) { (Resolve-Path -LiteralPath $ShellPath).Path } else { $installPath }

if (-not $Apply) {
    $previewSid = try { Get-UserSid $UserName } catch { "non résolu en aperçu" }
    Write-Host "MODE APERÇU — aucune modification Shell Launcher ne sera effectuée." -ForegroundColor Yellow
    Write-Host "Compte : $UserName"
    Write-Host "SID : $previewSid"
    Write-Host "Shell : `"$shell`" --shell"
    Write-Host "Pour appliquer : .\Configure-ShellLauncher.ps1 -UserName `"$UserName`" -Apply"
    exit 0
}

Assert-Administrator

$productName = (Get-ComputerInfo -Property WindowsProductName).WindowsProductName
if ($productName -notmatch "Enterprise|Education|IoT") {
    throw "Cette édition ($productName) ne fait pas partie des éditions supportées par Shell Launcher. Utilise Install-SteamOsWin.ps1 pour le shell Winlogon réversible."
}

$sid = Get-UserSid $UserName

try {
    $shellLauncherClass = [wmiclass]"\\localhost\$namespace`:WESL_UserSetting"
}
catch {
    throw "Le fournisseur WMI Shell Launcher est indisponible. Vérifie les fonctionnalités Windows et exécute ce script avec Windows PowerShell 5.1. $($_.Exception.Message)"
}

if ($Restore) {
    Invoke-ShellLauncherMethod ($shellLauncherClass.RemoveCustomShell($sid)) "RemoveCustomShell"
    Write-Host "Configuration Shell Launcher retirée pour $UserName ($sid). Redémarre Windows pour appliquer." -ForegroundColor Green
    exit 0
}

$featureNames = @("Client-DeviceLockdown", "Client-EmbeddedShellLauncher")
Enable-WindowsOptionalFeature -Online -FeatureName $featureNames -All -NoRestart | Out-Null

if (-not (Test-Path -LiteralPath $shell)) {
    throw "Shell introuvable : $shell"
}

New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
[ordered]@{
    ConfiguredAt = (Get-Date).ToString("o")
    UserName = $UserName
    Sid = $sid
    Shell = $shell
    FeatureNames = $featureNames
} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

# Exit code 1 means “do nothing” for Shell Launcher. The shell uses it after
# starting Explorer when the user requests a return to the normal desktop.
$returnCodes = [int[]](1)
$returnActions = [int[]](3)
$result = $shellLauncherClass.SetCustomShell(
    $sid,
    ('"{0}" --shell' -f $shell),
    $returnCodes,
    $returnActions,
    0)
Invoke-ShellLauncherMethod $result "SetCustomShell"
Invoke-ShellLauncherMethod ($shellLauncherClass.SetEnabled($true)) "SetEnabled"

Write-Host "Shell Launcher configuré pour $UserName ($sid)" -ForegroundColor Green
Write-Host "Shell : `"$shell`" --shell"
Write-Host "Retour bureau : Ctrl + Alt + Shift + W"
Write-Host "Redémarre Windows pour appliquer. Restauration : .\Configure-ShellLauncher.ps1 -UserName `"$UserName`" -Restore -Apply"
