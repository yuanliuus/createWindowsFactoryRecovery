#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceWim,

    [Parameter(Mandatory)]
    [string] $ExpectedDiskId,

    [Parameter(Mandatory)]
    [int[]] $ExpectedImageIndexes,

    [int] $ExpectedFactoryPartition = 4,

    [int] $RemovedPartition = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourceWim -PathType Leaf)) {
    throw "Source WIM not found: $SourceWim"
}

$factoryVolumes = @(Get-Volume |
    Where-Object FileSystemLabel -eq 'FACTORY_RECOVERY')
if ($factoryVolumes.Count -ne 1) {
    throw "Expected one FACTORY_RECOVERY volume; found $($factoryVolumes.Count)."
}
$installedWim = Join-Path `
    (Join-Path $factoryVolumes[0].Path 'FactoryRecovery') 'FactoryImage.wim'
$sourceHash = (Get-FileHash -LiteralPath $SourceWim -Algorithm SHA256).Hash
$installedHash = (Get-FileHash -LiteralPath $installedWim -Algorithm SHA256).Hash
if ($sourceHash -ne $installedHash) {
    throw 'Installed factory WIM hash differs from the external source.'
}

$wimInfo = (& dism.exe /English /Get-WimInfo `
    "/WimFile:$installedWim" 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'DISM could not inspect the installed WIM.' }
$installedIndexes = @([regex]::Matches(
    $wimInfo, '(?im)^Index\s*:\s*(\d+)\s*$') |
    ForEach-Object { [int] $_.Groups[1].Value })
$installedIndexText = ($installedIndexes | Sort-Object) -join ','
$expectedIndexText = ($ExpectedImageIndexes | Sort-Object) -join ','
if ($installedIndexText -ne $expectedIndexText) {
    throw "Installed WIM indexes are '$($installedIndexes -join ',')'; expected '$($ExpectedImageIndexes -join ',')'."
}

$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Verify-PostIntegrationState.ps1') `
    -ExpectedDiskId $ExpectedDiskId `
    -ExpectedImageIndexes $ExpectedImageIndexes `
    -ExpectedFactoryPartition $ExpectedFactoryPartition `
    -RemovedPartition $RemovedPartition
& (Join-Path $PSScriptRoot 'Verify-RecoveryVerifier.ps1') `
    -ExpectedImageIndexes $ExpectedImageIndexes
$recoveryReport = Join-Path $root 'recovery-verifier-test.txt'
Get-Content -LiteralPath $recoveryReport

& fsutil.exe dirty query $env:SystemDrive | Out-Host
if ($LASTEXITCODE -ne 0) { throw "$env:SystemDrive is dirty." }
$systemVolume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')
if ($systemVolume.HealthStatus -ne 'Healthy') {
    throw "$env:SystemDrive health is $($systemVolume.HealthStatus)."
}

[pscustomobject]@{
    SourceWim = $SourceWim
    FactoryWimSha256 = $sourceHash
    InstalledImageIndexes = $installedIndexes -join ','
    SystemVolumeHealth = $systemVolume.HealthStatus
    Result = 'INSTALLED FACTORY UPDATE VERIFICATION PASSED'
} | Format-List
