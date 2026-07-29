#Requires -Version 5.1

<#
.SYNOPSIS
Safely prepares, integrates, updates, and removes local Windows factory recovery.

.DESCRIPTION
The workflow is deliberately split into independent operations:
  --create    Plans, prepares, and integrates in one guided workflow.
  --prepare   Creates/populates the recovery partition; never changes boot data.
  --integrate Registers WinRE and adds a boot entry; never changes partitions.
  --update    Rebuilds recovery files and replaces them in place.
  --remove    Removes a verified package, its integration, and its partition.

With no operation option, the script prints a read-only plan.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $CliArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RecoveryLabel = 'FACTORY_RECOVERY'
$RecoverySizeGB = 20
$PartitionAlignmentReserve = 1MB
$BootMenuTimeoutSeconds = 3
$ImageIndex = 1
$ImageIndexSpecified = $false
$RecoverySizeSpecified = $false
$AllowedImageIndexes = @()
$ImagePath = $null
$Create = $false
$RemoveOriginalWinre = $false
$Prepare = $false
$Integrate = $false
$Update = $false
$RemoveFactory = $false
$Help = $false

for ($i = 0; $i -lt $CliArguments.Count; $i++) {
    $option = $CliArguments[$i].ToLowerInvariant()
    switch ($option) {
        { $_ -in @('--help', '-h') } { $Help = $true }
        { $_ -in @('--create', '-c') } { $Create = $true }
        { $_ -in @('--remove-original-winre', '-o') } {
            $RemoveOriginalWinre = $true
        }
        { $_ -in @('--prepare', '-p') } { $Prepare = $true }
        { $_ -in @('--integrate', '-g') } { $Integrate = $true }
        { $_ -in @('--update', '-u') } { $Update = $true }
        { $_ -in @('--remove', '-r') } { $RemoveFactory = $true }
        { $_ -in @('--what-if', '-w') } { $WhatIfPreference = $true }
        { $_ -in @('--verbose', '-v') } { $VerbosePreference = 'Continue' }
        { $_ -in @('--image-path', '-i', '--image-index', '-n',
                '--recovery-size-gb', '-s') } {
            if (++$i -ge $CliArguments.Count) { throw "Missing value after $option." }
            $value = $CliArguments[$i]
            if ($option -in @('--image-path', '-i')) {
                $ImagePath = $value
            } elseif ($option -in @('--image-index', '-n')) {
                $parsed = 0
                if (-not [int]::TryParse($value, [ref]$parsed) -or $parsed -lt 1) {
                    throw "$option requires a positive integer."
                }
                $ImageIndex = $parsed
                $ImageIndexSpecified = $true
            } else {
                $parsed = 0
                if (-not [int]::TryParse($value, [ref]$parsed) -or
                    $parsed -lt 8 -or $parsed -gt 2048) {
                    throw "$option must be from 8 through 2048."
                }
                $RecoverySizeGB = $parsed
                $RecoverySizeSpecified = $true
            }
        }
        default { throw "Unknown option '$($CliArguments[$i])'. Use --help." }
    }
}

if ($Help) {
@'
Windows Factory Recovery Manager

USAGE
  .\Manage-WindowsFactoryRecovery.ps1 -i <capture.wim>
      Show a read-only plan.

  .\Manage-WindowsFactoryRecovery.ps1 --create
      Show the workflow, ask to continue, collect parameters, plan, prepare,
      and integrate.

  .\Manage-WindowsFactoryRecovery.ps1 -i <capture.wim> --prepare
      Create/populate recovery without changing BCD or WinRE.

  .\Manage-WindowsFactoryRecovery.ps1 --integrate
      Integrate an already prepared package; never repartitions.

  .\Manage-WindowsFactoryRecovery.ps1 -i <new.wim> --update
      Side-by-side stage, hash-check, and replace recovery files.

  .\Manage-WindowsFactoryRecovery.ps1 --remove
      Remove verified factory recovery and reclaim its partition space.

  .\Manage-WindowsFactoryRecovery.ps1 --remove-original-winre
      Remove one verified legacy WinRE partition after factory integration.

OPTIONS
  --image-path, -i <path>        Captured WIM
  --image-index, -n <number>     Lock recovery to one index; default allows all
  --recovery-size-gb, -s <GB>    New partition size; default 20
  --create, -c                    Guided plan, prepare, and integrate workflow
  --remove-original-winre, -o     Remove verified legacy WinRE after integration
  --prepare, -p                   Partition/file preparation only
  --integrate, -g                 BCD/WinRE integration only
  --update, -u                    Existing package file update only
  --remove, -r                    Remove factory recovery completely
  --what-if, -w                   Stop after the plan
  --verbose, -v                   Detailed commands
  --help, -h                      This help

SAFETY
  Preparation always preserves existing WinRE. Original WinRE removal is a
  separate post-integration operation and extends Factory Recovery only into
  the verified adjacent released space.
  Integration asks before adding a Boot Manager entry.
  Normal Windows remains the default boot entry.
  Removal requires typing REMOVE-FACTORY and creates a BCD checkpoint.
'@ | Write-Host
    return
}

$modeCount = @(
    $Create, $RemoveOriginalWinre, $Prepare, $Integrate, $Update, $RemoveFactory
).Where({ $_ }).Count
if ($modeCount -gt 1) { throw 'Use only one operation option.' }
if ($Create -and -not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'FACTORY RECOVERY CREATE WORKFLOW' -ForegroundColor Cyan
    Write-Host '  1. Collect the image and recovery-size parameters.'
    Write-Host '  2. Show the complete machine, partition, and image plan.'
    Write-Host '  3. Prepare and verify the recovery partition and files.'
    Write-Host '  4. Integrate the verified package with WinRE and, optionally, Boot Manager.'
    while ($true) {
        $answer = (Read-Host `
            'Continue to create the factory recovery ? [y/n]').Trim().ToLowerInvariant()
        if ($answer -in @('y', 'yes')) { break }
        if ($answer -in @('n', 'no')) {
            Write-Host 'Create cancelled; no changes made.'
            return
        }
        Write-Host 'Please enter y or n.' -ForegroundColor Yellow
    }
    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        $ImagePath = (Read-Host 'Captured WIM path').Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($ImagePath)) {
            throw 'A captured WIM path is required.'
        }
    }
    if (-not $RecoverySizeSpecified) {
        $sizeAnswer = (Read-Host `
            'Recovery partition size in GB, or press Enter for 20').Trim()
        if ($sizeAnswer) {
            $parsedSize = 0
            if (-not [int]::TryParse($sizeAnswer, [ref]$parsedSize) -or
                $parsedSize -lt 8 -or $parsedSize -gt 2048) {
                throw 'Recovery size must be from 8 through 2048 GB.'
            }
            $RecoverySizeGB = $parsedSize
        }
    }
}
if (-not $Integrate -and -not $RemoveFactory -and -not $RemoveOriginalWinre -and
    [string]::IsNullOrWhiteSpace($ImagePath)) {
    throw '--image-path is required for plan, prepare, and update.'
}
if ($ImagePath -and -not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
    throw "Image not found: $ImagePath"
}

# MOCK-ADMIN-CHECK-BEGIN
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$administrator = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $administrator) { throw 'Run from elevated Windows PowerShell.' }
# MOCK-ADMIN-CHECK-END

$RecoveryBytes = [uint64]$RecoverySizeGB * 1GB
$WorkingRoot = Join-Path $env:ProgramData 'FactoryRecoveryBuild'
$MountPath = Join-Path $WorkingRoot 'Mount'
$RecoveryLetter = @('R', 'Q', 'T', 'U', 'V') |
    Where-Object { -not (Test-Path "$_`:\" ) } | Select-Object -First 1
if (-not $RecoveryLetter) { throw 'No temporary drive letter is available.' }

function Invoke-Native {
    param([string] $File, [string[]] $Arguments = @())
    Write-Verbose "$File $($Arguments -join ' ')"
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "'$File' failed with exit code $LASTEXITCODE." }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string] $Prompt)
    while ($true) {
        $answer = (Read-Host "$Prompt [y/n]").Trim().ToLowerInvariant()
        switch ($answer) {
            { $_ -in @('y', 'yes') } { return $true }
            { $_ -in @('n', 'no') } { return $false }
            default { Write-Host 'Please enter y or n.' -ForegroundColor Yellow }
        }
    }
}

function Get-WimImages {
    param([string] $Path)
    $result = & dism.exe /English /Get-WimInfo "/WimFile:$Path" 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'DISM cannot enumerate the WIM images.' }
    $matches = [regex]::Matches(
        ($result -join "`n"),
        '(?ms)^\s*Index\s*:\s*(?<index>\d+)\s*$.*?^\s*Name\s*:\s*(?<name>[^\r\n]+)')
    if ($matches.Count -eq 0) { throw 'No Windows images were found in the WIM.' }
    foreach ($match in $matches) {
        $index = [int]$match.Groups['index'].Value
        $details = & dism.exe /English /Get-WimInfo "/WimFile:$Path" `
            "/Index:$index" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "DISM cannot read details for WIM image index $index."
        }
        $detailText = $details -join "`n"
        $readField = {
            param([string] $Field)
            $fieldMatch = [regex]::Match(
                $detailText,
                "(?im)^\s*$([regex]::Escape($Field))\s*:\s*(?<value>[^\r\n]*)$")
            if ($fieldMatch.Success) {
                return $fieldMatch.Groups['value'].Value.Trim()
            }
            ''
        }
        [pscustomobject]@{
            Index = $index
            Name = $match.Groups['name'].Value.Trim()
            Description = & $readField 'Description'
            Edition = & $readField 'Edition'
            Installation = & $readField 'Installation'
            Architecture = & $readField 'Architecture'
            Version = & $readField 'Version'
            Size = & $readField 'Size'
            Modified = & $readField 'Modified'
        }
    }
}

function Get-WinreRegistration {
    $result = & reagentc.exe /info 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'REAgentC discovery failed.' }
    $text = $result -join "`n"
    $location = [regex]::Match($text,
        'harddisk(?<disk>\d+)\\partition(?<part>\d+)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    [pscustomobject]@{
        Enabled = $text -match '(?im)Windows RE status:\s*Enabled'
        DiskNumber = if ($location.Success) { [int]$location.Groups['disk'].Value } else { $null }
        PartitionNumber = if ($location.Success) { [int]$location.Groups['part'].Value } else { $null }
        Raw = $text
    }
}

function Get-FactoryPaths {
    param([string] $Letter)
    $root = "$Letter`:\FactoryRecovery"
    [pscustomobject]@{
        Root = $root
        RecoveryRoot = "$Letter`:\Recovery\WindowsRE"
        Image = Join-Path $root 'FactoryImage.wim'
        FactoryRE = Join-Path $root 'FactoryRE.wim'
        WinRE = "$Letter`:\Recovery\WindowsRE\Winre.wim"
        BootSdi = Join-Path $root 'boot.sdi'
        Manifest = Join-Path $root 'Manifest.json'
    }
}

function Remove-TemporaryAccessPath {
    param(
        [int] $DiskNumber,
        [int] $PartitionNumber,
        [string] $Letter
    )

    Remove-PartitionAccessPath -DiskNumber $DiskNumber `
        -PartitionNumber $PartitionNumber -AccessPath "$Letter`:\" `
        -ErrorAction SilentlyContinue
    $partition = Get-Partition -DiskNumber $DiskNumber `
        -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    $volume = if ($partition) {
        Get-Volume -Partition $partition -ErrorAction SilentlyContinue
    }
    if ($volume -and $volume.DriveLetter -and
        $volume.DriveLetter.ToString() -eq $Letter) {
        $cleanupFile = Join-Path $WorkingRoot `
            "RemoveAccess-$DiskNumber-$PartitionNumber.txt"
@"
select disk $DiskNumber
select partition $PartitionNumber
remove letter=$Letter
exit
"@ | Set-Content -LiteralPath $cleanupFile -Encoding ASCII
        Invoke-Native diskpart.exe @('/s', $cleanupFile) | Out-Host
    }
}

function Get-VerifiedPartitionAtOffset {
    param(
        [int] $DiskNumber,
        [uint64] $Offset,
        [uint64] $Size,
        [string] $Purpose
    )

    $matches = @(Get-Partition -DiskNumber $DiskNumber |
        Where-Object {
            [uint64]$_.Offset -eq $Offset -and [uint64]$_.Size -eq $Size
        })
    if ($matches.Count -ne 1) {
        throw "$Purpose identity check failed at offset $Offset, size $Size."
    }
    $matches[0]
}

function Assert-BootLayoutUnchanged {
    param(
        [object] $ExpectedOs,
        [object] $ExpectedSystem
    )

    $currentDisk = Get-Disk -Number $ExpectedOs.DiskNumber
    if ($currentDisk.IsOffline -or $currentDisk.IsReadOnly -or
        -not $currentDisk.IsBoot -or -not $currentDisk.IsSystem) {
        throw 'Boot disk became offline, read-only, or lost boot/system identity.'
    }
    $currentOs = Get-VerifiedPartitionAtOffset -DiskNumber $ExpectedOs.DiskNumber `
        -Offset ([uint64]$ExpectedOs.Offset) -Size ([uint64]$ExpectedOs.Size) `
        -Purpose 'Windows partition'
    $currentSystem = Get-VerifiedPartitionAtOffset `
        -DiskNumber $ExpectedSystem.DiskNumber `
        -Offset ([uint64]$ExpectedSystem.Offset) -Size ([uint64]$ExpectedSystem.Size) `
        -Purpose 'EFI system partition'
    if ($currentOs.GptType -ne '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -or
        $currentSystem.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') {
        throw 'Windows or EFI partition type changed unexpectedly.'
    }
}

function Get-BaseWinre {
    param([object] $Registration)
    $local = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    if ($null -eq $Registration.DiskNumber) {
        throw 'Winre.wim is not local and REAgentC has no registered location.'
    }
    $part = Get-Partition -DiskNumber $Registration.DiskNumber `
        -PartitionNumber $Registration.PartitionNumber
    $vol = Get-Volume -Partition $part
    $letter = if ($vol.DriveLetter) { $vol.DriveLetter.ToString() } else { 'Q' }
    $added = -not $vol.DriveLetter
    try {
        if ($added) {
            Add-PartitionAccessPath -DiskNumber $part.DiskNumber `
                -PartitionNumber $part.PartitionNumber -AccessPath "$letter`:\"
        }
        $source = "$letter`:\Recovery\WindowsRE\Winre.wim"
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "WinRE image not found at $source."
        }
        $copy = Join-Path $WorkingRoot 'BaseWinre.wim'
        Copy-Item -LiteralPath $source -Destination $copy -Force
        return $copy
    } finally {
        if ($added) {
            Remove-TemporaryAccessPath -DiskNumber $part.DiskNumber `
                -PartitionNumber $part.PartitionNumber -Letter $letter
        }
    }
}

function New-CustomWinre {
    param(
        [string] $BaseWinre,
        [int] $DiskNumber,
        [int] $OsPartitionNumber,
        [int] $RecoveryPartitionNumber,
        [int] $SystemPartitionNumber,
        [string] $DiskId,
        [int[]] $Indexes,
        [object[]] $Images
    )
    if (-not $Indexes.Count) {
        throw 'At least one factory image index is required.'
    }
    $normal = Join-Path $WorkingRoot 'Winre.custom.wim'
    $factory = Join-Path $WorkingRoot 'FactoryRE.custom.wim'
    Copy-Item $BaseWinre $normal -Force
    $mounted = $false
    try {
        Invoke-Native dism.exe @('/Mount-Image', "/ImageFile:$normal",
            '/Index:1', "/MountDir:$MountPath") | Out-Host
        $mounted = $true
        $tools = Join-Path $MountPath 'Sources\Recovery\Tools'
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
        Remove-Item -LiteralPath (Join-Path $tools 'FactoryRecoveryLauncher.exe') `
            -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $MountPath 'Windows\System32\cmd.exe') `
            (Join-Path $tools 'cmd.exe') -Force
        Get-ChildItem -LiteralPath (Join-Path $MountPath 'Windows\System32') `
            -Directory | ForEach-Object {
                $mui = Join-Path $_.FullName 'cmd.exe.mui'
                if (Test-Path -LiteralPath $mui -PathType Leaf) {
                    $languageDir = Join-Path $tools $_.Name
                    New-Item -ItemType Directory -Path $languageDir -Force | Out-Null
                    Copy-Item -LiteralPath $mui `
                        -Destination (Join-Path $languageDir 'cmd.exe.mui') -Force
                }
            }
        $findstrSource = Join-Path $env:SystemRoot 'System32\findstr.exe'
        if (-not (Test-Path -LiteralPath $findstrSource -PathType Leaf)) {
            throw "Required disk-identity verifier was not found: $findstrSource"
        }
        Copy-Item -LiteralPath $findstrSource `
            -Destination (Join-Path $tools 'findstr.exe') -Force
        @"
select disk $DiskNumber
uniqueid disk
exit
"@ | Set-Content (Join-Path $tools 'IdentifyDisk.txt') -Encoding ASCII
        @"
select disk $DiskNumber
select partition $RecoveryPartitionNumber
assign letter=R
select partition $OsPartitionNumber
format fs=ntfs quick label=Windows
assign letter=W
select partition $SystemPartitionNumber
assign letter=S
exit
"@ | Set-Content (Join-Path $tools 'RestoreDisk.txt') -Encoding ASCII
        $catalogLines = @(
            'AVAILABLE FACTORY IMAGES',
            '========================',
            ''
        )
        foreach ($availableImage in $Images |
            Where-Object Index -in $Indexes |
            Sort-Object Index) {
            $imageLines = @(
                "Image index: $($availableImage.Index)",
                "Name: $(($availableImage.Name -replace '[\r\n]', ' ').Trim())"
            )
            foreach ($field in @(
                    'Description',
                    'Edition',
                    'Installation',
                    'Architecture',
                    'Version',
                    'Size',
                    'Modified')) {
                $value = "$($availableImage.$field)".Trim() -replace '[\r\n]', ' '
                if ($value) { $imageLines += "$field`: $value" }
            }
            $catalogLines += $imageLines
            $catalogLines += ''
            @(
                'SELECTED FACTORY IMAGE',
                '======================',
                $imageLines,
                ''
            ) | Set-Content (Join-Path $tools `
                "ImageDetails-$($availableImage.Index).txt") -Encoding ASCII
        }
        $catalogLines | Set-Content `
            (Join-Path $tools 'ImageCatalog.txt') -Encoding ASCII
        $validator = @('@echo off')
        foreach ($allowedIndex in $Indexes) {
            $validator += "if `"%~1`"==`"$allowedIndex`" exit /b 0"
        }
        $validator += 'exit /b 1'
        $validator | Set-Content `
            (Join-Path $tools 'ValidateImageIndex.cmd') -Encoding ASCII
        $showDetails = @('@echo off')
        foreach ($allowedIndex in $Indexes) {
            $showDetails += "if `"%~1`"==`"$allowedIndex`" goto image$allowedIndex"
        }
        $showDetails += 'exit /b 1'
        foreach ($allowedIndex in $Indexes) {
            $showDetails += ":image$allowedIndex"
            $showDetails += "type X:\Sources\Recovery\Tools\ImageDetails-$allowedIndex.txt"
            $showDetails += 'exit /b 0'
        }
        $showDetails | Set-Content `
            (Join-Path $tools 'ShowImageDetails.cmd') -Encoding ASCII
        $selectionBlock = if ($Indexes.Count -gt 1) {
@'
type X:\Sources\Recovery\Tools\ImageCatalog.txt
:selectimage
set "IMAGE_INDEX="
set /p IMAGE_INDEX=Select image index:
call X:\Sources\Recovery\Tools\ValidateImageIndex.cmd "%IMAGE_INDEX%"
if errorlevel 1 (
  echo Invalid image index.
  goto selectimage
)
'@
        } else {
            "set `"IMAGE_INDEX=$($Indexes[0])`""
        }
        @"
@echo off
wpeinit
diskpart /s X:\Sources\Recovery\Tools\IdentifyDisk.txt > X:\FactoryDisk.txt
"X:\Sources\Recovery\Tools\findstr.exe" /i /c:"$DiskId" X:\FactoryDisk.txt >nul
if errorlevel 1 goto wrongdisk
$selectionBlock
call X:\Sources\Recovery\Tools\ShowImageDetails.cmd "%IMAGE_INDEX%"
if errorlevel 1 goto failed
echo FACTORY RESTORE WILL ERASE THE WINDOWS PARTITION.
set /p CONFIRM=Type RESTORE in uppercase to continue:
if not "%CONFIRM%"=="RESTORE" goto cancel
diskpart /s X:\Sources\Recovery\Tools\RestoreDisk.txt
if errorlevel 1 goto failed
dism /Apply-Image /ImageFile:R:\FactoryRecovery\FactoryImage.wim /Index:%IMAGE_INDEX% /ApplyDir:W:\
if errorlevel 1 goto failed
bcdboot W:\Windows /s S: /f UEFI
if errorlevel 1 goto failed
wpeutil reboot
:wrongdisk
echo Expected disk ID $DiskId was not found at disk $DiskNumber.
echo No partition was formatted.
pause
cmd.exe
:failed
echo Restore failed. Do not reboot until the error is investigated.
pause
cmd.exe
:cancel
echo Restore cancelled without formatting.
wpeutil reboot
"@ | Set-Content (Join-Path $tools 'RestoreFactory.cmd') -Encoding ASCII
        @'
<?xml version="1.0" encoding="utf-8"?>
<Recovery><RecoveryTools>
<RelativeFilePath>cmd.exe</RelativeFilePath>
<CommandLineParam>/d /c X:\Sources\Recovery\Tools\RestoreFactory.cmd</CommandLineParam>
</RecoveryTools></Recovery>
'@ | Set-Content (Join-Path $tools 'WinREConfig.xml') -Encoding UTF8
        @'
[LaunchApps]
%SYSTEMROOT%\System32\wpeinit.exe
%SYSTEMDRIVE%\Sources\Recovery\RecEnv.exe
'@ | Set-Content `
            (Join-Path $MountPath 'Windows\System32\winpeshl.ini') `
            -Encoding ASCII
        Invoke-Native dism.exe @('/Unmount-Image', "/MountDir:$MountPath", '/Commit') |
            Out-Host
        $mounted = $false
        Copy-Item $normal $factory -Force
        Invoke-Native dism.exe @('/Mount-Image', "/ImageFile:$factory",
            '/Index:1', "/MountDir:$MountPath") | Out-Host
        $mounted = $true
        @'
[LaunchApps]
"%SYSTEMROOT%\System32\cmd.exe","/d /c X:\Sources\Recovery\Tools\RestoreFactory.cmd"
'@ | Set-Content (Join-Path $MountPath 'Windows\System32\winpeshl.ini') -Encoding ASCII
        Invoke-Native dism.exe @('/Unmount-Image', "/MountDir:$MountPath", '/Commit') |
            Out-Host
        $mounted = $false
        [pscustomobject]@{ WinRE = $normal; FactoryRE = $factory }
    } finally {
        if ($mounted) {
            & dism.exe /Unmount-Image "/MountDir:$MountPath" /Discard | Out-Null
        }
    }
}

function New-CleanWinre {
    param([string] $SourceWinre)

    $clean = Join-Path $WorkingRoot 'Winre.clean.wim'
    Copy-Item -LiteralPath $SourceWinre -Destination $clean -Force
    $mounted = $false
    try {
        Invoke-Native dism.exe @('/Mount-Image', "/ImageFile:$clean",
            '/Index:1', "/MountDir:$MountPath") | Out-Host
        $mounted = $true
        $tools = Join-Path $MountPath 'Sources\Recovery\Tools'
        foreach ($name in @(
                'WinREConfig.xml',
                'RestoreFactory.cmd',
                'RestoreDisk.txt',
                'IdentifyDisk.txt',
                'ImageCatalog.txt',
                'ValidateImageIndex.cmd',
                'ShowImageDetails.cmd',
                'findstr.exe',
                'cmd.exe',
                'FactoryRecoveryLauncher.exe')) {
            Remove-Item -LiteralPath (Join-Path $tools $name) `
                -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem -LiteralPath $tools -Filter 'cmd.exe.mui' `
            -File -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Force
        Get-ChildItem -LiteralPath $tools -Filter 'ImageDetails-*.txt' `
            -File -ErrorAction SilentlyContinue |
            Remove-Item -Force
        @'
[LaunchApps]
%SYSTEMROOT%\System32\wpeinit.exe
%SYSTEMDRIVE%\Sources\Recovery\RecEnv.exe
'@ | Set-Content `
            (Join-Path $MountPath 'Windows\System32\winpeshl.ini') `
            -Encoding ASCII
        Invoke-Native dism.exe @('/Unmount-Image', "/MountDir:$MountPath",
            '/Commit') | Out-Host
        $mounted = $false
        $validation = & dism.exe /English /Get-WimInfo `
            "/WimFile:$clean" /Index:1 2>&1
        if ($LASTEXITCODE -ne 0 -or
            ($validation -join ' ') -notmatch '\bIndex\s*:\s*1\b') {
            throw 'Cleaned standard WinRE image failed DISM validation.'
        }
        $clean
    }
    finally {
        if ($mounted) {
            & dism.exe /Unmount-Image "/MountDir:$MountPath" /Discard | Out-Null
        }
    }
}

function Write-Manifest {
    param([object] $Paths, [object] $Part, [string] $Status,
        [string] $Hash, [object] $Bcd)
    $manifestOs = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
    $manifestSystem = Get-VerifiedPartitionAtOffset `
        -DiskNumber $systemPart.DiskNumber `
        -Offset ([uint64]$systemPart.Offset) -Size ([uint64]$systemPart.Size) `
        -Purpose 'EFI system partition for manifest'
    $manifestRecovery = Get-VerifiedPartitionAtOffset `
        -DiskNumber $Part.DiskNumber `
        -Offset ([uint64]$Part.Offset) -Size ([uint64]$Part.Size) `
        -Purpose 'Factory Recovery partition for manifest'
    [ordered]@{
        SchemaVersion = 4
        Status = $Status
        PreparedUtc = [DateTime]::UtcNow.ToString('o')
        DiskId = $diskId
        DiskNumber = $osDisk.Number
        OsPartitionNumber = $manifestOs.PartitionNumber
        OsPartitionOffset = [uint64]$manifestOs.Offset
        OsPartitionSize = [uint64]$manifestOs.Size
        RecoveryPartitionNumber = $manifestRecovery.PartitionNumber
        RecoveryPartitionOffset = [uint64]$manifestRecovery.Offset
        RecoveryPartitionSize = [uint64]$manifestRecovery.Size
        SystemPartitionNumber = $manifestSystem.PartitionNumber
        SystemPartitionOffset = [uint64]$manifestSystem.Offset
        SystemPartitionSize = [uint64]$manifestSystem.Size
        ImageIndex = if ($AllowedImageIndexes.Count -eq 1) {
            $AllowedImageIndexes[0]
        } else { $null }
        ImageSelection = if ($AllowedImageIndexes.Count -gt 1) {
            'Recovery'
        } else { 'Locked' }
        AllowedImageIndexes = @($AllowedImageIndexes)
        ImageSha256 = $Hash
        LoaderGuid = if ($Bcd) { $Bcd.LoaderGuid } else { $null }
        RamdiskGuid = if ($Bcd) { $Bcd.RamdiskGuid } else { $null }
    } | ConvertTo-Json | Set-Content $Paths.Manifest -Encoding UTF8
}

function Assert-Package {
    param(
        [object] $Paths,
        [object] $Part,
        [switch] $AllowLegacyPartitionNumberDrift
    )
    foreach ($file in @($Paths.Image, $Paths.FactoryRE, $Paths.WinRE, $Paths.Manifest)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Incomplete package; missing $file."
        }
    }
    $data = Get-Content $Paths.Manifest -Raw | ConvertFrom-Json
    if ($data.SchemaVersion -notin @(2, 3, 4)) {
        throw "Unsupported package manifest schema '$($data.SchemaVersion)'."
    }
    if ($data.DiskId -ne $diskId) {
        throw ("Package disk ID mismatch. Manifest: '$($data.DiskId)'; " +
            "current: '$diskId'.")
    }
    if ($data.Status -eq 'UpdateInProgress') {
        if (-not $AllowLegacyPartitionNumberDrift) {
            throw ('A previous in-place update did not finish. Run --update ' +
                'again with the captured WIM before integration or removal.')
        }
        Write-Warning 'Resuming a previously interrupted in-place update.'
    }
    if ($Part.DiskNumber -ne $osDisk.Number -or
        $Part.GptType -ne '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') {
        throw 'The labeled Factory Recovery volume is not a recovery partition on the Windows disk.'
    }
    $currentOs = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
    if ($data.SchemaVersion -eq 4) {
        $layoutMismatches = [Collections.Generic.List[string]]::new()
        foreach ($comparison in @(
                @('Windows offset', [uint64]$data.OsPartitionOffset,
                    [uint64]$currentOs.Offset),
                @('Windows size', [uint64]$data.OsPartitionSize,
                    [uint64]$currentOs.Size),
                @('Factory offset', [uint64]$data.RecoveryPartitionOffset,
                    [uint64]$Part.Offset),
                @('Factory size', [uint64]$data.RecoveryPartitionSize,
                    [uint64]$Part.Size),
                @('EFI offset', [uint64]$data.SystemPartitionOffset,
                    [uint64]$systemPart.Offset),
                @('EFI size', [uint64]$data.SystemPartitionSize,
                    [uint64]$systemPart.Size))) {
            if ($comparison[1] -ne $comparison[2]) {
                $layoutMismatches.Add(
                    "$($comparison[0]): manifest $($comparison[1]), current $($comparison[2])")
            }
        }
        if ($layoutMismatches.Count) {
            throw ("Package immutable-layout mismatch: " +
                ($layoutMismatches -join '; '))
        }
    } else {
        $numberMismatches = [Collections.Generic.List[string]]::new()
        if ($data.OsPartitionNumber -ne $currentOs.PartitionNumber) {
            $numberMismatches.Add(
                "Windows: manifest $($data.OsPartitionNumber), current $($currentOs.PartitionNumber)")
        }
        if ($data.RecoveryPartitionNumber -ne $Part.PartitionNumber) {
            $numberMismatches.Add(
                "Factory: manifest $($data.RecoveryPartitionNumber), current $($Part.PartitionNumber)")
        }
        if ($numberMismatches.Count) {
            $detail = $numberMismatches -join '; '
            if (-not $AllowLegacyPartitionNumberDrift) {
                throw ("Legacy package partition-number mismatch: $detail. " +
                    'Run --update with the captured WIM to rebuild the embedded ' +
                    'restore layout before integration.')
            }
            Write-Warning ("Legacy partition numbers changed ($detail). Update " +
                'will rebuild both recovery images and write an immutable schema-4 manifest.')
        }
    }
    if ($data.SchemaVersion -in @(3, 4) -and
        @($data.AllowedImageIndexes).Count -eq 0) {
        throw 'Package manifest has no allowed factory image indexes.'
    }
    $data
}

function Add-FactoryBootEntry {
    param([object] $Paths, [string] $Letter)
    $sdi = @(
        (Join-Path $env:SystemRoot 'Boot\DVD\EFI\boot.sdi'),
        (Join-Path $env:SystemRoot 'Boot\DVD\PCAT\boot.sdi')) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sdi) { throw 'boot.sdi was not found.' }
    Copy-Item $sdi $Paths.BootSdi -Force

    # Private device-options object: never rewrite shared {ramdiskoptions}.
    $deviceOutput = & bcdedit.exe /create /d 'Factory Recovery Ramdisk' /device 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not create private ramdisk options.' }
    $device = [regex]::Match(($deviceOutput -join ' '), '\{[0-9a-fA-F-]{36}\}').Value
    if (-not $device) { throw 'Could not parse ramdisk-options identifier.' }
    Invoke-Native bcdedit.exe @('/set', $device, 'ramdisksdidevice',
        "partition=$Letter`:") | Out-Host
    Invoke-Native bcdedit.exe @('/set', $device, 'ramdisksdipath',
        '\FactoryRecovery\boot.sdi') | Out-Host

    $loaderOutput = & bcdedit.exe /create /d 'Factory Recovery' /application osloader 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not create Factory Recovery loader.' }
    $loader = [regex]::Match(($loaderOutput -join ' '), '\{[0-9a-fA-F-]{36}\}').Value
    if (-not $loader) { throw 'Could not parse Factory Recovery identifier.' }
    $ramdisk = "ramdisk=[$Letter`:]\FactoryRecovery\FactoryRE.wim,$device"
    Invoke-Native bcdedit.exe @('/set', $loader, 'device', $ramdisk) | Out-Host
    Invoke-Native bcdedit.exe @('/set', $loader, 'osdevice', $ramdisk) | Out-Host
    Invoke-Native bcdedit.exe @('/set', $loader, 'path',
        '\Windows\System32\winload.efi') | Out-Host
    Invoke-Native bcdedit.exe @('/set', $loader, 'systemroot', '\Windows') | Out-Host
    Invoke-Native bcdedit.exe @('/set', $loader, 'winpe', 'yes') | Out-Host
    Invoke-Native bcdedit.exe @('/set', $loader, 'detecthal', 'yes') | Out-Host
    Invoke-Native bcdedit.exe @('/displayorder', $loader, '/addlast') | Out-Host
    Invoke-Native bcdedit.exe @('/timeout',
        $BootMenuTimeoutSeconds.ToString()) | Out-Host
    [pscustomobject]@{ LoaderGuid = $loader; RamdiskGuid = $device }
}

function Get-FactoryBcdIdentifiers {
    $output = & bcdedit.exe /enum all /v 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate BCD objects.' }
    $sections = [regex]::Split(($output -join "`n"), '(?:\r?\n){2,}')
    foreach ($section in $sections) {
        $isFactoryLoader = $section -match '(?im)^\s*description\s+Factory Recovery\s*$' -and
            $section -match '(?i)\\FactoryRecovery\\FactoryRE\.wim'
        $isFactoryDevice = $section -match
            '(?im)^\s*description\s+Factory Recovery Ramdisk\s*$' -and
            $section -match '(?i)\\FactoryRecovery\\boot\.sdi'
        if ($isFactoryLoader -or $isFactoryDevice) {
            $identifier = [regex]::Match(
                $section, '\{[0-9a-fA-F-]{36}\}').Value
            if ($identifier) { $identifier }
        }
    }
}

# Read-only discovery.
$resolvedImage = if ($ImagePath) {
    (Resolve-Path -LiteralPath $ImagePath).ProviderPath
} else { $null }
$wimImages = @(if ($resolvedImage) { Get-WimImages $resolvedImage })
if ($Create -and -not $WhatIfPreference -and
    -not $ImageIndexSpecified -and $wimImages.Count -gt 1) {
    Write-Host ''
    Write-Host 'Images available in the captured WIM:' -ForegroundColor Cyan
    $wimImages | Format-Table Index, Name, Edition, Installation, Architecture `
        -AutoSize | Out-Host
    $indexAnswer = (Read-Host `
        'Lock recovery to one index, or press Enter to offer all during recovery').Trim()
    if ($indexAnswer) {
        $parsedIndex = 0
        if (-not [int]::TryParse($indexAnswer, [ref]$parsedIndex) -or
            $parsedIndex -notin $wimImages.Index) {
            throw "Image index must be one of: $($wimImages.Index -join ', ')."
        }
        $ImageIndex = $parsedIndex
        $ImageIndexSpecified = $true
    }
}
if ($resolvedImage -and $ImageIndexSpecified -and
    $ImageIndex -notin $wimImages.Index) {
    throw "WIM index $ImageIndex does not exist. Available indexes: $($wimImages.Index -join ', ')."
}
$AllowedImageIndexes = @(if (-not $resolvedImage) {
    @()
} elseif ($ImageIndexSpecified) {
    $ImageIndex
} else {
    $wimImages.Index
})
$wim = if ($AllowedImageIndexes.Count -eq 1) {
    $wimImages | Where-Object Index -eq $AllowedImageIndexes[0] |
        Select-Object -First 1
} else { $null }
$image = if ($resolvedImage) { Get-Item $resolvedImage } else { $null }
$osPartition = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
$osDisk = Get-Disk -Number $osPartition.DiskNumber
$diskId = if ($osDisk.PSObject.Properties.Name -contains 'Guid' -and $osDisk.Guid) {
    $osDisk.Guid.ToString().Trim('{}')
} else {
    $osDisk.UniqueId.ToString().Trim('{}')
}
$systemPart = Get-Partition -DiskNumber $osDisk.Number |
    Where-Object GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' |
    Select-Object -First 1
if (-not $systemPart) { throw 'EFI system partition was not found.' }
$registration = Get-WinreRegistration
$factoryVolumes = @(Get-Volume | Where-Object FileSystemLabel -eq $RecoveryLabel)
if ($factoryVolumes.Count -gt 1) { throw "Multiple $RecoveryLabel volumes exist." }
$factoryVolume = $factoryVolumes | Select-Object -First 1
$factoryPart = if ($factoryVolume) { Get-Partition -Volume $factoryVolume } else { $null }
$originalWinrePart = $null
$legacyWinreCandidate = $null

if ($osDisk.PartitionStyle -ne 'GPT') { throw 'Only GPT/UEFI is supported.' }
if (-not $osDisk.IsBoot -or -not $osDisk.IsSystem -or
    $osDisk.IsOffline -or $osDisk.IsReadOnly) {
    throw 'Windows disk preflight failed (boot/system/online/writable).'
}
if ($factoryPart -and $factoryPart.DiskNumber -ne $osDisk.Number) {
    throw "$RecoveryLabel is not on the Windows disk."
}
if ($RemoveOriginalWinre) {
    if (-not $factoryPart) {
        throw "No $RecoveryLabel partition exists."
    }
    if (-not $registration.Enabled -or
        $registration.DiskNumber -ne $factoryPart.DiskNumber -or
        $registration.PartitionNumber -ne $factoryPart.PartitionNumber) {
        throw ('Original WinRE removal requires WinRE to be enabled and ' +
            'registered on Factory Recovery.')
    }
    $legacyCandidates = @(Get-Partition -DiskNumber $osDisk.Number |
        Where-Object {
            $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -and
            $_.PartitionNumber -ne $factoryPart.PartitionNumber -and
            $_.PartitionNumber -ne $osPartition.PartitionNumber -and
            $_.PartitionNumber -ne $systemPart.PartitionNumber
        })
    if ($legacyCandidates.Count -ne 1) {
        throw ("Expected exactly one legacy recovery partition; found " +
            "$($legacyCandidates.Count). Removal is refused.")
    }
    $legacyWinreCandidate = $legacyCandidates[0]
    if (($factoryPart.Offset + $factoryPart.Size) -ne
        $legacyWinreCandidate.Offset) {
        throw ('The legacy recovery partition is not directly after Factory ' +
            'Recovery. Removal is refused.')
    }
}
if ($Create -and $registration.Enabled -and
    $null -ne $registration.DiskNumber -and
    $null -ne $registration.PartitionNumber) {
    $candidate = Get-Partition -DiskNumber $registration.DiskNumber `
        -PartitionNumber $registration.PartitionNumber `
        -ErrorAction SilentlyContinue
    $candidateIsVerified = $candidate -and
        $candidate.DiskNumber -eq $osDisk.Number -and
        $candidate.PartitionNumber -ne $osPartition.PartitionNumber -and
        $candidate.PartitionNumber -ne $systemPart.PartitionNumber -and
        $candidate.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -and
        ($osPartition.Offset + $osPartition.Size) -eq $candidate.Offset
    if ($candidateIsVerified) {
        $originalWinrePart = $candidate
        Write-Verbose ("Original WinRE partition $($candidate.PartitionNumber) " +
            'was verified and will be preserved.')
    } elseif ($candidate) {
        Write-Warning ('The registered WinRE partition exists but is not a ' +
            'verified adjacent partition; it will still be preserved.')
    }
}

$bitlocker = if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
    Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
}
$bitlockerOn = $bitlocker -and $bitlocker.ProtectionStatus -eq 'On'

Write-Host ''
Write-Host 'FACTORY RECOVERY PLAN - NO CHANGES YET' -ForegroundColor Cyan
Write-Host "  Windows : $env:SystemDrive, disk $($osDisk.Number), partition $($osPartition.PartitionNumber)"
Write-Host "  Disk ID : $diskId"
if ($image) {
    Write-Host "  Image   : $resolvedImage"
    if ($AllowedImageIndexes.Count -gt 1) {
        Write-Host "  Indexes : $($AllowedImageIndexes -join ', ') (user selects during recovery)"
        $wimImages | Format-Table Index, Name -AutoSize | Out-Host
    } else {
        Write-Host "  Index   : $($AllowedImageIndexes[0]) - $($wim.Name) (locked)"
    }
    Write-Host "  Size    : $([math]::Round($image.Length / 1GB, 2)) GB"
}
if ($RemoveOriginalWinre) {
    Write-Host ("  Remove  : legacy WinRE on disk " +
        "$($legacyWinreCandidate.DiskNumber), partition " +
        "$($legacyWinreCandidate.PartitionNumber)")
    Write-Host '  Verify  : Factory Recovery is the enabled WinRE target'
    Write-Host '  Reclaim : extend Factory Recovery into the released space'
} elseif ($RemoveFactory -and $factoryPart) {
    Write-Host "  Remove  : factory recovery on disk $($factoryPart.DiskNumber), partition $($factoryPart.PartitionNumber)"
    Write-Host '  Reclaim : delete only the verified factory partition and extend Windows'
    Write-Host '  WinRE   : preserve a cleaned standard WinRE image and re-enable it'
} elseif ($RemoveFactory) {
    Write-Warning "No $RecoveryLabel partition exists to remove."
} elseif ($factoryPart) {
    Write-Host "  Factory : disk $($factoryPart.DiskNumber), partition $($factoryPart.PartitionNumber)"
} else {
    Write-Host "  Factory : new $RecoverySizeGB GB partition"
}
if ($RemoveOriginalWinre) {
    Write-Host "  Old WinRE: remove partition $($legacyWinreCandidate.PartitionNumber)"
} elseif ($originalWinrePart) {
    Write-Host "  Old WinRE: preserve partition $($originalWinrePart.PartitionNumber)"
} else {
    Write-Host '  Old WinRE: preserve any existing recovery partition'
}
Write-Host '  Boot and partition operations use separate verified phases.'
Write-Host "  Boot menu entry is optional; if added, selection timeout is $BootMenuTimeoutSeconds seconds."
if ($bitlockerOn) { Write-Warning 'BitLocker is enabled.' }

if ($modeCount -eq 0) {
    Write-Host 'PLAN ONLY: no disk, file, BCD, or WinRE changes were made.' -ForegroundColor Green
    return
}
if ($WhatIfPreference) {
    Write-Host 'WHAT-IF COMPLETE: the selected operation was not entered.' -ForegroundColor Green
    return
}
if ($bitlockerOn) { throw 'Suspend BitLocker before continuing.' }
New-Item -ItemType Directory -Path $WorkingRoot -Force | Out-Null
New-Item -ItemType Directory -Path $MountPath -Force | Out-Null

if ($Prepare -or $Create) {
    if ($factoryPart) { throw 'Factory recovery already exists; use --update or --integrate.' }
    if ($image.Length + 2GB -gt $RecoveryBytes) {
        throw 'Image plus the 2 GB margin does not fit.'
    }
    $supported = Get-PartitionSupportedSize -DiskNumber $osDisk.Number `
        -PartitionNumber $osPartition.PartitionNumber
    if (($osPartition.Size - $supported.SizeMin) -lt
        ($RecoveryBytes + $PartitionAlignmentReserve + 1GB)) {
        throw 'Insufficient safe shrink space.'
    }
    if (-not $Create -and
        (Read-Host 'Type PREPARE to create/populate recovery') -cne 'PREPARE') {
        Write-Host 'Cancelled; no changes made.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess("disk $($osDisk.Number)", 'prepare recovery partition')) {
        return
    }
    $base = Get-BaseWinre $registration
    $newPart = $null
    try {
        Resize-Partition -DiskNumber $osDisk.Number `
            -PartitionNumber $osPartition.PartitionNumber `
            -Size ($osPartition.Size - $RecoveryBytes -
                $PartitionAlignmentReserve)
        $shrunkOs = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
        Assert-BootLayoutUnchanged -ExpectedOs $shrunkOs -ExpectedSystem $systemPart
        $newPart = New-Partition -DiskNumber $osDisk.Number `
            -Size $RecoveryBytes `
            -GptType '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        $newPart = Get-VerifiedPartitionAtOffset -DiskNumber $osDisk.Number `
            -Offset ([uint64]$newPart.Offset) -Size ([uint64]$newPart.Size) `
            -Purpose 'new Factory Recovery partition'
        if ($newPart.Offset -lt ($shrunkOs.Offset + $shrunkOs.Size) -or
            $newPart.Offset -eq $systemPart.Offset) {
            throw 'New Factory Recovery partition overlaps a protected partition.'
        }
        Assert-BootLayoutUnchanged -ExpectedOs $shrunkOs -ExpectedSystem $systemPart
        $newPart | Format-Volume -FileSystem NTFS `
            -NewFileSystemLabel $RecoveryLabel -Confirm:$false | Out-Null
        Add-PartitionAccessPath -InputObject $newPart `
            -AccessPath "$RecoveryLetter`:\"
        $custom = New-CustomWinre $base $osDisk.Number `
            $osPartition.PartitionNumber $newPart.PartitionNumber `
            $systemPart.PartitionNumber $diskId `
            $AllowedImageIndexes $wimImages
        $paths = Get-FactoryPaths $RecoveryLetter
        New-Item -ItemType Directory $paths.Root -Force | Out-Null
        New-Item -ItemType Directory $paths.RecoveryRoot -Force | Out-Null
        Copy-Item $custom.WinRE $paths.WinRE -Force
        Copy-Item $custom.FactoryRE $paths.FactoryRE -Force
        Copy-Item $resolvedImage $paths.Image -Force
        $hash = (Get-FileHash $resolvedImage -Algorithm SHA256).Hash
        if ((Get-FileHash $paths.Image -Algorithm SHA256).Hash -ne $hash) {
            throw 'Copied WIM failed SHA-256 verification.'
        }
        Write-Manifest $paths $newPart 'Prepared' $hash $null
        $newPart = Get-VerifiedPartitionAtOffset -DiskNumber $osDisk.Number `
            -Offset ([uint64]$newPart.Offset) -Size ([uint64]$newPart.Size) `
            -Purpose 'populated Factory Recovery partition'
        if ($newPart.GptType -ne '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') {
            throw 'Factory Recovery GPT type verification failed.'
        }
        Assert-BootLayoutUnchanged -ExpectedOs $shrunkOs -ExpectedSystem $systemPart
        Set-Partition -InputObject $newPart -NoDefaultDriveLetter $true
        Remove-TemporaryAccessPath -DiskNumber $newPart.DiskNumber `
            -PartitionNumber $newPart.PartitionNumber -Letter $RecoveryLetter
        Write-Host 'Prepared successfully. BCD and WinRE were not changed.' `
            -ForegroundColor Green
        if ($Prepare) {
            Write-Host 'Reboot and confirm normal Windows startup before --integrate.'
        } else {
            Write-Host 'Preparation verified; continuing to integration.'
        }
    } catch {
        if ($newPart) {
            Write-Warning "Partition $($newPart.PartitionNumber) remains for inspection but is not boot-integrated."
        }
        throw
    }
    if ($Prepare) { return }
    $factoryPart = Get-Partition -DiskNumber $osDisk.Number `
        -PartitionNumber $newPart.PartitionNumber
    $factoryVolume = Get-Volume -Partition $factoryPart
}

if (-not $factoryPart) { throw "No $RecoveryLabel partition exists." }
$addedLetter = -not $factoryVolume.DriveLetter
$activeLetter = if ($addedLetter) { $RecoveryLetter } else {
    $factoryVolume.DriveLetter.ToString()
}
if ($addedLetter) {
    Add-PartitionAccessPath -DiskNumber $factoryPart.DiskNumber `
        -PartitionNumber $factoryPart.PartitionNumber -AccessPath "$activeLetter`:\"
}
$paths = Get-FactoryPaths $activeLetter
$oldWinreAccessAdded = $false
$oldWinrePart = $null
$oldWinrePath = $null
$oldWinreLetter = $null
try {
    if ($Update -and -not (Test-Path $paths.Manifest)) {
        foreach ($legacyFile in @($paths.Image, $paths.FactoryRE, $paths.WinRE)) {
            if (-not (Test-Path $legacyFile -PathType Leaf)) {
                throw "Legacy package adoption failed; missing $legacyFile."
            }
        }
        Write-Warning 'Legacy/incomplete package detected. A successful update will adopt it as schema 4.'
        $manifest = [pscustomobject]@{
            Status = 'Prepared'
            LoaderGuid = $null
            RamdiskGuid = $null
        }
    } else {
        $manifest = Assert-Package $paths $factoryPart `
            -AllowLegacyPartitionNumberDrift:$Update
    }
    if ($Integrate) {
        $AllowedImageIndexes = @(if ($manifest.SchemaVersion -in @(3, 4)) {
            $manifest.AllowedImageIndexes | ForEach-Object { [int] $_ }
        } else {
            [int] $manifest.ImageIndex
        })
    }
    if ($RemoveOriginalWinre) {
        Write-Warning ('This permanently deletes the verified legacy WinRE ' +
            'partition and extends Factory Recovery into its released space.')
        if ((Read-Host 'Type REMOVE-ORIGINAL-WINRE to continue') -cne
            'REMOVE-ORIGINAL-WINRE') {
            Write-Host 'Original WinRE removal cancelled; no changes made.'
            return
        }
        if (-not $PSCmdlet.ShouldProcess(
                "disk $($legacyWinreCandidate.DiskNumber), partition " +
                "$($legacyWinreCandidate.PartitionNumber)",
                'remove verified legacy WinRE partition')) {
            return
        }

        $registrationCheck = Get-WinreRegistration
        if (-not $registrationCheck.Enabled -or
            $registrationCheck.DiskNumber -ne $factoryPart.DiskNumber -or
            $registrationCheck.PartitionNumber -ne $factoryPart.PartitionNumber) {
            throw 'WinRE is no longer verified on Factory Recovery; removal is refused.'
        }
        $verifiedLegacy = Get-VerifiedPartitionAtOffset `
            -DiskNumber $legacyWinreCandidate.DiskNumber `
            -Offset ([uint64]$legacyWinreCandidate.Offset) `
            -Size ([uint64]$legacyWinreCandidate.Size) `
            -Purpose 'legacy WinRE partition'
        if ($verifiedLegacy.GptType -ne
                '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -or
            ($factoryPart.Offset + $factoryPart.Size) -ne
                $verifiedLegacy.Offset) {
            throw 'Legacy WinRE identity changed; removal is refused.'
        }

        $legacyLetter = @('Q', 'T', 'U', 'V', 'P') |
            Where-Object {
                $_ -ne $activeLetter -and -not (Test-Path "$_`:\")
            } | Select-Object -First 1
        if (-not $legacyLetter) {
            throw 'No temporary drive letter is available for legacy WinRE verification.'
        }
        $legacyVolume = Get-Volume -Partition $verifiedLegacy
        $legacyAccessAdded = -not $legacyVolume.DriveLetter
        $legacyActiveLetter = if ($legacyAccessAdded) {
            $legacyLetter
        } else {
            $legacyVolume.DriveLetter.ToString()
        }
        $checkpoint = Join-Path $WorkingRoot `
            ('RemoveOriginalWinRE-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $checkpoint -Force | Out-Null
        try {
            if ($legacyAccessAdded) {
                Add-PartitionAccessPath -InputObject $verifiedLegacy `
                    -AccessPath "$legacyActiveLetter`:\"
            }
            $legacyImage = "$legacyActiveLetter`:\Recovery\WindowsRE\Winre.wim"
            if (-not (Test-Path -LiteralPath $legacyImage -PathType Leaf)) {
                throw 'Legacy Winre.wim was not found; removal is refused.'
            }
            Copy-Item -LiteralPath $legacyImage `
                -Destination (Join-Path $checkpoint 'PreviousWinre.wim') -Force
            (Get-FileHash -LiteralPath $legacyImage -Algorithm SHA256).Hash |
                Set-Content (Join-Path $checkpoint 'PreviousWinre.sha256') `
                    -Encoding ASCII
            [ordered]@{
                DiskId = $diskId
                DiskNumber = $verifiedLegacy.DiskNumber
                PartitionNumber = $verifiedLegacy.PartitionNumber
                Offset = [uint64]$verifiedLegacy.Offset
                Size = [uint64]$verifiedLegacy.Size
                GptType = $verifiedLegacy.GptType
                RemovedUtc = [DateTime]::UtcNow.ToString('o')
            } | ConvertTo-Json |
                Set-Content (Join-Path $checkpoint 'Partition.json') -Encoding UTF8
            Copy-Item -LiteralPath $paths.Manifest `
                -Destination (Join-Path $checkpoint 'Manifest-before.json') -Force
        }
        finally {
            if ($legacyAccessAdded) {
                Remove-TemporaryAccessPath `
                    -DiskNumber $verifiedLegacy.DiskNumber `
                    -PartitionNumber $verifiedLegacy.PartitionNumber `
                    -Letter $legacyActiveLetter
            }
        }

        $verifiedLegacy = Get-VerifiedPartitionAtOffset `
            -DiskNumber $legacyWinreCandidate.DiskNumber `
            -Offset ([uint64]$legacyWinreCandidate.Offset) `
            -Size ([uint64]$legacyWinreCandidate.Size) `
            -Purpose 'legacy WinRE partition before deletion'
        Remove-Partition -InputObject $verifiedLegacy -Confirm:$false
        $remainingAtOffset = @(Get-Partition `
            -DiskNumber $legacyWinreCandidate.DiskNumber |
            Where-Object {
                [uint64]$_.Offset -eq [uint64]$legacyWinreCandidate.Offset
            })
        if ($remainingAtOffset.Count) {
            throw 'Legacy WinRE partition still exists after removal.'
        }
        $factoryBeforeExpand = Get-VerifiedPartitionAtOffset `
            -DiskNumber $factoryPart.DiskNumber `
            -Offset ([uint64]$factoryPart.Offset) `
            -Size ([uint64]$factoryPart.Size) `
            -Purpose 'Factory Recovery partition before expansion'
        $factorySupported = Get-PartitionSupportedSize `
            -DiskNumber $factoryBeforeExpand.DiskNumber `
            -PartitionNumber $factoryBeforeExpand.PartitionNumber
        if ($factorySupported.SizeMax -le $factoryBeforeExpand.Size) {
            throw ('Legacy WinRE was removed, but Factory Recovery cannot be ' +
                "expanded. Backup checkpoint: $checkpoint")
        }
        Resize-Partition -InputObject $factoryBeforeExpand `
            -Size $factorySupported.SizeMax
        $expandedFactory = Get-VerifiedPartitionAtOffset `
            -DiskNumber $factoryBeforeExpand.DiskNumber `
            -Offset ([uint64]$factoryBeforeExpand.Offset) `
            -Size ([uint64]$factorySupported.SizeMax) `
            -Purpose 'expanded Factory Recovery partition'
        if (($expandedFactory.Offset + $expandedFactory.Size) -ne
            ($legacyWinreCandidate.Offset + $legacyWinreCandidate.Size)) {
            throw ('Factory Recovery expansion did not consume exactly the ' +
                "released legacy extent. Backup checkpoint: $checkpoint")
        }
        $AllowedImageIndexes = @(if ($manifest.SchemaVersion -in @(3, 4)) {
            $manifest.AllowedImageIndexes | ForEach-Object { [int] $_ }
        } else {
            [int]$manifest.ImageIndex
        })
        $existingBcd = if ($manifest.LoaderGuid -and $manifest.RamdiskGuid) {
            [pscustomobject]@{
                LoaderGuid = $manifest.LoaderGuid
                RamdiskGuid = $manifest.RamdiskGuid
            }
        } else { $null }
        Write-Manifest $paths $expandedFactory $manifest.Status `
            $manifest.ImageSha256 $existingBcd
        $manifest = Assert-Package $paths $expandedFactory
        Assert-BootLayoutUnchanged -ExpectedOs $osPartition `
            -ExpectedSystem $systemPart
        $registrationAfterRemoval = Get-WinreRegistration
        if (-not $registrationAfterRemoval.Enabled -or
            $registrationAfterRemoval.DiskNumber -ne $factoryPart.DiskNumber -or
            $registrationAfterRemoval.PartitionNumber -ne
                $factoryPart.PartitionNumber) {
            throw ('Legacy partition was removed, but Factory Recovery WinRE ' +
                'registration no longer verifies. Do not reboot until investigated.')
        }
        Write-Host ('Original WinRE was removed and Factory Recovery was ' +
            'extended into the released space.') -ForegroundColor Green
        Write-Host "Backup checkpoint: $checkpoint"
        return
    }
    if ($RemoveFactory) {
        $factoryIsActiveWinre = $registration.DiskNumber -eq $factoryPart.DiskNumber -and
            $registration.PartitionNumber -eq $factoryPart.PartitionNumber
        $mustInstallStandardWinre = $factoryIsActiveWinre -or
            -not $registration.Enabled
        $factoryIsAdjacent = ($osPartition.Offset + $osPartition.Size) -eq
            $factoryPart.Offset
        Write-Warning 'This permanently deletes the verified factory WIM, recovery WIMs, manifest, and factory partition.'
        if (-not $factoryIsAdjacent) {
            Write-Warning 'The factory partition is not directly after Windows; its space cannot be merged automatically.'
        }
        if ((Read-Host 'Type REMOVE-FACTORY to permanently remove factory recovery') -cne
            'REMOVE-FACTORY') {
            Write-Host 'Factory recovery removal cancelled; no changes made.'
            return
        }
        if (-not $PSCmdlet.ShouldProcess(
                "disk $($factoryPart.DiskNumber), partition $($factoryPart.PartitionNumber)",
                'remove factory recovery and reclaim adjacent space')) {
            return
        }

        $checkpoint = Join-Path $WorkingRoot `
            ('Remove-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $checkpoint -Force | Out-Null
        $bcdBackup = Join-Path $checkpoint 'BCD'
        Invoke-Native bcdedit.exe @('/export', $bcdBackup)
        $factoryBcdIdentifiers = @(
            @($manifest.LoaderGuid, $manifest.RamdiskGuid)
            @(Get-FactoryBcdIdentifiers)
        ) | Where-Object { $_ -match '^\{[0-9a-fA-F-]{36}\}$' } |
            Select-Object -Unique
        $cleanWinre = if ($mustInstallStandardWinre) {
            New-CleanWinre -SourceWinre $paths.WinRE
        } else { $null }
        $partitionRemoved = $false
        try {
            if ($factoryIsActiveWinre -and $registration.Enabled) {
                Invoke-Native reagentc.exe @('/disable')
            }
            if ($mustInstallStandardWinre) {
                $localRecovery = Join-Path $env:SystemRoot 'System32\Recovery'
                New-Item -ItemType Directory -Path $localRecovery -Force | Out-Null
                Copy-Item -LiteralPath $cleanWinre `
                    -Destination (Join-Path $localRecovery 'Winre.wim') -Force
            }

            foreach ($guid in $factoryBcdIdentifiers) {
                & bcdedit.exe /enum $guid /v *> $null
                if ($LASTEXITCODE -eq 0) {
                    Invoke-Native bcdedit.exe @('/delete', $guid)
                }
            }
            if (@(Get-FactoryBcdIdentifiers).Count) {
                throw 'One or more Factory Recovery BCD objects remain.'
            }

            if ($addedLetter) {
                Remove-TemporaryAccessPath `
                    -DiskNumber $factoryPart.DiskNumber `
                    -PartitionNumber $factoryPart.PartitionNumber `
                    -Letter $activeLetter
                $addedLetter = $false
            }
            Remove-Partition -DiskNumber $factoryPart.DiskNumber `
                -PartitionNumber $factoryPart.PartitionNumber -Confirm:$false
            $partitionRemoved = $true

            if ($mustInstallStandardWinre) {
                $localRecovery = Join-Path $env:SystemRoot 'System32\Recovery'
                Invoke-Native reagentc.exe @('/setreimage', '/path', $localRecovery)
                Invoke-Native reagentc.exe @('/enable')
                $winreAfter = Get-WinreRegistration
                if (-not $winreAfter.Enabled) {
                    throw 'Standard WinRE could not be verified after factory removal.'
                }
            }

            if ($factoryIsAdjacent) {
                $currentOsPartition = Get-Partition -DriveLetter `
                    $env:SystemDrive.TrimEnd(':')
                $supported = Get-PartitionSupportedSize `
                    -DiskNumber $currentOsPartition.DiskNumber `
                    -PartitionNumber $currentOsPartition.PartitionNumber
                Resize-Partition -DiskNumber $currentOsPartition.DiskNumber `
                    -PartitionNumber $currentOsPartition.PartitionNumber `
                    -Size $supported.SizeMax
            }

            if (Get-Volume | Where-Object FileSystemLabel -eq $RecoveryLabel) {
                throw "A volume labeled $RecoveryLabel still exists after removal."
            }
            Write-Host 'Factory recovery was removed successfully.' -ForegroundColor Green
            Write-Host "BCD checkpoint: $bcdBackup"
        }
        catch {
            if (-not $partitionRemoved) {
                & bcdedit.exe /import $bcdBackup | Out-Null
                if ($factoryIsActiveWinre -and $registration.Enabled) {
                    & reagentc.exe /setreimage /path $paths.RecoveryRoot | Out-Null
                    & reagentc.exe /enable | Out-Null
                }
                Write-Warning 'Removal stopped before partition deletion; BCD was restored.'
            } else {
                Write-Warning "The factory partition was removed. Do not import the old BCD checkpoint automatically: $bcdBackup"
            }
            throw
        }
        return
    }
    if ($Update) {
        $minimum = $image.Length + 2GB
        if ($factoryPart.Size -lt $minimum) {
            $needed = [math]::Ceiling($minimum / 1GB)
            if ((Read-Host "Image cannot fit. Type RESIZE to request $needed GB") -ceq 'RESIZE') {
                throw 'Online delete/recreate resizing is intentionally disabled. Use tested offline media.'
            }
            Write-Host 'Cancelled; no changes made.'; return
        }
        if ((Read-Host 'Type UPDATE to replace the recovery files in place') -cne
            'UPDATE') {
            Write-Host 'Cancelled; no changes made.'; return
        }
        $base = if ((Test-Path -LiteralPath $paths.WinRE -PathType Leaf) -and
            $null -eq $registration.DiskNumber -and
            -not (Test-Path (Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'))) {
            Write-Warning 'Using the existing factory WinRE as the legacy adoption base.'
            $paths.WinRE
        } else {
            Get-BaseWinre $registration
        }
        $custom = New-CustomWinre $base $osDisk.Number `
            $osPartition.PartitionNumber $factoryPart.PartitionNumber `
            $systemPart.PartitionNumber $diskId `
            $AllowedImageIndexes $wimImages
        $hash = (Get-FileHash $resolvedImage -Algorithm SHA256).Hash
        $existingBcd = if ($manifest.LoaderGuid -and $manifest.RamdiskGuid) {
            [pscustomobject]@{
                LoaderGuid = $manifest.LoaderGuid
                RamdiskGuid = $manifest.RamdiskGuid
            }
        } else { $null }
        $finalStatus = if ($existingBcd) { 'Integrated' } else { 'Prepared' }
        $previousHash = if ($manifest.PSObject.Properties.Name -contains
                'ImageSha256' -and $manifest.ImageSha256) {
            $manifest.ImageSha256
        } else {
            (Get-FileHash -LiteralPath $paths.Image -Algorithm SHA256).Hash
        }
        Write-Manifest $paths $factoryPart 'UpdateInProgress' `
            $previousHash $existingBcd
        Write-Warning ('Replacing files in place. Do not restart or power off ' +
            'until the update reports success.')
        Copy-Item -LiteralPath $resolvedImage -Destination $paths.Image -Force
        if ((Get-FileHash -LiteralPath $paths.Image -Algorithm SHA256).Hash -ne
            $hash) {
            throw ('Factory WIM hash mismatch after in-place replacement. ' +
                'The manifest is marked UpdateInProgress; rerun --update.')
        }
        foreach ($item in @(
                @($custom.FactoryRE, $paths.FactoryRE),
                @($custom.WinRE, $paths.WinRE))) {
            $sourceHash = (Get-FileHash -LiteralPath $item[0] `
                -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $item[0] -Destination $item[1] -Force
            if ((Get-FileHash -LiteralPath $item[1] -Algorithm SHA256).Hash -ne
                $sourceHash) {
                throw ("Recovery image hash mismatch after replacing $($item[1]). " +
                    'The manifest is marked UpdateInProgress; rerun --update.')
            }
        }
        Write-Manifest $paths $factoryPart $finalStatus $hash $existingBcd
        Write-Host 'Recovery files updated; BCD and WinRE were not changed.' -ForegroundColor Green
        return
    }

    $current = & bcdedit.exe /enum '{current}' /v 2>&1
    if ($LASTEXITCODE -ne 0 -or ($current -join ' ') -notmatch 'winload\.efi') {
        throw 'Normal Windows loader failed BCD preflight.'
    }
    $bootBefore = & bcdedit.exe /enum '{bootmgr}' /v 2>&1
    $default = [regex]::Match(($bootBefore -join "`n"),
        '(?im)^\s*default\s+(\{[0-9a-fA-F-]{36}\})').Groups[1].Value
    if ($LASTEXITCODE -ne 0 -or -not $default) {
        throw 'Boot Manager/default-loader preflight failed.'
    }
    $addBootEntry = Read-YesNo `
        'Add Factory Recovery to Windows Boot Manager?'
    if (-not $Create -and
        (Read-Host 'Type INTEGRATE to register WinRE and the Factory Recovery tile') -cne 'INTEGRATE') {
        Write-Host 'Cancelled; no changes made.'; return
    }
    if (-not $PSCmdlet.ShouldProcess('Windows boot configuration',
        'integrate prepared recovery')) { return }

    $checkpoint = Join-Path $WorkingRoot ('Checkpoint-' + (Get-Date -Format yyyyMMdd-HHmmss))
    New-Item -ItemType Directory $checkpoint -Force | Out-Null
    $bcdBackup = Join-Path $checkpoint 'BCD'
    Invoke-Native bcdedit.exe @('/export', $bcdBackup)
    $registration.Raw | Set-Content (Join-Path $checkpoint 'ReAgent-before.txt')

    if ($null -ne $registration.DiskNumber -and
        ($registration.DiskNumber -ne $factoryPart.DiskNumber -or
         $registration.PartitionNumber -ne $factoryPart.PartitionNumber)) {
        $oldWinrePart = Get-Partition -DiskNumber $registration.DiskNumber `
            -PartitionNumber $registration.PartitionNumber
        $oldWinreVolume = Get-Volume -Partition $oldWinrePart
        $oldWinreLetter = if ($oldWinreVolume.DriveLetter) {
            $oldWinreVolume.DriveLetter.ToString()
        } else { 'Q' }
        $oldWinreAccessAdded = -not $oldWinreVolume.DriveLetter
        if ($oldWinreAccessAdded) {
            Add-PartitionAccessPath -DiskNumber $oldWinrePart.DiskNumber `
                -PartitionNumber $oldWinrePart.PartitionNumber `
                -AccessPath "$oldWinreLetter`:\"
        }
        $oldWinrePath = "$oldWinreLetter`:\Recovery\WindowsRE"
        if (-not (Test-Path (Join-Path $oldWinrePath 'Winre.wim'))) {
            throw 'The previous WinRE image cannot be staged for rollback.'
        }
    }
    try {
        if ($registration.Enabled) {
            Invoke-Native reagentc.exe @('/disable')
        } else {
            Write-Verbose 'WinRE is already disabled; skipping REAgentC /disable.'
        }
        Invoke-Native reagentc.exe @('/setreimage', '/path', $paths.RecoveryRoot)
@'
<?xml version="1.0" encoding="utf-8"?>
<BootShell><WinRETool locale="en-us">
<Name>Factory Recovery</Name>
<Description>Restore the factory system image</Description>
</WinRETool></BootShell>
'@ | Set-Content (Join-Path $checkpoint 'BootShell.xml') -Encoding UTF8
        Invoke-Native reagentc.exe @('/setbootshelllink', '/configfile',
            (Join-Path $checkpoint 'BootShell.xml'))
        Invoke-Native reagentc.exe @('/enable')
        $check = Get-WinreRegistration
        if (-not $check.Enabled -or $check.DiskNumber -ne $osDisk.Number -or
            $check.PartitionNumber -ne $factoryPart.PartitionNumber) {
            throw 'WinRE post-change verification failed.'
        }
        $bcd = $null
        if ($addBootEntry) {
            $bcd = Add-FactoryBootEntry $paths $activeLetter
            $entry = & bcdedit.exe /enum $bcd.LoaderGuid /v 2>&1
            if ($LASTEXITCODE -ne 0 -or
                ($entry -join ' ') -notmatch 'FactoryRE\.wim') {
                throw 'Factory loader verification failed.'
            }
        } else {
            Write-Host 'Boot Manager Factory Recovery entry was skipped by user choice.'
        }
        $bootAfter = & bcdedit.exe /enum '{bootmgr}' /v 2>&1
        if ($LASTEXITCODE -ne 0 -or ($bootAfter -join ' ') -notmatch
            [regex]::Escape($default)) {
            throw 'Normal default loader changed or disappeared.'
        }
        Write-Manifest $paths $factoryPart 'Integrated' $manifest.ImageSha256 $bcd
        Write-Host "Integrated successfully. Checkpoint: $bcdBackup" -ForegroundColor Green
        Write-Host 'Reboot and test normal Windows before testing recovery.'
    } catch {
        Write-Warning "Integration failed; restoring BCD from $bcdBackup"
        & reagentc.exe /disable | Out-Null
        if ($oldWinrePath) {
            & reagentc.exe /setreimage /path $oldWinrePath | Out-Null
            if ($registration.Enabled) { & reagentc.exe /enable | Out-Null }
        }
        & bcdedit.exe /import $bcdBackup | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Automatic BCD rollback failed. Keep the checkpoint and do not reboot.'
        }
        throw
    }
} finally {
    if ($oldWinreAccessAdded) {
        Remove-TemporaryAccessPath -DiskNumber $oldWinrePart.DiskNumber `
            -PartitionNumber $oldWinrePart.PartitionNumber `
            -Letter $oldWinreLetter
    }
    if ($addedLetter) {
        Remove-TemporaryAccessPath -DiskNumber $factoryPart.DiskNumber `
            -PartitionNumber $factoryPart.PartitionNumber `
            -Letter $activeLetter
    }
}
