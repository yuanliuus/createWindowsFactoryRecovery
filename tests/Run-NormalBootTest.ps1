#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$result = Join-Path $root 'reboot-scheduled.txt'

& shutdown.exe /r /t 15 /d p:4:1 /c 'Factory Recovery normal Windows boot validation'
if ($LASTEXITCODE -ne 0) {
    throw "shutdown.exe failed with exit code $LASTEXITCODE."
}

@"
REBOOT SCHEDULED
Scheduled by: $env:USERNAME
Time: $([DateTime]::Now.ToString('o'))
Expected boot: Normal Windows (Boot Manager default)
"@ | Set-Content -LiteralPath $result -Encoding UTF8
