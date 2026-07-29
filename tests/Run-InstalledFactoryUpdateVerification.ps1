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

    [int] $RemovedPartition = 0,

    [Parameter(Mandatory)]
    [string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    & (Join-Path $PSScriptRoot 'Verify-InstalledFactoryUpdate.ps1') `
        -SourceWim $SourceWim `
        -ExpectedDiskId $ExpectedDiskId `
        -ExpectedImageIndexes $ExpectedImageIndexes `
        -ExpectedFactoryPartition $ExpectedFactoryPartition `
        -RemovedPartition $RemovedPartition *>&1 |
        Tee-Object -FilePath $ReportPath
    if ($LASTEXITCODE -ne 0) {
        throw "Installed factory update verification exited with code $LASTEXITCODE."
    }
}
catch {
    $_ | Out-String | Tee-Object -FilePath $ReportPath -Append
    throw
}
