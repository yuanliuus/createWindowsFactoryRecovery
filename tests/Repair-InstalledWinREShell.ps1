#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ExpectedDiskId,

    [int] $ExpectedPartition = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$factoryVolumes = @(Get-Volume |
    Where-Object FileSystemLabel -eq 'FACTORY_RECOVERY')
if ($factoryVolumes.Count -ne 1) {
    throw "Expected one FACTORY_RECOVERY volume; found $($factoryVolumes.Count)."
}
$factoryVolume = $factoryVolumes[0]
$factoryPart = Get-Partition -Volume $factoryVolume
$disk = Get-Disk -Number $factoryPart.DiskNumber
$diskId = if ($disk.Guid) {
    $disk.Guid.ToString().Trim('{}')
} else {
    $disk.UniqueId.ToString().Trim('{}')
}
if ($diskId -ne $ExpectedDiskId -or
    $factoryPart.PartitionNumber -ne $ExpectedPartition -or
    $disk.IsOffline -or $disk.IsReadOnly) {
    throw 'Factory disk/partition identity or state check failed.'
}

$registrationBefore = (& reagentc.exe /info 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or
    $registrationBefore -notmatch '(?im)Windows RE status:\s*Enabled' -or
    $registrationBefore -notmatch
        "harddisk$($disk.Number)\\partition$ExpectedPartition") {
    throw 'WinRE is not enabled on the expected factory partition.'
}

$usedLetters = @(Get-Volume | Where-Object DriveLetter |
    ForEach-Object { $_.DriveLetter.ToString() })
$letter = @('R', 'Q', 'T', 'U', 'V') |
    Where-Object { $_ -notin $usedLetters } |
    Select-Object -First 1
if (-not $letter) { throw 'No temporary drive letter is available.' }
$accessAdded = -not $factoryVolume.DriveLetter
if (-not $accessAdded) { $letter = $factoryVolume.DriveLetter.ToString() }

$working = Join-Path $env:ProgramData `
    ('FactoryRecoveryBuild\WinREShellRepair-' +
        (Get-Date -Format 'yyyyMMdd-HHmmss'))
$mount = Join-Path $working 'Mount'
New-Item -ItemType Directory -Path $mount -Force | Out-Null
$bcdBackup = Join-Path $working 'BCD'
$wimBackup = Join-Path $working 'Winre.before.wim'
$mounted = $false
$wimCommitted = $false

try {
    if ($accessAdded) {
        Add-PartitionAccessPath -DiskNumber $factoryPart.DiskNumber `
            -PartitionNumber $factoryPart.PartitionNumber `
            -AccessPath "$letter`:\"
    }
    $recoveryRoot = "$letter`:\Recovery\WindowsRE"
    $wim = Join-Path $recoveryRoot 'Winre.wim'
    if (-not (Test-Path -LiteralPath $wim -PathType Leaf)) {
        throw "Installed WinRE image was not found at $wim."
    }

    & bcdedit.exe /export $bcdBackup | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'BCD checkpoint failed.' }
    Copy-Item -LiteralPath $wim -Destination $wimBackup -Force

    & dism.exe /Mount-Image "/ImageFile:$wim" /Index:1 `
        "/MountDir:$mount" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Could not mount WinRE for repair.' }
    $mounted = $true

    $recenv = Join-Path $mount 'Sources\Recovery\RecEnv.exe'
    if (-not (Test-Path -LiteralPath $recenv -PathType Leaf)) {
        throw 'RecEnv.exe is missing from the installed WinRE image.'
    }
@'
[LaunchApps]
%SYSTEMROOT%\System32\wpeinit.exe
%SYSTEMDRIVE%\Sources\Recovery\RecEnv.exe
'@ | Set-Content -LiteralPath `
        (Join-Path $mount 'Windows\System32\winpeshl.ini') `
        -Encoding ASCII

    & dism.exe /Unmount-Image "/MountDir:$mount" /Commit | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the WinRE shell repair.' }
    $mounted = $false
    $wimCommitted = $true

    $validation = (& dism.exe /English /Get-WimInfo `
        "/WimFile:$wim" /Index:1 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $validation -notmatch '(?im)^Index\s*:\s*1\s*$') {
        throw 'The repaired WinRE image failed DISM validation.'
    }

    $bootShell = Join-Path $working 'BootShell.xml'
@'
<?xml version="1.0" encoding="utf-8"?>
<BootShell><WinRETool locale="en-us">
<Name>Factory Recovery</Name>
<Description>Restore the factory system image</Description>
</WinRETool></BootShell>
'@ | Set-Content -LiteralPath $bootShell -Encoding UTF8

    & reagentc.exe /disable | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'REAgentC /disable failed.' }
    & reagentc.exe /setreimage /path $recoveryRoot | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'REAgentC /setreimage failed.' }
    & reagentc.exe /setbootshelllink /configfile $bootShell | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'REAgentC /setbootshelllink failed.' }
    & reagentc.exe /enable | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'REAgentC /enable failed.' }

    $registrationAfter = (& reagentc.exe /info 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or
        $registrationAfter -notmatch '(?im)Windows RE status:\s*Enabled' -or
        $registrationAfter -notmatch
            "harddisk$($disk.Number)\\partition$ExpectedPartition") {
        throw 'WinRE registration verification failed after shell repair.'
    }

    [pscustomobject]@{
        WinreShell = 'wpeinit.exe -> RecEnv.exe'
        WinreRegistration = "Enabled on disk $($disk.Number), partition $ExpectedPartition"
        BcdCheckpoint = $bcdBackup
        WimCheckpoint = $wimBackup
        Result = 'INSTALLED WINRE SHELL REPAIR PASSED'
    } | Format-List
}
catch {
    if ($mounted) {
        & dism.exe /Unmount-Image "/MountDir:$mount" /Discard | Out-Null
        $mounted = $false
    }
    if ($wimCommitted -and (Test-Path -LiteralPath $wimBackup)) {
        & reagentc.exe /disable | Out-Null
        Copy-Item -LiteralPath $wimBackup -Destination $wim -Force
        & reagentc.exe /setreimage /path $recoveryRoot | Out-Null
        & reagentc.exe /enable | Out-Null
    }
    if (Test-Path -LiteralPath $bcdBackup) {
        & bcdedit.exe /import $bcdBackup | Out-Null
    }
    throw
}
finally {
    if ($accessAdded) {
        Remove-PartitionAccessPath -DiskNumber $factoryPart.DiskNumber `
            -PartitionNumber $factoryPart.PartitionNumber `
            -AccessPath "$letter`:\" -ErrorAction SilentlyContinue
        $remaining = Get-Volume -Partition $factoryPart `
            -ErrorAction SilentlyContinue
        if ($remaining -and $remaining.DriveLetter -and
            $remaining.DriveLetter.ToString() -eq $letter) {
            $cleanup = Join-Path $working 'RemoveAccess.txt'
@"
select disk $($factoryPart.DiskNumber)
select partition $($factoryPart.PartitionNumber)
remove letter=$letter
exit
"@ | Set-Content -LiteralPath $cleanup -Encoding ASCII
            & diskpart.exe /s $cleanup | Out-Null
        }
    }
}
