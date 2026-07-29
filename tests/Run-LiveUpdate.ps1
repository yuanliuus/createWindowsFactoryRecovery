#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ImagePath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $root 'Manage-WindowsFactoryRecovery.ps1'
$log = Join-Path $root 'live-update-output.txt'
$result = Join-Path $root 'live-update-result.txt'

trap {
    ($_ | Format-List * -Force | Out-String) |
        Set-Content -LiteralPath $result -Encoding UTF8
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}

Start-Transcript -LiteralPath $log -Force | Out-Null
function global:Read-Host {
    param([string] $Prompt)
    if ($Prompt -match 'Type UPDATE') { return 'UPDATE' }
    throw "Unexpected confirmation prompt: $Prompt"
}

& $manager `
    --image-path $ImagePath `
    --update `
    -Confirm:$false

'UPDATE COMPLETED' | Set-Content -LiteralPath $result -Encoding UTF8
Stop-Transcript | Out-Null
