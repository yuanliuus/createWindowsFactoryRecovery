#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ExpectedDiskId,

    [Parameter(Mandatory)]
    [Alias('ExpectedImageIndex')]
    [int[]] $ExpectedImageIndexes,

    [int] $ExpectedFactoryPartition = 4,

    [int] $RemovedPartition = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$os = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
$disk = Get-Disk -Number $os.DiskNumber
$diskId = if ($disk.Guid) {
    $disk.Guid.ToString().Trim('{}')
} else {
    $disk.UniqueId.ToString().Trim('{}')
}
if ($diskId -ne $ExpectedDiskId -or $disk.IsOffline -or $disk.IsReadOnly) {
    throw 'Boot disk identity or online/writable state failed.'
}

$parts = @(Get-Partition -DiskNumber $disk.Number)
$volumes = @(Get-Volume |
    Where-Object FileSystemLabel -eq 'FACTORY_RECOVERY')
if ($volumes.Count -ne 1) {
    throw "Expected one FACTORY_RECOVERY volume; found $($volumes.Count)."
}
$factoryVolume = $volumes[0]
$factoryPart = Get-Partition -Volume $factoryVolume
if ($factoryPart.PartitionNumber -ne $ExpectedFactoryPartition -or
    $factoryPart.DriveLetter) {
    throw 'Factory partition identity or hidden state failed.'
}
if ($RemovedPartition -and $parts.PartitionNumber -contains $RemovedPartition) {
    throw "Removed partition $RemovedPartition still exists."
}

$manifestPath = Join-Path `
    (Join-Path $factoryVolume.Path 'FactoryRecovery') 'Manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$actualImageIndexes = if ($manifest.SchemaVersion -in @(3, 4)) {
    @($manifest.AllowedImageIndexes | ForEach-Object { [int] $_ })
} else {
    @([int] $manifest.ImageIndex)
}
$expectedIndexText = (@($ExpectedImageIndexes) | Sort-Object) -join ','
$actualIndexText = ($actualImageIndexes | Sort-Object) -join ','
if ($manifest.Status -ne 'Integrated' -or
    $actualIndexText -ne $expectedIndexText) {
    throw 'Integrated manifest status or allowed image indexes failed.'
}

$winre = (& reagentc.exe /info 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $winre -notmatch 'Enabled' -or
    $winre -notmatch "harddisk$($disk.Number)\\partition$ExpectedFactoryPartition") {
    throw 'WinRE registration does not point to the factory partition.'
}

$boot = (& bcdedit.exe /enum '{bootmgr}' /v 2>&1) -join "`n"
$current = (& bcdedit.exe /enum '{current}' /v 2>&1) -join "`n"
$all = (& bcdedit.exe /enum all /v 2>&1) -join "`n"
$currentId = [regex]::Match(
    $current, '(?im)^\s*identifier\s+(\{[0-9a-f-]{36}\})').Groups[1].Value
$defaultId = [regex]::Match(
    $boot, '(?im)^\s*default\s+(\{[0-9a-f-]{36}\})').Groups[1].Value
if (-not $currentId -or $currentId -ne $defaultId -or
    $boot -notmatch '(?im)^\s*timeout\s+3\s*$') {
    throw 'Windows default loader or Boot Manager timeout failed.'
}

foreach ($expected in @(
        $manifest.LoaderGuid,
        $manifest.RamdiskGuid,
        'FactoryRecovery\FactoryRE.wim',
        'FactoryRecovery\boot.sdi')) {
    if (-not $expected -or $all -notmatch [regex]::Escape($expected)) {
        throw "Factory BCD verification failed for '$expected'."
    }
}

[pscustomobject]@{
    DiskOnline = 'PASS'
    Partitions = $parts.PartitionNumber -join ','
    RemovedPartitionAbsent = if ($RemovedPartition) { 'PASS' } else { 'N/A' }
    FactoryPartition = "Disk $($disk.Number), partition $ExpectedFactoryPartition, hidden"
    FactorySizeGB = [math]::Round($factoryPart.Size / 1GB, 2)
    ManifestStatus = $manifest.Status
    ImageIndexes = $actualIndexText
    ImageSelection = if ($manifest.SchemaVersion -in @(3, 4)) {
        $manifest.ImageSelection
    } else { 'Legacy locked' }
    WinRE = "Enabled on partition $ExpectedFactoryPartition"
    WindowsDefault = $currentId
    FactoryLoader = $manifest.LoaderGuid
    PrivateRamdisk = $manifest.RamdiskGuid
    BootTimeoutSeconds = 3
    Result = 'POST-INTEGRATION VERIFICATION PASSED'
} | Format-List
