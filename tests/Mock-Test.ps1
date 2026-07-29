#Requires -Version 5.1

<#
Static and non-destructive mock tests. Production code is loaded in memory,
administrator discovery is replaced, and every mutating storage/BCD/WinRE
command is guarded. No real system command is allowed to mutate state.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'Manage-WindowsFactoryRecovery.ps1'

$parseErrors = $null
$tokens = $null
[Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) {
    throw "Parser errors: $($parseErrors.Message -join '; ')"
}

$source = Get-Content $scriptPath -Raw
$required = @(
    '--prepare', '--integrate', '--update', '--remove',
    'user selects during recovery',
    'ImageCatalog.txt', 'ValidateImageIndex.cmd',
    'ShowImageDetails.cmd', 'ImageDetails-',
    'SELECTED FACTORY IMAGE',
    '/Index:%IMAGE_INDEX%',
    'SchemaVersion = 3',
    'Add Factory Recovery to Windows Boot Manager?',
    'Private device-options object',
    '/create /d ''Factory Recovery Ramdisk'' /device',
    'Checkpoint-', '/export', '/import',
    'Old WinRE is preserved',
    'Online delete/recreate resizing is intentionally disabled',
    'Type REMOVE-FACTORY to permanently remove factory recovery',
    'New-CleanWinre',
    'Get-FactoryBcdIdentifiers',
    '$PartitionAlignmentReserve',
    '%SYSTEMDRIVE%\Sources\Recovery\RecEnv.exe',
    "Remove-Partition -DiskNumber `$factoryPart.DiskNumber",
    'Standard WinRE could not be verified after factory removal',
    'uniqueid disk', 'Expected disk ID',
    'Tools\findstr.exe',
    'PLAN ONLY:', 'WHAT-IF COMPLETE:'
)
foreach ($text in $required) {
    if ($source -notmatch [regex]::Escape($text)) {
        throw "Required safety element is missing: $text"
    }
}
if ($source -match "bcdedit\.exe\s+@\('/set',\s*'\{ramdiskoptions\}'") {
    throw 'The production script still modifies shared {ramdiskoptions}.'
}
$exportPosition = $source.IndexOf("bcdedit.exe @('/export'")
$disablePosition = $source.IndexOf("reagentc.exe @('/disable')")
if ($exportPosition -lt 0 -or $disablePosition -lt 0 -or
    $exportPosition -gt $disablePosition) {
    throw 'BCD export must occur before WinRE is disabled.'
}

$source = $source -replace
    '(?s)# MOCK-ADMIN-CHECK-BEGIN.*?# MOCK-ADMIN-CHECK-END',
    '$administrator = $true'
$production = [scriptblock]::Create($source)
$script:Mutations = 0
$script:MockMultipleImages = $false

function Stop-Mutation([string] $Name) {
    $script:Mutations++
    throw "Mutation guard reached: $Name"
}

function global:dism.exe {
    $global:LASTEXITCODE = 0
    'Index : 1'
    'Name : Mock Windows Server'
    'Description : Mock factory image'
    'Edition : ServerStandard'
    'Installation : Server Core'
    'Architecture : x64'
    'Version : 10.0.26100.0'
    'Size : 20,000,000,000 bytes'
    'Modified : 7/28/2026 - 1:00 PM'
    if ($script:MockMultipleImages) {
        'Index : 2'
        'Name : Mock Windows Server Datacenter'
    }
}
function global:Read-Host {
    param([string] $Prompt)
    throw "Unexpected mock prompt: $Prompt"
}
function global:reagentc.exe {
    if ($args -contains '/info') {
        $global:LASTEXITCODE = 0
        'Windows RE status: Disabled'
        return
    }
    Stop-Mutation 'reagentc'
}
function global:bcdedit.exe { Stop-Mutation 'bcdedit' }
function global:diskpart.exe { Stop-Mutation 'diskpart' }
function global:Get-Disk {
    [pscustomobject]@{
        Number = 0
        Guid = [guid]'11111111-2222-3333-4444-555555555555'
        UniqueId = 'mock'
        PartitionStyle = 'GPT'
        IsBoot = $true
        IsSystem = $true
        IsOffline = $false
        IsReadOnly = $false
    }
}
function global:Get-Partition {
    param([string] $DriveLetter, [int] $DiskNumber, [object] $Volume)
    if ($DriveLetter) {
        return [pscustomobject]@{
            DiskNumber = 0; PartitionNumber = 3; Size = 100GB; Offset = 1GB
        }
    }
    if ($Volume) { return $null }
    @(
        [pscustomobject]@{
            DiskNumber = 0; PartitionNumber = 1
            GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        },
        [pscustomobject]@{
            DiskNumber = 0; PartitionNumber = 3
            GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        }
    )
}
function global:Get-Volume {
    param([object] $Partition, [string] $DriveLetter)
    @()
}
function global:Get-BitLockerVolume {
    [pscustomobject]@{ ProtectionStatus = 'Off' }
}
function global:Resize-Partition { Stop-Mutation 'Resize-Partition' }
function global:Remove-Partition { Stop-Mutation 'Remove-Partition' }
function global:New-Partition { Stop-Mutation 'New-Partition' }
function global:Format-Volume { Stop-Mutation 'Format-Volume' }
function global:Set-Partition { Stop-Mutation 'Set-Partition' }
function global:Add-PartitionAccessPath { Stop-Mutation 'Add-PartitionAccessPath' }
function global:Remove-PartitionAccessPath { Stop-Mutation 'Remove-PartitionAccessPath' }

$tempImage = Join-Path $env:TEMP 'FactoryRecoveryMock.wim'
try {
    Set-Content $tempImage 'mock'

    $help = & $production '--help' 6>&1 | Out-String
    if ($help -notmatch '--prepare' -or $help -notmatch '--integrate' -or
        $help -notmatch '--remove') {
        throw 'Help test failed.'
    }

    $plan = & $production '--image-path' $tempImage 6>&1 | Out-String
    if ($plan -notmatch 'PLAN ONLY:') { throw 'Plan test failed.' }

    $script:MockMultipleImages = $true
    $multiImagePlan = & $production '--image-path' $tempImage 6>&1 | Out-String
    if ($multiImagePlan -notmatch
        'Indexes\s*:\s*1, 2 \(user selects during recovery\)') {
        throw "Deferred multi-image selection plan test failed.`n$multiImagePlan"
    }
    $lockedPlan = & $production '--image-path' $tempImage `
        '--image-index' '2' 6>&1 | Out-String
    if ($lockedPlan -notmatch 'Index\s*:\s*2 - Mock Windows Server Datacenter \(locked\)') {
        throw 'Locked image selection plan test failed.'
    }
    $script:MockMultipleImages = $false

    foreach ($arguments in @(
        @('-i', $tempImage, '--prepare', '--what-if'),
        @('-i', $tempImage, '--update', '--what-if'),
        @('--integrate', '--what-if'),
        @('--remove', '--what-if'))) {
        $result = & $production @arguments 6>&1 | Out-String
        if ($result -notmatch 'WHAT-IF COMPLETE:') {
            throw "What-if test failed for $($arguments -join ' ')."
        }
    }
    if ($script:Mutations -ne 0) {
        throw "$script:Mutations mutation guard(s) were reached."
    }

    [pscustomobject]@{
        Parser = 'PASS'
        StaticSafety = 'PASS'
        Help = 'PASS'
        Plan = 'PASS'
        DeferredImageSelection = 'PASS'
        LockedImageSelection = 'PASS'
        PrepareWhatIf = 'PASS'
        UpdateWhatIf = 'PASS'
        IntegrateWhatIf = 'PASS'
        RemoveWhatIf = 'PASS'
        MutationCommandsReached = $script:Mutations
        Result = 'ALL MOCK TESTS PASSED'
    } | Format-List
}
finally {
    Remove-Item $tempImage -ErrorAction SilentlyContinue
    foreach ($name in @(
        'dism.exe','reagentc.exe','bcdedit.exe','diskpart.exe','Get-Disk',
        'Read-Host',
        'Get-Partition','Get-Volume','Get-BitLockerVolume','Resize-Partition',
        'Remove-Partition','New-Partition','Format-Volume','Set-Partition',
        'Add-PartitionAccessPath','Remove-PartitionAccessPath')) {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
}
