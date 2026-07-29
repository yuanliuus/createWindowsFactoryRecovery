#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $root 'Manage-WindowsFactoryRecovery.ps1'
$log = Join-Path $root 'live-integrate-output.txt'
$result = Join-Path $root 'live-integrate-result.txt'

trap {
    ($_ | Format-List * -Force | Out-String) |
        Set-Content -LiteralPath $result -Encoding UTF8
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}

Start-Transcript -LiteralPath $log -Force | Out-Null
function global:Read-Host {
    param([string] $Prompt)
    if ($Prompt -match 'Add Factory Recovery') { return 'y' }
    if ($Prompt -match 'Type INTEGRATE') { return 'INTEGRATE' }
    throw "Unexpected confirmation prompt: $Prompt"
}

& $manager --integrate -Confirm:$false

'INTEGRATION COMPLETED' | Set-Content -LiteralPath $result -Encoding UTF8
Stop-Transcript | Out-Null
