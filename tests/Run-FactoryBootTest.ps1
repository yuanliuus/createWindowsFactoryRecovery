#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resultPath = Join-Path $root 'factory-boot-test-scheduled.txt'
$workingRoot = Join-Path $env:ProgramData 'FactoryRecoveryBuild'
$checkpoint = Join-Path $workingRoot `
    ('FactoryBootTest-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

New-Item -ItemType Directory -Path $checkpoint -Force | Out-Null
$bcdBackup = Join-Path $checkpoint 'BCD'
& bcdedit.exe /export $bcdBackup | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "BCD export failed with exit code $LASTEXITCODE."
}

$bcdText = (& bcdedit.exe /enum all /v 2>&1) -join "`r`n"
if ($LASTEXITCODE -ne 0) {
    throw "BCD enumeration failed with exit code $LASTEXITCODE."
}
$sections = [regex]::Split($bcdText, '(?:\r?\n){2,}')
$factorySection = $sections | Where-Object {
    $_ -match '(?im)^\s*description\s+Factory Recovery\s*$' -and
    $_ -match 'FactoryRecovery\\FactoryRE\.wim' -and
    $_ -match '(?im)^\s*winpe\s+Yes\s*$'
} | Select-Object -First 1
if (-not $factorySection) {
    throw 'The verified Factory Recovery loader was not found.'
}
$factoryGuid = [regex]::Match(
    $factorySection,
    '(?im)^\s*identifier\s+(\{[0-9a-fA-F-]{36}\})').Groups[1].Value
if (-not $factoryGuid) {
    throw 'The Factory Recovery loader identifier could not be parsed.'
}

& bcdedit.exe /bootsequence $factoryGuid | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "One-time boot sequence failed with exit code $LASTEXITCODE."
}

@"
FACTORY RECOVERY BOOT TEST SCHEDULED
Time: $([DateTime]::Now.ToString('o'))
Factory loader: $factoryGuid
BCD checkpoint: $bcdBackup

At the Factory Recovery prompt:
1. If prompted, enter one of the listed image indexes. A locked single-image
   package selects its image automatically.
2. Confirm that the expected image index is shown.
3. Press Enter without typing RESTORE.
4. The computer will reboot directly to normal Windows.
"@ | Set-Content -LiteralPath $resultPath -Encoding UTF8

& shutdown.exe /r /t 20 /d p:4:1 /c 'One-time Factory Recovery boot validation'
if ($LASTEXITCODE -ne 0) {
    & bcdedit.exe /deletevalue '{bootmgr}' bootsequence | Out-Null
    throw "Reboot scheduling failed; one-time boot sequence was removed."
}
