#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ExpectedDiskId,

    [Parameter(Mandatory)]
    [int[]] $ExpectedImageIndexes,

    [int] $ExpectedFactoryPartition = 4,

    [int] $RemovedPartition = 0,

    [Parameter(Mandatory)]
    [string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Start-Transcript -LiteralPath $ReportPath -Force | Out-Null

& (Join-Path $PSScriptRoot 'Verify-PostIntegrationState.ps1') `
    -ExpectedDiskId $ExpectedDiskId `
    -ExpectedImageIndexes $ExpectedImageIndexes `
    -ExpectedFactoryPartition $ExpectedFactoryPartition `
    -RemovedPartition $RemovedPartition

$bootManager = (& bcdedit.exe /enum '{bootmgr}' /v 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'BCD boot-manager inspection failed.' }
if ($bootManager -match '(?im)^\s*bootsequence\s+') {
    throw 'The one-time BCD boot sequence was not cleared.'
}

$dirtyOutput = (& fsutil.exe dirty query $env:SystemDrive 2>&1) -join "`n"
$dirtyOutput | Write-Host
if ($LASTEXITCODE -ne 0) {
    throw "Could not query the $env:SystemDrive dirty bit."
}
if ($dirtyOutput -match '(?im)\bis\s+Dirty\s*$' -and
    $dirtyOutput -notmatch '(?im)\bis\s+NOT\s+Dirty\s*$') {
    throw "$env:SystemDrive is dirty."
}
$systemVolume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')
if ($systemVolume.HealthStatus -ne 'Healthy') {
    throw "$env:SystemDrive health is $($systemVolume.HealthStatus)."
}

[pscustomobject]@{
    OneTimeBootSequence = 'Cleared'
    SystemVolumeHealth = $systemVolume.HealthStatus
    Result = 'POST-FACTORY-BOOT VERIFICATION PASSED'
} | Format-List

Stop-Transcript | Out-Null
