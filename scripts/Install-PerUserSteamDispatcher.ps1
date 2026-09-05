[CmdletBinding()]
param(
    [string]$UserName = "SteamGaming",
    [string]$PublishedPath = "",
    [ValidateSet("normal", "steam")]
    [string]$Mode = "steam",
    [switch]$CleanUserStartup,
    [switch]$Apply,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour configurer le shell de l'utilisateur."
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    & $FilePath @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath a échoué avec le code $LASTEXITCODE."
    }
}

function Resolve-PublishedRoot {
    param([string]$RequestedPath)

    $projectRoot = Split-Path -Parent $PSScriptRoot
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates += $RequestedPath
    }
    $candidates += (Join-Path $projectRoot "publish\win-x64")

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "SteamOsWin.exe")) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-UserProfilePath {
    param([string]$Sid)

    $profile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue
    if (-not $profile -or [string]::IsNullOrWhiteSpace($profile.LocalPath)) {
        throw "Profil Windows introuvable pour le SID $Sid. Connecte-toi une fois avec le compte cible."
    }

    return $profile.LocalPath
}

function Use-UserHive {
    param(
        [string]$Sid,
        [scriptblock]$Action
    )

    # Use a private temporary hive name. Windows can leave HKU\<SID> mounted
    # briefly after logoff even when Win32_UserProfile.Loaded is already false.
    # Reusing that SID can make reg.exe load fail with ERROR_ACCESS_DENIED.
    $hiveName = "SteamOsWin-" + ($Sid -replace "[^A-Za-z0-9_]", "_")
    $hiveRoot = "Registry::HKEY_USERS\$hiveName"
    $mountedByScript = $false

    $profile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue
    $profileIsLoaded = $profile -and $profile.Loaded

    if (-not (Test-Path -LiteralPath $hiveRoot)) {
        if (-not $profileIsLoaded) {
            $profilePath = Get-UserProfilePath $Sid
            $ntUserPath = Join-Path $profilePath "NTUSER.DAT"
            if (-not (Test-Path -LiteralPath $ntUserPath)) {
                throw "NTUSER.DAT introuvable pour le compte cible : $ntUserPath"
            }

            Invoke-Native "reg.exe" @("load", "HKU\$hiveName", $ntUserPath)
            $mountedByScript = $true
        }
    }

    try {
        & $Action $hiveRoot
    }
    finally {
        if ($mountedByScript) {
            Invoke-Native "reg.exe" @("unload", "HKU\$hiveName")
        }
    }
}

function Set-UserShell {
    param(
        [string]$Sid,
        [AllowNull()][string]$Command
    )

    Use-UserHive $Sid {
        param($hiveRoot)
        $keyPath = Join-Path $hiveRoot "Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
        New-Item -ItemType Directory -Path $keyPath -Force | Out-Null
        $key = Get-Item -LiteralPath $keyPath
        $oldValue = $null
        if ($key.GetValueNames() -contains "Shell") {
            $oldValue = [string]$key.GetValue("Shell")
        }

        if ([string]::IsNullOrWhiteSpace($Command)) {
            $key.DeleteValue("Shell", $false)
        } else {
            New-ItemProperty -LiteralPath $keyPath -Name "Shell" -PropertyType String -Value $Command -Force | Out-Null
        }

        $key.Close()
        $oldValue
    }
}

function Get-UserShell {
    param([string]$Sid)

    Use-UserHive $Sid {
        param($hiveRoot)
        $keyPath = Join-Path $hiveRoot "Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $key = Get-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue
        $value = $null
        if ($key -and $key.GetValueNames() -contains "Shell") {
            $value = [string]$key.GetValue("Shell")
        }
        if ($key) {
            $key.Close()
        }
        $value
    }
}

function Backup-AndCleanUserStartup {
    param(
        [string]$Sid,
        [string]$BackupPath
    )

    Use-UserHive $Sid {
        param($hiveRoot)
        $runPath = Join-Path $hiveRoot "Software\Microsoft\Windows\CurrentVersion\Run"
        $key = Get-Item -LiteralPath $runPath -ErrorAction SilentlyContinue
        $values = @()
        if ($key) {
            foreach ($name in $key.GetValueNames()) {
                $values += [ordered]@{
                    Name = $name
                    Value = [string]$key.GetValue($name)
                    Kind = $key.GetValueKind($name).ToString()
                }
            }
        }

        $values | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackupPath -Encoding UTF8

        $keepPattern = '(?i)iCUE|SignalRGB|Steam|SteamSync|Apollo|DayNight|Bitdefender|NVIDIA'
        if ($key) {
            foreach ($value in $values) {
                if ($value.Name -notmatch $keepPattern -and $value.Value -notmatch $keepPattern) {
                    $key.DeleteValue($value.Name, $false)
                }
            }
            $key.Close()
        }
    }
}

function Restore-UserStartup {
    param(
        [string]$Sid,
        [string]$BackupPath
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        return
    }

    $values = @(Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json)
    Use-UserHive $Sid {
        param($hiveRoot)
        $runPath = Join-Path $hiveRoot "Software\Microsoft\Windows\CurrentVersion\Run"
        New-Item -ItemType Directory -Path $runPath -Force | Out-Null
        foreach ($value in $values) {
            New-ItemProperty -LiteralPath $runPath -Name $value.Name -PropertyType String -Value $value.Value -Force | Out-Null
        }
    }
}

$dataRoot = Join-Path ${env:ProgramData} "SteamOsWin"
$backupRoot = Join-Path $dataRoot "backups"
$statePath = Join-Path $dataRoot "per-user-shell-state.json"
$legacyStatePath = Join-Path $dataRoot "per-user-dispatcher-state.json"
$installRoot = Join-Path ${env:ProgramFiles} "SteamOsWin"
$installedExe = Join-Path $installRoot "SteamOsWin.exe"
$machineWinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

if (-not $Apply -and -not $Restore) {
    $published = Resolve-PublishedRoot $PublishedPath
    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    $machineShell = (Get-ItemProperty -LiteralPath $machineWinlogonPath -Name Shell -ErrorAction SilentlyContinue).Shell
    Write-Host "MODE APERCU - aucune modification ne sera effectuee." -ForegroundColor Yellow
    Write-Host "Utilisateur cible : $UserName (trouve : $([bool]$user))"
    Write-Host "Mode cible : $Mode"
    Write-Host "Payload detecte : $published"
    Write-Host "Shell machine actuel : $machineShell"
    Write-Host "Le compte normal restera sur Explorer."
    Write-Host "Le shell Steam sera écrit uniquement dans la ruche de $UserName."
    Write-Host "Pour appliquer : .\Install-PerUserSteamDispatcher.ps1 -UserName `"$UserName`" -Mode $Mode -Apply"
    exit 0
}

Assert-Administrator

if ($Restore) {
    $stateFile = if (Test-Path -LiteralPath $statePath) { $statePath } elseif (Test-Path -LiteralPath $legacyStatePath) { $legacyStatePath } else { $null }
    if ($stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($state.UserSid) {
            $originalUserShell = if ($state.PSObject.Properties.Name -contains "OriginalUserShell") {
                $state.OriginalUserShell
            } else {
                "explorer.exe"
            }
            Set-UserShell -Sid $state.UserSid -Command $originalUserShell | Out-Null
            if ($state.UserStartupBackup -and $state.UserSid) {
                Restore-UserStartup -Sid $state.UserSid -BackupPath $state.UserStartupBackup
            }
        }
    }

    $currentMachineShell = (Get-ItemProperty -LiteralPath $machineWinlogonPath -Name Shell -ErrorAction SilentlyContinue).Shell
    Write-Host "Shell utilisateur SteamOS-Win retiré. Le shell machine n'a pas été modifié." -ForegroundColor Green
    exit 0
}

$user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if (-not $user) {
    throw "Le compte local '$UserName' n'existe pas."
}

$machineShell = (Get-ItemProperty -LiteralPath $machineWinlogonPath -Name Shell -ErrorAction SilentlyContinue).Shell
Write-Host "Shell machine conservé : $machineShell"
if ($machineShell -and $machineShell -notmatch "(?i)^explorer\.exe$") {
    throw "Sécurité : le shell machine n'est pas explorer.exe ('$machineShell'). Répare d'abord le shell global en mode sans échec ; ce script ne le modifiera jamais."
}

$published = Resolve-PublishedRoot $PublishedPath
if (-not $published) {
    throw "SteamOsWin.exe est introuvable. Passe -PublishedPath vers publish\win-x64 ou lance scripts\Publish.ps1."
}

$sid = $user.SID.Value
$profile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
if ($profile -and $profile.Loaded) {
    throw "Le profil de '$UserName' est encore charge. Deconnecte completement cette session (Gestionnaire des taches > Utilisateurs > '$UserName' > Se deconnecter), puis relance le script."
}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stateBackup = Join-Path $backupRoot "per-user-shell-state-before-$stamp.json"
$hadStateBefore = Test-Path -LiteralPath $statePath
if ($hadStateBefore) {
    Copy-Item -LiteralPath $statePath -Destination $stateBackup -Force
}

$oldUserShell = Get-UserShell -Sid $sid
try {
    # Explorer mode only changes the target user's shell. Skipping the copy in
    # that mode avoids locking conflicts with a SteamOS-Win process still open
    # in another user session.
    if ($Mode -eq "steam" -or -not (Test-Path -LiteralPath $installedExe)) {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
        Get-ChildItem -LiteralPath $published -Force | Copy-Item -Destination $installRoot -Recurse -Force
    }

    $startupBackup = $null
    if ($CleanUserStartup) {
        $startupBackup = Join-Path $backupRoot "HKCU-Run-$stamp.json"
        Backup-AndCleanUserStartup -Sid $sid -BackupPath $startupBackup
    }

    $shellCommand = if ($Mode -eq "steam") {
        '"{0}" --shell --user-session' -f $installedExe
    } else {
        "explorer.exe"
    }
    Set-UserShell -Sid $sid -Command $shellCommand | Out-Null

    $state = [ordered]@{
        InstalledAt = (Get-Date).ToString("o")
        UserName = $UserName
        UserSid = $sid
        Mode = $Mode
        InstallRoot = $installRoot
        OriginalUserShell = $oldUserShell
        UserStartupBackup = $startupBackup
    }
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
}
catch {
    try { Set-UserShell -Sid $sid -Command $oldUserShell | Out-Null } catch { }
    if (Test-Path -LiteralPath $stateBackup) {
        Copy-Item -LiteralPath $stateBackup -Destination $statePath -Force
    } elseif (-not $hadStateBefore -and (Test-Path -LiteralPath $statePath)) {
        Remove-Item -LiteralPath $statePath -Force
    }
    throw
}

Write-Host "Shell SteamOS-Win configuré uniquement pour '$UserName'." -ForegroundColor Green
if ($Mode -eq "steam") {
    Write-Host "'$UserName' démarrera directement SteamOS-Win/Steam sans Explorer."
} else {
    Write-Host "'$UserName' démarrera avec Explorer."
}
Write-Host "Le compte normal conserve Explorer."
Write-Host "Pour restaurer : .\Install-PerUserSteamDispatcher.ps1 -Restore -Apply"
