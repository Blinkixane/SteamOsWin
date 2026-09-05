[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\ProgramData\SteamOsWin\session-switch.json"
)

$ErrorActionPreference = "Stop"
$logPath = Join-Path ${env:ProgramData} "SteamOsWin\session-switch.log"

function Write-Log {
    param([string]$Message)

    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
        Add-Content -LiteralPath $logPath -Value ("[{0}] {1}" -f (Get-Date -Format o), $Message)
    }
    catch {
        # A logging failure must never prevent session recovery.
    }
}

function Get-ConsoleSessions {
    $quser = Join-Path ${env:SystemRoot} "System32\quser.exe"
    $lines = @(& $quser 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "quser a echoue avec le code $LASTEXITCODE : $($lines -join ' ')"
    }

    $result = foreach ($rawLine in $lines | Select-Object -Skip 1) {
        $line = $rawLine.ToString().Trim().TrimStart('>')
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # SESSIONNAME is blank for a disconnected session. Backtracking makes
        # this work in both French and English Windows output.
        if ($line -match '^(?<User>\S+)\s+(?:(?<Station>\S+)\s+)?(?<Id>\d+)\s+(?<State>\S+)') {
            [pscustomobject]@{
                UserName = $Matches.User
                Station = $Matches.Station
                Id       = [int]$Matches.Id
                State    = $Matches.State
            }
        }
    }

    return @($result)
}

function Test-ActiveState {
    param([string]$State)
    return $State -match '^(?i:active|actif)$'
}

function Test-DisconnectedState {
    param([string]$State)
    return $State -match '^(?i:disc|d[eé]co)'
}

try {
    Write-Log "Broker demarre par le Planificateur."

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration introuvable : $ConfigPath"
    }

    $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $normalUser = [string]$configuration.NormalUserName
    $gamingUser = [string]$configuration.GamingUserName
    if ([string]::IsNullOrWhiteSpace($normalUser) -or [string]::IsNullOrWhiteSpace($gamingUser)) {
        throw "Configuration des comptes incomplete."
    }

    $sessions = Get-ConsoleSessions
    Write-Log ("Sessions: " + (($sessions | ForEach-Object { "$($_.UserName)/$($_.Station)/$($_.Id)/$($_.State)" }) -join '; '))

    $current = $sessions |
        Where-Object { $_.Station -ieq "console" -and (Test-ActiveState $_.State) } |
        Select-Object -First 1
    if (-not $current) {
        throw "Aucune session console active detectee."
    }

    $targetUser = if ($current.UserName -ieq $normalUser) {
        $gamingUser
    }
    elseif ($current.UserName -ieq $gamingUser) {
        $normalUser
    }
    else {
        throw "La session console active ($($current.UserName)) ne correspond pas aux comptes configures."
    }

    $target = $sessions |
        Where-Object {
            $_.UserName -ieq $targetUser -and
            $_.Id -ne $current.Id
        } |
        Select-Object -First 1
    if (-not $target) {
        throw "La session de '$targetUser' n'existe pas. Connecte ce compte une fois avant d'utiliser le raccourci."
    }

    Write-Log "Transfert: $($current.UserName) session $($current.Id) -> $targetUser session $($target.Id)."
    $tscon = Join-Path ${env:SystemRoot} "System32\tscon.exe"
    $transfer = Start-Process -FilePath $tscon -ArgumentList @([string]$target.Id, "/dest:console") -Wait -PassThru -WindowStyle Hidden
    if ($transfer.ExitCode -ne 0) {
        throw "tscon a echoue avec le code $($transfer.ExitCode)."
    }

    Write-Log "Transfert demande avec succes vers la session $($target.Id)."
    exit 0
}
catch {
    Write-Log "ECHEC: $($_.Exception.Message)"
    exit 2
}
