[CmdletBinding()]
param(
    [string]$UserName = "SteamGaming",
    [ValidateSet("normal", "steam")]
    [string]$Mode = "steam"
)

$ErrorActionPreference = "Stop"

$targetUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if (-not $targetUser) {
    throw "Le compte local '$UserName' n'existe pas."
}

$shellValue = if ($Mode -eq "steam") {
    $shellExe = Join-Path ${env:ProgramFiles} "SteamOsWin\SteamOsWin.exe"
    if (-not (Test-Path -LiteralPath $shellExe)) {
        throw "SteamOsWin.exe est introuvable : $shellExe"
    }
    '"{0}" --shell --user-session' -f $shellExe
} else {
    "explorer.exe"
}

# This code runs in SteamGaming's own interactive profile. It deliberately
# modifies only that account's Winlogon\Shell value, never HKLM.
$innerScript = @"
`$ErrorActionPreference = 'Stop'
`$key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
New-Item -Path `$key -Force | Out-Null
Set-ItemProperty -LiteralPath `$key -Name 'Shell' -Value '$shellValue' -Force
"@

$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($innerScript))
$argument = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"

Write-Host "Saisis le mot de passe de '$UserName' dans la fenetre d'identification Windows." -ForegroundColor Yellow
$credential = Get-Credential -UserName "$env:COMPUTERNAME\$UserName" -Message "Mot de passe du compte SteamGaming"
if ($null -eq $credential) {
    throw "Identification annulee."
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = "powershell.exe"
$startInfo.Arguments = $argument
$startInfo.UserName = $UserName
$startInfo.Domain = $env:COMPUTERNAME
$startInfo.Password = $credential.Password
$startInfo.LoadUserProfile = $true
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true

try {
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "La commande executee sous '$UserName' a echoue avec le code $($process.ExitCode)."
    }
}
catch {
    throw "Impossible d'executer la configuration sous '$UserName'. Verifie le mot de passe. $($_.Exception.Message)"
}

Write-Host "La valeur Shell a ete demandee pour '$UserName' : $shellValue" -ForegroundColor Green
Write-Host "Deconnecte-toi puis reconnecte-toi a '$UserName' pour appliquer le mode $Mode."
