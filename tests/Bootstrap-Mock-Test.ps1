#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$bootstrap = Join-Path $root 'Invoke-WindowsFactoryRecovery.ps1'
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $bootstrap, [ref]$null, [ref]$errors)
if ($errors.Count) {
    throw "Bootstrap parser errors: $($errors.Message -join '; ')"
}

$source = Get-Content -LiteralPath $bootstrap -Raw
foreach ($required in @(
        'raw.githubusercontent.com/yuanliuus/createWindowsFactoryRecovery/main',
        'Show a read-only plan',
        '--create',
        '--prepare',
        '--integrate',
        '--update',
        '--remove',
        'Get-FileHash',
        'Start-Process',
        '-Verb RunAs',
        'Remove-Item -LiteralPath $managerPath')) {
    if ($source -notmatch [regex]::Escape($required)) {
        throw "Bootstrap safety/behavior element is missing: $required"
    }
}
foreach ($forbidden in @(
        'Resize-Partition',
        'Remove-Partition',
        'Format-Volume',
        'bcdedit.exe',
        'reagentc.exe')) {
    if ($source -match [regex]::Escape($forbidden)) {
        throw "Bootstrap contains a forbidden direct mutation: $forbidden"
    }
}

$manager = Join-Path $root 'Manage-WindowsFactoryRecovery.ps1'
$script:RequestedUri = $null
function global:Read-Host {
    param([string] $Prompt)
    if ($Prompt -eq 'Choose an operation') { return 'h' }
    throw "Unexpected bootstrap prompt: $Prompt"
}
function global:Invoke-RestMethod {
    param([string] $Uri)
    $script:RequestedUri = $Uri
    Get-Content -LiteralPath $manager -Raw
}
try {
    $executionOutput = & ([scriptblock]::Create($source)) 6>&1 | Out-String
    if ($executionOutput -notmatch 'Windows Factory Recovery Manager' -or
        $executionOutput -notmatch 'USAGE') {
        throw 'Bootstrap help execution did not invoke the downloaded manager.'
    }
    if ($script:RequestedUri -notmatch
        'raw\.githubusercontent\.com/.+/Manage-WindowsFactoryRecovery\.ps1') {
        throw 'Bootstrap did not request the expected manager URL.'
    }
}
finally {
    Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    Parser = 'PASS'
    Menu = 'PASS'
    TemporaryDownload = 'PASS'
    UacDelegation = 'PASS'
    MockHelpExecution = 'PASS'
    DirectMutationCommands = 0
    Result = 'BOOTSTRAP MOCK TEST PASSED'
} | Format-List
