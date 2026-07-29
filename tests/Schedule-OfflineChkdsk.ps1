#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string] $Drive = $env:SystemDrive,

    [Parameter(Mandatory)]
    [string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$driveName = $Drive.TrimEnd(':') + ':'
$output = ('Y' | & chkdsk.exe $driveName /f 2>&1) -join "`r`n"
$output | Set-Content -LiteralPath $ReportPath -Encoding UTF8
if ($output -notmatch
    '(?i)(scheduled to be checked|will be checked the next time|check this volume the next time)') {
    throw "CHKDSK did not confirm an offline repair schedule.`n$output"
}

& shutdown.exe /r /t 20 /d p:4:1 `
    /c 'Offline CHKDSK repair after Factory Recovery boot test'
if ($LASTEXITCODE -ne 0) {
    throw "CHKDSK was scheduled, but restart scheduling failed with exit code $LASTEXITCODE."
}
