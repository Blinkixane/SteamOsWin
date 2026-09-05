[CmdletBinding()]
param(
    [string]$NormalUserName = "Euxane",
    [string]$GamingUserName = "SteamGaming",
    [switch]$Apply,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour installer le changement de session."
    }
}

function Get-LocalAccountOrThrow {
    param([string]$Name)

    $account = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if (-not $account) {
        throw "Le compte local '$Name' n'existe pas."
    }
    return $account
}

function Get-TaskFolder {
    param($Service)

    try {
        return $Service.GetFolder("\SteamOsWin")
    }
    catch {
        return $Service.GetFolder("\").CreateFolder("SteamOsWin", $null)
    }
}

function New-BaseTask {
    param(
        $Service,
        [string]$Description,
        [string]$ExecutionTimeLimit = "PT2M"
    )

    $task = $Service.NewTask(0)
    $task.RegistrationInfo.Description = $Description
    $task.Settings.Enabled = $true
    $task.Settings.Hidden = $true
    $task.Settings.AllowDemandStart = $true
    $task.Settings.StartWhenAvailable = $true
    $task.Settings.DisallowStartIfOnBatteries = $false
    # The SYSTEM broker must finish quickly.  The normal-user hotkey agent is
    # intentionally long-lived and therefore uses PT0S (no time limit).
    $task.Settings.ExecutionTimeLimit = $ExecutionTimeLimit
    # Ignore a second key press while a switch is already in progress.  Two
    # concurrent tscon calls can otherwise leave the console in an ambiguous
    # state.
    $task.Settings.MultipleInstances = 2
    return $task
}

function Register-SystemTask {
    param(
        $Service,
        $Folder,
        [string]$Name,
        [string]$BrokerPath,
        [string]$ConfigPath
    )

    try { $Folder.DeleteTask($Name, 0) } catch { }

    $task = New-BaseTask $Service "SteamOS-Win secure account switch broker"
    $task.Principal.UserId = "SYSTEM"
    $task.Principal.LogonType = 5
    $task.Principal.RunLevel = 1

    $action = $task.Actions.Create(0)
    $action.Path = Join-Path ${env:SystemRoot} "System32\WindowsPowerShell\v1.0\powershell.exe"
    $action.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$BrokerPath`" -ConfigPath `"$ConfigPath`""
    $action.WorkingDirectory = Split-Path -Parent $BrokerPath

    $registered = $Folder.RegisterTaskDefinition($Name, $task, 6, $null, $null, 5, $null)
    # SYSTEM and Administrators may manage the task. Built-in Users may only
    # read and run it, preventing arbitrary privileged command injection.
    $registered.SetSecurityDescriptor("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;BU)", 0)
}

function Register-UserAgentTask {
    param(
        $Service,
        $Folder,
        [string]$Name,
        [string]$UserName,
        [string]$ExecutablePath
    )

    try { $Folder.DeleteTask($Name, 0) } catch { }

    $task = New-BaseTask $Service "SteamOS-Win Ctrl Alt W agent for $UserName" "PT0S"
    $principalId = "$env:COMPUTERNAME\$UserName"
    $task.Principal.UserId = $principalId
    $task.Principal.LogonType = 3
    $task.Principal.RunLevel = 0

    $trigger = $task.Triggers.Create(9)
    $trigger.UserId = $principalId

    $action = $task.Actions.Create(0)
    $action.Path = $ExecutablePath
    $action.Arguments = "--switch-agent"
    $action.WorkingDirectory = Split-Path -Parent $ExecutablePath

    $Folder.RegisterTaskDefinition($Name, $task, 6, $principalId, $null, 3, $null) | Out-Null
}

$dataRoot = Join-Path ${env:ProgramData} "SteamOsWin"
$configPath = Join-Path $dataRoot "session-switch.json"
$projectRoot = Split-Path -Parent $PSScriptRoot
$brokerSource = Join-Path $PSScriptRoot "Switch-SteamOsWinSession.ps1"
$publishedRoot = Join-Path $projectRoot "publish\win-x64"
$publishedExe = Join-Path $projectRoot "publish\win-x64\SteamOsWin.exe"
$installRoot = Join-Path ${env:ProgramFiles} "SteamOsWin"
$installedExe = Join-Path $installRoot "SteamOsWin.exe"
$taskFolderPath = "\SteamOsWin"
$brokerTaskName = "SessionSwitch"
$agentTaskName = "NormalUserHotkey"

if (-not $Apply -and -not $Restore) {
    Write-Host "MODE APERCU - aucune modification ne sera effectuee." -ForegroundColor Yellow
    Write-Host "Compte normal : $NormalUserName"
    Write-Host "Compte gaming : $GamingUserName"
    Write-Host "Tache SYSTEM : $taskFolderPath\$brokerTaskName"
    Write-Host "Agent au login : $taskFolderPath\$agentTaskName"
    Write-Host "Cible : Ctrl + Alt + W"
    Write-Host "Le compte cible doit avoir une session existante (deja connectee au moins une fois)."
    Write-Host "Pour appliquer : .\Install-SessionSwitch.ps1 -Apply"
    exit 0
}

Assert-Administrator
$normal = Get-LocalAccountOrThrow $NormalUserName
$gaming = Get-LocalAccountOrThrow $GamingUserName

$service = New-Object -ComObject "Schedule.Service"
$service.Connect()
$folder = Get-TaskFolder $service

if ($Restore) {
    try { $folder.DeleteTask($brokerTaskName, 0) } catch { }
    try { $folder.DeleteTask($agentTaskName, 0) } catch { }
    if (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force
    }
    if (Test-Path -LiteralPath $brokerSource) {
        Write-Host "Les taches de changement de session ont ete retirees." -ForegroundColor Green
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $brokerSource)) {
    throw "Broker introuvable : $brokerSource"
}
if (-not (Test-Path -LiteralPath $publishedExe)) {
    throw "SteamOsWin.exe publie introuvable : $publishedExe. Lance scripts\Publish.ps1 d'abord."
}

New-Item -ItemType Directory -Path $dataRoot,$installRoot -Force | Out-Null
Get-ChildItem -LiteralPath $publishedRoot -Force | Copy-Item -Destination $installRoot -Recurse -Force
Copy-Item -LiteralPath $brokerSource -Destination (Join-Path $installRoot "Switch-SteamOsWinSession.ps1") -Force
$installedBroker = Join-Path $installRoot "Switch-SteamOsWinSession.ps1"

@{
    NormalUserName = $normal.Name
    GamingUserName = $gaming.Name
} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding ASCII

# Make the configuration and broker readable/executable but not writable by
# regular users. The broker accepts no user-supplied command or path.
& icacls.exe $configPath /inheritance:r /grant:r "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" "*S-1-5-32-545:(R)" /C | Out-Null
& icacls.exe $installedBroker /inheritance:r /grant:r "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" "*S-1-5-32-545:(RX)" /C | Out-Null
$folder.SetSecurityDescriptor("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;BU)", 0)

Register-SystemTask -Service $service -Folder $folder -Name $brokerTaskName -BrokerPath $installedBroker -ConfigPath $configPath
Register-UserAgentTask -Service $service -Folder $folder -Name $agentTaskName -UserName $normal.Name -ExecutablePath $installedExe

# Start the normal-session agent immediately when the installer is being run
# from that account; otherwise it will start automatically at the next logon.
if ($env:USERNAME -ieq $normal.Name) {
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $agentAlreadyRunning = Get-CimInstance Win32_Process -Filter "Name='SteamOsWin.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId -and $_.CommandLine -match "--switch-agent" }
    if (-not $agentAlreadyRunning) {
        Start-Process -FilePath $installedExe -ArgumentList "--switch-agent" -WorkingDirectory $installRoot -WindowStyle Hidden | Out-Null
    }
}

Write-Host "Changement de session installe." -ForegroundColor Green
Write-Host "Ctrl + Alt + W basculera entre $($normal.Name) et $($gaming.Name)."
Write-Host "La cible doit avoir ete connectee au moins une fois depuis le demarrage."
    Write-Host "Le broker transfere la console puis conserve la session precedente deconnectee; il ne demande pas de mot de passe."
Write-Host "Deconnecte/reconnecte les deux comptes une fois pour lancer l'agent normal."
