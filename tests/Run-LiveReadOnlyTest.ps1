#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ImagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'Manage-WindowsFactoryRecovery.ps1'
$reportPath = Join-Path $root 'live-readonly-test.txt'
$errorPath = Join-Path $root 'live-readonly-test-error.txt'
Remove-Item -LiteralPath $errorPath -ErrorAction SilentlyContinue
trap {
    ($_ | Format-List * -Force | Out-String) |
        Set-Content -LiteralPath $errorPath -Encoding UTF8
    exit 1
}

if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
    throw "Test image not found: $ImagePath"
}

$sections = [Collections.Generic.List[string]]::new()
function Invoke-ReadOnlyCase {
    param([string] $Name, [string[]] $Arguments, [string] $Expected)

    $output = & $scriptPath @Arguments 6>&1 5>&1 4>&1 3>&1 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "$Name exited with code $LASTEXITCODE.`n$output"
    }
    if ($output -notmatch [regex]::Escape($Expected)) {
        throw "$Name did not produce '$Expected'.`n$output"
    }
    $sections.Add("===== $Name =====`r`n$output")
}

Invoke-ReadOnlyCase -Name 'LIVE PLAN' `
    -Arguments @('--image-path', $ImagePath) `
    -Expected 'PLAN ONLY:'
Invoke-ReadOnlyCase -Name 'LIVE UPDATE WHAT-IF' `
    -Arguments @('--image-path', $ImagePath, '--update', '--what-if') `
    -Expected 'WHAT-IF COMPLETE:'
Invoke-ReadOnlyCase -Name 'LIVE INTEGRATE WHAT-IF' `
    -Arguments @('--integrate', '--what-if') `
    -Expected 'WHAT-IF COMPLETE:'

$factoryVolumes = @(Get-Volume |
    Where-Object FileSystemLabel -eq 'FACTORY_RECOVERY')
if ($factoryVolumes.Count -ne 1) {
    throw "Expected exactly one FACTORY_RECOVERY volume; found $($factoryVolumes.Count)."
}
$factoryVolume = $factoryVolumes[0]
$factoryPartition = Get-Partition -Volume $factoryVolume
$volumeRoot = $factoryVolume.Path
$packageChecks = foreach ($relative in @(
        'FactoryRecovery\FactoryImage.wim',
        'FactoryRecovery\FactoryRE.wim',
        'Recovery\WindowsRE\Winre.wim',
        'FactoryRecovery\Manifest.json')) {
    $fullPath = Join-Path $volumeRoot $relative
    [pscustomobject]@{
        File = $relative
        Exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    }
}
$winreInfo = (& reagentc.exe /info 2>&1) -join "`r`n"
$bcdInfo = (& bcdedit.exe /enum all /v 2>&1) -join "`r`n"
$bootManagerInfo = (& bcdedit.exe /enum '{bootmgr}' /v 2>&1) -join "`r`n"
$currentLoaderInfo = (& bcdedit.exe /enum '{current}' /v 2>&1) -join "`r`n"
$factoryBcdPresent = $bcdInfo -match '(?im)description\s+Factory Recovery\s*$'
$factoryRamdiskPresent = $bcdInfo -match '(?im)description\s+Factory Recovery Ramdisk\s*$'
$factoryWimReferenced = $bcdInfo -match 'FactoryRecovery\\FactoryRE\.wim'
$currentId = [regex]::Match($currentLoaderInfo,
    '(?im)^\s*identifier\s+(\{[0-9a-fA-F-]{36}\})').Groups[1].Value
$defaultId = [regex]::Match($bootManagerInfo,
    '(?im)^\s*default\s+(\{[0-9a-fA-F-]{36}\})').Groups[1].Value
$normalWindowsIsDefault = $currentId -and $defaultId -and $currentId -eq $defaultId
if (-not $factoryBcdPresent -or -not $factoryRamdiskPresent -or
    -not $factoryWimReferenced -or -not $normalWindowsIsDefault) {
    throw (("Final BCD verification failed: Factory={0}; Ramdisk={1}; " +
        "WimReference={2}; Current={3}; Default={4}; WindowsDefault={5}") -f
        $factoryBcdPresent, $factoryRamdiskPresent, $factoryWimReferenced,
        $currentId, $defaultId, $normalWindowsIsDefault)
}
$sections.Add(@"
===== LIVE RECOVERY STATE (READ-ONLY) =====
Factory partition: disk $($factoryPartition.DiskNumber), partition $($factoryPartition.PartitionNumber)
Factory size: $([math]::Round($factoryPartition.Size / 1GB, 2)) GB
Factory free: $([math]::Round($factoryVolume.SizeRemaining / 1GB, 2)) GB

$($packageChecks | Format-Table -AutoSize | Out-String)
WinRE:
$winreInfo

Factory Recovery BCD entry present: $factoryBcdPresent
Private Factory ramdisk present: $factoryRamdiskPresent
FactoryRE.wim referenced: $factoryWimReferenced
Normal Windows loader ID: $currentId
Boot Manager default ID: $defaultId
Normal Windows remains default: $normalWindowsIsDefault
"@)

$sections.Add(@"
===== RESULT =====
LIVE READ-ONLY TESTS PASSED
No prepare, update, integration, partition, BCD, or REAgentC mutation path was entered.
"@)
$sections -join "`r`n" | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "LIVE READ-ONLY TESTS PASSED"
Write-Host "Report: $reportPath"
