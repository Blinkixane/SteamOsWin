[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,
    [string]$VhdxPath = "E:\SteamOsWin\SteamOS-Win.vhdx",
    [int]$ImageIndex = 0,
    [ValidateRange(64, 2048)]
    [int]$SizeGB = 120,
    [switch]$ListImages,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$mountedIso = $null
$mountedVhdx = $false
$diskNumber = $null
$efiLetter = $null
$osLetter = $null

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvre PowerShell en tant qu'administrateur pour préparer le VHDX."
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output -join [Environment]::NewLine) + "`n$FilePath a échoué avec le code $LASTEXITCODE.")
    }
    return $output
}

function Get-InstallImage([string]$MountRoot) {
    $wim = Join-Path $MountRoot "sources\install.wim"
    $esd = Join-Path $MountRoot "sources\install.esd"
    if (Test-Path -LiteralPath $wim) { return $wim }
    if (Test-Path -LiteralPath $esd) { return $esd }
    throw "Aucun sources\install.wim ou sources\install.esd trouvé dans $MountRoot"
}

function Invoke-DiskPartScript([string[]]$Commands) {
    $scriptPath = [IO.Path]::GetTempFileName()
    try {
        $Commands | Set-Content -LiteralPath $scriptPath -Encoding ASCII
        $output = & diskpart.exe /s $scriptPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output -join [Environment]::NewLine) + "`ndiskpart.exe a échoué avec le code $LASTEXITCODE.")
        }
        return $output
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-FreeDriveLetter([string[]]$Exclude = @()) {
    $used = [IO.DriveInfo]::GetDrives().Name | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() }
    foreach ($candidate in @('W', 'V', 'R', 'S', 'T', 'U', 'Y', 'Z')) {
        if ($used -notcontains $candidate -and $Exclude -notcontains $candidate) {
            return $candidate
        }
    }
    throw "Aucune lettre de lecteur temporaire disponible."
}

function Mount-AndPartitionVhdx([string]$Path, [int]$SizeInGB, [string]$Efi, [string]$Os) {
    if ((Get-Command New-VHD -ErrorAction SilentlyContinue) -and (Get-Command Mount-VHD -ErrorAction SilentlyContinue)) {
        New-VHD -Path $Path -SizeBytes ([int64]$SizeInGB * 1GB) -Dynamic | Out-Null
        Mount-VHD -Path $Path
        $script:mountedVhdx = $true
        $disk = Get-DiskImage -ImagePath $Path | Get-Disk
        $script:diskNumber = $disk.Number
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false | Out-Null
        $efiPartition = New-Partition -DiskNumber $disk.Number -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -DriveLetter $Efi
        Format-Volume -Partition $efiPartition -FileSystem FAT32 -NewFileSystemLabel "SYSTEM" -Confirm:$false | Out-Null
        New-Partition -DiskNumber $disk.Number -Size 16MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null
        $osPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}" -DriveLetter $Os
        Format-Volume -Partition $osPartition -FileSystem NTFS -NewFileSystemLabel "SteamOSWin" -Confirm:$false | Out-Null
        return
    }

    if (-not (Get-Command diskpart.exe -ErrorAction SilentlyContinue)) {
        throw "New-VHD/Mount-VHD et diskpart.exe sont indisponibles sur ce Windows."
    }

    $sizeMB = [int64]$SizeInGB * 1024
    Invoke-DiskPartScript @(
        "create vdisk file=`"$Path`" maximum=$sizeMB type=expandable",
        "select vdisk file=`"$Path`"",
        "attach vdisk",
        "convert gpt",
        "create partition efi size=100",
        "format fs=fat32 quick label=SYSTEM",
        "assign letter=$Efi",
        "create partition msr size=16",
        "create partition primary",
        "format fs=ntfs quick label=SteamOSWin",
        "assign letter=$Os"
    ) | ForEach-Object { Write-Verbose $_ }
    $script:mountedVhdx = $true
}

function Dismount-VirtualDisk([string]$Path) {
    if (Get-Command Dismount-VHD -ErrorAction SilentlyContinue) {
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
    } elseif (Get-Command diskpart.exe -ErrorAction SilentlyContinue) {
        Invoke-DiskPartScript @(
            "select vdisk file=`"$Path`"",
            "detach vdisk"
        ) | Out-Null
    }
}

try {
    if ($Apply) {
        Assert-Administrator
    }
    $iso = (Resolve-Path -LiteralPath $IsoPath).Path
    if ([IO.Path]::GetExtension($iso) -notin @(".iso", ".img")) {
        throw "Le média doit être une ISO ou une image IMG."
    }

    $vhdx = [IO.Path]::GetFullPath($VhdxPath)
    if (Test-Path -LiteralPath $vhdx) {
        throw "Le VHDX existe déjà et ne sera pas écrasé : $vhdx"
    }

    $parent = Split-Path -Parent $vhdx
    if (-not (Test-Path -LiteralPath $parent)) {
        if ($Apply) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        } else {
            Write-Host "Le dossier parent sera créé avec -Apply : $parent"
        }
    }

    Mount-DiskImage -ImagePath $iso -Access ReadOnly | Out-Null
    $mountedIso = Get-DiskImage -ImagePath $iso
    $isoVolume = $mountedIso | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if (-not $isoVolume) {
        throw "Impossible de trouver la lettre du lecteur ISO."
    }

    $imageFile = Get-InstallImage "$($isoVolume.DriveLetter):\"
    Write-Host "Image d'installation : $imageFile"
    Write-Host "Index disponibles :"
    Invoke-Native "dism.exe" @("/Get-WimInfo", "/WimFile:$imageFile") | ForEach-Object { Write-Host $_ }

    if ($ListImages -or -not $Apply) {
        if ($ImageIndex -eq 0) {
            Write-Host "Choisis l'index de Windows Pro affiché ci-dessus, puis relance avec -ImageIndex N -Apply."
        } else {
            Write-Host "VHDX prévu : $vhdx ($SizeGB Go dynamiques)"
            Write-Host "Commande d'application : .\New-SteamOsWinVhdx.ps1 -IsoPath `"$iso`" -VhdxPath `"$vhdx`" -ImageIndex $ImageIndex -SizeGB $SizeGB -Apply"
        }
        return
    }

    if ($ImageIndex -lt 1) {
        throw "-ImageIndex est obligatoire avec -Apply. Utilise d'abord -ListImages."
    }
    $efiLetter = Get-FreeDriveLetter
    $osLetter = Get-FreeDriveLetter -Exclude @($efiLetter)
    Mount-AndPartitionVhdx $vhdx $SizeGB $efiLetter $osLetter

    $efiRoot = "${efiLetter}:\"
    $osRoot = "${osLetter}:\"
    Invoke-Native "dism.exe" @("/Apply-Image", "/ImageFile:$imageFile", "/Index:$ImageIndex", "/ApplyDir:$osRoot") | Out-Null
    Invoke-Native "bcdboot.exe" @("${osRoot}Windows", "/s", $efiRoot, "/f", "UEFI") | Out-Null

    Write-Host "VHDX Windows créé et amorçable : $vhdx" -ForegroundColor Green
    Write-Host "Démarre-le ensuite avec : .\Install-VhdxBootEntry.ps1 -VhdxPath `"$vhdx`" -Description ""SteamOS-Win"" -Apply"
}
finally {
    if ($mountedVhdx -and $vhdx -and (Test-Path -LiteralPath $vhdx)) {
        Dismount-VirtualDisk $vhdx
    }
    if ($mountedIso) {
        Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue
    }
}
