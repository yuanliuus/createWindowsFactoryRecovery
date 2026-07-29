#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
Exercises the real --remove path through package validation, then deliberately
fails the REMOVE-FACTORY confirmation. It verifies that partitions, BCD, and
WinRE registration are unchanged afterward.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manager = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'Manage-WindowsFactoryRecovery.ps1'

function Get-PartitionSnapshot {
    @(Get-Partition | Sort-Object DiskNumber, PartitionNumber | ForEach-Object {
        [ordered]@{
            DiskNumber = $_.DiskNumber
            PartitionNumber = $_.PartitionNumber
            Offset = $_.Offset
            Size = $_.Size
            DriveLetter = if ($_.DriveLetter) { $_.DriveLetter.ToString() } else { '' }
            GptType = $_.GptType
        }
    }) | ConvertTo-Json -Compress
}

$partitionsBefore = Get-PartitionSnapshot
$bcdBefore = (& bcdedit.exe /enum all /v 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Could not capture the initial BCD state.' }
$winreBefore = (& reagentc.exe /info 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Could not capture the initial WinRE state.' }

function global:Read-Host {
    param([string] $Prompt)
    Write-Host "$Prompt [automatic test response: CANCEL-TEST]"
    'CANCEL-TEST'
}

try {
    $result = & $manager --remove -Confirm:$false 6>&1 | Out-String
    $result | Write-Host
}
finally {
    Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
}

if ($result -notmatch 'Factory recovery removal cancelled; no changes made\.') {
    throw 'The removal path did not stop at its critical confirmation.'
}

$partitionsAfter = Get-PartitionSnapshot
$bcdAfter = (& bcdedit.exe /enum all /v 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Could not capture the final BCD state.' }
$winreAfter = (& reagentc.exe /info 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Could not capture the final WinRE state.' }

if ($partitionsAfter -cne $partitionsBefore) {
    throw 'Partition state changed during the cancellation test.'
}
if ($bcdAfter -cne $bcdBefore) {
    throw 'BCD state changed during the cancellation test.'
}
if ($winreAfter -cne $winreBefore) {
    throw 'WinRE registration changed during the cancellation test.'
}

[pscustomobject]@{
    PackageValidation = 'PASS'
    CriticalConfirmationCancellation = 'PASS'
    PartitionsUnchanged = 'PASS'
    BcdUnchanged = 'PASS'
    WinreUnchanged = 'PASS'
    Result = 'LIVE REMOVE CANCELLATION TEST PASSED'
} | Format-List
