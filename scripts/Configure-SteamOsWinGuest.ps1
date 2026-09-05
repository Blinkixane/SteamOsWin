[CmdletBinding()]
param(
    [string]$PublishedPath = "",
    [string[]]$GameDriveLetters = @("D", "E"),
    [switch]$Debloat,
    [switch]$InstallShell,
    [switch]$AllowMissingGameDrives,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour configurer Windows."
    }
}

function Resolve-PublishedPath {
    param([string]$RequestedPath)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates += $RequestedPath
    }
    $candidates += @(
        (Join-Path $PSScriptRoot "..\publish\win-x64"),
        "D:\SteamOsWin\payload\publish\win-x64",
        "E:\SteamOsWin\payload\publish\win-x64",
        "D:\SteamOsWin\publish\win-x64",
        "E:\SteamOsWin\publish\win-x64"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "SteamOsWin.exe")) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-StorageReport {
    $report = @()
    $knownRoots = @("SteamLibrary", "Games", "Steam", "Vortex Mods")

    foreach ($letter in $GameDriveLetters) {
        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        $driveRoot = "{0}:\" -f $letter
        $roots = @()

        if ($volume) {
            foreach ($rootName in $knownRoots) {
                $candidate = Join-Path $driveRoot $rootName
                if (Test-Path -LiteralPath $candidate) {
                    $roots += $candidate
                }
            }

            $topLevel = @(Get-ChildItem -LiteralPath $driveRoot -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "(?i)steam|game|library|vortex" } |
                Select-Object -First 50 -ExpandProperty FullName)
            $roots += $topLevel
        }

        $report += [ordered]@{
            DriveLetter = $letter
            Accessible = [bool]$volume
            FileSystem = if ($volume) { $volume.FileSystem } else { $null }
            Label = if ($volume) { $volume.FileSystemLabel } else { $null }
            SizeGB = if ($volume) { [math]::Round($volume.Size / 1GB, 1) } else { $null }
            FreeGB = if ($volume) { [math]::Round($volume.SizeRemaining / 1GB, 1) } else { $null }
            GameRoots = @($roots | Select-Object -Unique)
        }
    }

    return $report
}

function Get-ConfiguredServiceNames {
    $defaultNames = @(
        "ApolloService",
        "button_shutdown_daynight_listening",
        "SignalRgb.Service",
        "iCUEUpdateService",
        "Steam Client Service",
        "VSSERV",
        "BDAppSrv",
        "BDAuxSrv",
        "BDProtSrv",
        "BDSafepaySrv",
        "bdredline",
        "bdredline_agent",
        "UPDATESRV"
    )

    $configCandidates = @(
        (Join-Path $PSScriptRoot "..\publish\win-x64\background-services.json"),
        "D:\SteamOsWin\payload\publish\win-x64\background-services.json",
        "E:\SteamOsWin\payload\publish\win-x64\background-services.json"
    )

    foreach ($candidate in $configCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            try {
                $config = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
                $names = @($config.services | ForEach-Object { $_.name } | Where-Object { $_ })
                if ($names.Count -gt 0) {
                    return @($names | Select-Object -Unique)
                }
            } catch {
                # Keep the safe built-in list if the optional config is unreadable.
            }
        }
    }

    return $defaultNames
}

function Start-ConfiguredServices {
    param([string[]]$Names)

    $results = @()
    foreach ($name in $Names) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) {
            $results += [ordered]@{ Name = $name; Status = "missing"; Error = $null }
            continue
        }

        try {
            if ($service.Status -ne "Running") {
                Start-Service -Name $name -ErrorAction Stop
                $service = Get-Service -Name $name
            }
            $results += [ordered]@{ Name = $name; Status = [string]$service.Status; Error = $null }
        } catch {
            $results += [ordered]@{ Name = $name; Status = [string]$service.Status; Error = $_.Exception.Message }
        }
    }

    return $results
}

function Set-PolicyValue {
    param([string]$Path, [string]$Name, [int]$Value)

    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Invoke-ConservativeDebloat {
    param([string]$DataRoot)

    $patterns = @(
        "^Clipchamp\.Clipchamp$",
        "^Microsoft\.BingNews$",
        "^Microsoft\.GetHelp$",
        "^Microsoft\.Getstarted$",
        "^Microsoft\.MicrosoftOfficeHub$",
        "^Microsoft\.MicrosoftSolitaireCollection$",
        "^Microsoft\.People$",
        "^Microsoft\.Todos$",
        "^Microsoft\.WindowsFeedbackHub$",
        "^Microsoft\.WindowsMaps$",
        "^Microsoft\.549981C3F5F10$"
    )

    $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $name = $_.Name; $patterns | Where-Object { $name -match $_ } })
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $name = $_.DisplayName; $patterns | Where-Object { $name -match $_ } })

    $inventory = [ordered]@{
        CapturedAt = (Get-Date).ToString("o")
        Installed = @($installed | Select-Object Name, PackageFullName)
        Provisioned = @($provisioned | Select-Object DisplayName, PackageName)
    }
    $inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $DataRoot "pre-debloat-packages.json") -Encoding UTF8

    $removedInstalled = @()
    foreach ($package in $installed | Sort-Object PackageFullName -Unique) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            $removedInstalled += $package.PackageFullName
        } catch {
            Write-Warning "Impossible de retirer $($package.PackageFullName) : $($_.Exception.Message)"
        }
    }

    $removedProvisioned = @()
    foreach ($package in $provisioned | Sort-Object PackageName -Unique) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
            $removedProvisioned += $package.PackageName
        } catch {
            Write-Warning "Impossible de retirer le package provisionne $($package.PackageName) : $($_.Exception.Message)"
        }
    }

    Set-PolicyValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
    Set-PolicyValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1
    Set-PolicyValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-PolicyValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds" 0

    $contentDelivery = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    New-Item -Path $contentDelivery -Force | Out-Null
    foreach ($name in @(
        "ContentDeliveryAllowed",
        "OemPreInstalledAppsEnabled",
        "PreInstalledAppsEnabled",
        "PreInstalledAppsEverEnabled",
        "SilentInstalledAppsEnabled",
        "SystemPaneSuggestionsEnabled",
        "SubscribedContent-338388Enabled",
        "SubscribedContent-338389Enabled"
    )) {
        New-ItemProperty -Path $contentDelivery -Name $name -PropertyType DWord -Value 0 -Force | Out-Null
    }

    return [ordered]@{
        InstalledCandidates = $installed.Count
        ProvisionedCandidates = $provisioned.Count
        RemovedInstalled = @($removedInstalled)
        RemovedProvisioned = @($removedProvisioned)
        OneDrive = "disabled by policy, not uninstalled"
        WindowsStoreAndRuntime = "preserved"
        NvidiaAndSteamComponents = "preserved"
    }
}

$dataRoot = Join-Path ${env:ProgramData} "SteamOsWin"
$statePath = Join-Path $dataRoot "guest-setup-state.json"
$GameDriveLetters = @($GameDriveLetters | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim().TrimEnd(":").ToUpperInvariant() } | Where-Object { $_ -match "^[A-Z]$" } | Select-Object -Unique)
$storageReport = Get-StorageReport
$published = Resolve-PublishedPath $PublishedPath
$serviceNames = Get-ConfiguredServiceNames

if (-not $Apply) {
    Write-Host "MODE APERCU - aucune modification ne sera effectuee." -ForegroundColor Yellow
    Write-Host "Les volumes D/E ne seront ni formates ni repartitionnes."
    $storageReport | Format-Table -AutoSize
    if ($Debloat) { Write-Host "Nettoyage demande : oui (a appliquer avec -Apply)." }
    if ($InstallShell) {
        Write-Host "Installation du shell demandee : oui"
        Write-Host "Payload detecte : $published"
    }
    Write-Host "Services surveilles : $($serviceNames -join ', ')"
    Write-Host "Pour appliquer : .\Configure-SteamOsWinGuest.ps1 -Debloat -InstallShell -Apply"
    exit 0
}

Assert-Administrator
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null

if ($InstallShell -and -not $AllowMissingGameDrives) {
    $missingDrives = @($storageReport | Where-Object { -not $_.Accessible })
    if ($missingDrives.Count -gt 0) {
        $missingNames = $missingDrives | ForEach-Object { "$($_.DriveLetter):" }
        throw "Volumes de jeux introuvables : $($missingNames -join ', '). Aucun changement applique. Verifie les lettres dans Gestion des disques ou utilise -GameDriveLetters, puis relance."
    }
}

$debloatResult = $null
if ($Debloat) {
    $debloatResult = Invoke-ConservativeDebloat $dataRoot
}

$serviceResult = Start-ConfiguredServices $serviceNames

if ($InstallShell) {
    if (-not $published) {
        throw "SteamOsWin.exe introuvable. Passe -PublishedPath vers le dossier publish\win-x64 copie dans cette installation."
    }

    $installer = Join-Path $PSScriptRoot "Install-SteamOsWin.ps1"
    & $installer -Mode steam -PublishedPath $published -Apply
}

$state = [ordered]@{
    ConfiguredAt = (Get-Date).ToString("o")
    Installation = "Windows VHDX SteamOS-like"
    Volumes = $storageReport
    Services = $serviceResult
    Debloat = $debloatResult
    ShellInstalled = [bool]$InstallShell
    Warning = "Les volumes D/E sont seulement inventories. Aucun formatage ou repartitionnement n'est effectue."
}
$state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-Host "Configuration invitee terminee." -ForegroundColor Green
Write-Host "Rapport : $statePath" -ForegroundColor Green
Write-Host "Les bibliotheques Steam existantes sur D/E restent intactes. Ajoute leur dossier dans Steam si necessaire."
