[CmdletBinding()]
param(
    [string]$UserName = "SteamGaming",
    [string]$SourceUserName = "Euxane",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour installer l'acces partage."
    }
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath a echoue avec le code $LASTEXITCODE."
    }
}

$target = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if (-not $target) {
    throw "Le compte local '$UserName' n'existe pas."
}

$sourceProfile = Join-Path ${env:SystemDrive} "Users\$SourceUserName"
$codexRoot = Join-Path $sourceProfile "AppData\Local\OpenAI\Codex"
$codexExe = Get-ChildItem -LiteralPath (Join-Path $codexRoot "bin") -Filter "codex.exe" -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $codexExe) {
    throw "Codex.exe introuvable sous $codexRoot."
}

$commonPrograms = Join-Path ${env:ProgramData} "Microsoft\Windows\Start Menu\Programs"
$shortcutPath = Join-Path $commonPrograms "OpenAI Codex.lnk"

if (-not $Apply) {
    Write-Host "MODE APERCU - aucune modification ne sera effectuee." -ForegroundColor Yellow
    Write-Host "Utilisateur cible : $UserName"
    Write-Host "Installation Codex : $($codexExe.FullName)"
    Write-Host "Raccourci commun : $shortcutPath"
    Write-Host "L'acces sera limite a la lecture/execution de l'installation Codex."
    Write-Host "Pour appliquer : .\Install-SteamGamingAppAccess.ps1 -Apply"
    exit 0
}

Assert-Administrator

$targetSid = $target.SID.Value
# Use the SID so this works independently of the Windows display language.
$grant = "*${targetSid}:(OI)(CI)(RX)"
Invoke-Native "icacls.exe" @($codexRoot, "/grant", $grant, "/T", "/C")

New-Item -ItemType Directory -Path $commonPrograms -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $codexExe.FullName
$shortcut.WorkingDirectory = $codexExe.DirectoryName
$shortcut.Description = "OpenAI Codex - raccourci partage pour les comptes Windows"
$shortcut.IconLocation = "$($codexExe.FullName),0"
$shortcut.Save()

Write-Host "Acces Codex installe pour '$UserName'." -ForegroundColor Green
Write-Host "Raccourci cree : $shortcutPath"
Write-Host "Le compte reste standard; les autres applications par utilisateur devront etre installees ou partagees separement."
