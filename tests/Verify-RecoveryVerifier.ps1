#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Alias('ExpectedImageIndex')]
    [int[]] $ExpectedImageIndexes = @()
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$report = Join-Path $root 'recovery-verifier-test.txt'
$factoryVolume = Get-Volume |
    Where-Object FileSystemLabel -eq 'FACTORY_RECOVERY' |
    Select-Object -First 1
if (-not $factoryVolume) { throw 'FACTORY_RECOVERY volume was not found.' }
$factoryPartition = Get-Partition -Volume $factoryVolume
$usedLetters = @(Get-Volume | Where-Object DriveLetter |
    ForEach-Object { $_.DriveLetter.ToString() })
$letter = @('R','Q','T','U','V') |
    Where-Object { $_ -notin $usedLetters } |
    Select-Object -First 1
if (-not $letter) { throw 'No temporary drive letter is available.' }

$accessAdded = -not $factoryVolume.DriveLetter
if (-not $accessAdded) { $letter = $factoryVolume.DriveLetter.ToString() }
$working = Join-Path $env:ProgramData `
    ('FactoryRecoveryBuild\Verify-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$mount = Join-Path $working 'Mount'
New-Item -ItemType Directory -Path $mount -Force | Out-Null

try {
    if ($accessAdded) {
        Add-PartitionAccessPath -DiskNumber $factoryPartition.DiskNumber `
            -PartitionNumber $factoryPartition.PartitionNumber `
            -AccessPath "$letter`:\"
    }
    $disk = Get-Disk -Number $factoryPartition.DiskNumber
    $diskId = $disk.Guid.ToString().Trim('{}')
    $results = foreach ($wim in @(
            "$letter`:\FactoryRecovery\FactoryRE.wim",
            "$letter`:\Recovery\WindowsRE\Winre.wim")) {
        & dism.exe /Mount-Image "/ImageFile:$wim" /Index:1 "/MountDir:$mount" /ReadOnly |
            Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Could not mount $wim read-only." }
        try {
            $verifier = Join-Path $mount 'Sources\Recovery\Tools\findstr.exe'
            $restoreScript = Join-Path $mount 'Sources\Recovery\Tools\RestoreFactory.cmd'
            $catalog = Join-Path $mount 'Sources\Recovery\Tools\ImageCatalog.txt'
            $indexValidator = Join-Path $mount `
                'Sources\Recovery\Tools\ValidateImageIndex.cmd'
            $detailsLauncher = Join-Path $mount `
                'Sources\Recovery\Tools\ShowImageDetails.cmd'
            $launcher = Join-Path $mount 'Sources\Recovery\Tools\cmd.exe'
            $launcherMui = Get-ChildItem `
                (Join-Path $mount 'Sources\Recovery\Tools') `
                -Filter 'cmd.exe.mui' -File -Recurse |
                Select-Object -First 1
            if (-not (Test-Path $verifier -PathType Leaf)) {
                throw "Bundled verifier is missing from $wim."
            }
            if (-not (Test-Path $restoreScript -PathType Leaf)) {
                throw "Restore script is missing from $wim."
            }
            if (-not (Test-Path $catalog -PathType Leaf) -or
                -not (Test-Path $indexValidator -PathType Leaf) -or
                -not (Test-Path $detailsLauncher -PathType Leaf)) {
                throw "Image catalog, validator, or details launcher is missing from $wim."
            }
            if (-not (Test-Path $launcher -PathType Leaf) -or -not $launcherMui) {
                throw "Resource-complete cmd.exe launcher is missing from $wim."
            }
            $winreConfig = Get-Content `
                (Join-Path $mount 'Sources\Recovery\Tools\WinREConfig.xml') -Raw
            if ($winreConfig -notmatch
                '<RelativeFilePath>cmd\.exe</RelativeFilePath>') {
                throw "WinREConfig.xml does not select cmd.exe in $wim."
            }
            $launcherOutput = 'CANCEL' |
                & $launcher /d /v:on /c `
                    'set /p CONFIRM=Type RESTORE: & echo VALUE=!CONFIRM!' 2>&1 |
                Out-String
            if ($launcherOutput -match
                'cannot find message text|message number 0x[0-9a-f]+' -or
                $launcherOutput -notmatch 'VALUE=CANCEL') {
                throw "Resource-complete launcher prompt test failed in $wim.`n$launcherOutput"
            }
            $restoreText = Get-Content $restoreScript -Raw
            if ($restoreText -notmatch
                [regex]::Escape('X:\Sources\Recovery\Tools\findstr.exe')) {
                throw "Restore script does not call the bundled verifier in $wim."
            }
            if ($restoreText -notmatch
                '(?i)/Index:%IMAGE_INDEX%(?:\s|$)') {
                throw "Restore script does not apply the validated image index in $wim."
            }
            if ($restoreText -notmatch
                '(?i)ShowImageDetails\.cmd\s+"%IMAGE_INDEX%"') {
                throw "Restore script does not display the selected image details in $wim."
            }
            $catalogText = Get-Content -LiteralPath $catalog -Raw
            foreach ($expectedIndex in $ExpectedImageIndexes) {
                if ($catalogText -notmatch
                    "(?m)^Image index:\s*$expectedIndex\s*$") {
                    throw "Image index $expectedIndex is missing from the catalog in $wim."
                }
                $detailsFile = Join-Path $mount `
                    "Sources\Recovery\Tools\ImageDetails-$expectedIndex.txt"
                if (-not (Test-Path -LiteralPath $detailsFile -PathType Leaf)) {
                    throw "Image details for index $expectedIndex are missing from $wim."
                }
                $detailsText = Get-Content -LiteralPath $detailsFile -Raw
                if ($detailsText -notmatch '(?m)^Name:\s*\S') {
                    throw "Image index $expectedIndex has no displayed title in $wim."
                }
                & $launcher /d /c "`"$indexValidator`" $expectedIndex"
                if ($LASTEXITCODE -ne 0) {
                    throw "Validator rejected image index $expectedIndex in $wim."
                }
                $detailsLauncherText = Get-Content `
                    -LiteralPath $detailsLauncher -Raw
                $expectedDetailsCall = [regex]::Escape(
                    "type X:\Sources\Recovery\Tools\ImageDetails-$expectedIndex.txt")
                if ($detailsLauncherText -notmatch $expectedDetailsCall) {
                    throw "Details launcher does not map image index $expectedIndex in $wim."
                }
                $displayOutput = & $launcher /d /c `
                    "type `"$detailsFile`"" 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0 -or
                    $displayOutput -notmatch '(?m)^Name:\s*\S') {
                    throw "Selected-image display failed for index $expectedIndex in $wim."
                }
            }
            & $launcher /d /c "`"$indexValidator`" 2147483647"
            if ($LASTEXITCODE -eq 0) {
                throw "Validator accepted an unlisted image index in $wim."
            }
            $shellConfig = Join-Path $mount 'Windows\System32\winpeshl.ini'
            if (-not (Test-Path -LiteralPath $shellConfig -PathType Leaf)) {
                throw "Winpeshl.ini is missing from $wim."
            }
            $shellText = Get-Content -LiteralPath $shellConfig -Raw
            if ($wim -like '*\Recovery\WindowsRE\Winre.wim') {
                if ($shellText -notmatch
                    '(?i)%SYSTEMDRIVE%\\Sources\\Recovery\\RecEnv\.exe') {
                    throw "Normal WinRE does not launch RecEnv.exe in $wim."
                }
                $shellLaunch = 'RecEnv.exe'
            } else {
                if ($shellText -notmatch
                    '(?i)RestoreFactory\.cmd') {
                    throw "Dedicated FactoryRE does not launch its restore script in $wim."
                }
                $shellLaunch = 'RestoreFactory.cmd'
            }
            $sample = Join-Path $working 'DiskIdentitySample.txt'
            "Disk ID: {$diskId}" | Set-Content $sample -Encoding ASCII
            & $verifier /i "/c:$diskId" $sample | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Bundled verifier did not match the expected disk ID in $wim."
            }
            [pscustomobject]@{
                WIM = $wim
                VerifierPresent = $true
                RestoreCallPresent = $true
                ResourceCompleteLauncher = $true
                LauncherPromptTest = 'PASS'
                DiskIdMatchTest = 'PASS'
                RestoreImageIndexes = if ($ExpectedImageIndexes.Count) {
                    $ExpectedImageIndexes -join ','
                } else { 'Not checked' }
                ShellLaunch = $shellLaunch
            }
        }
        finally {
            & dism.exe /Unmount-Image "/MountDir:$mount" /Discard | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Could not unmount $wim." }
        }
    }
    $results | Format-List | Out-String |
        Set-Content -LiteralPath $report -Encoding UTF8
    Add-Content -LiteralPath $report `
        -Value 'RECOVERY VERIFIER READ-ONLY TEST PASSED'
}
finally {
    if ($accessAdded) {
        Remove-PartitionAccessPath -DiskNumber $factoryPartition.DiskNumber `
            -PartitionNumber $factoryPartition.PartitionNumber `
            -AccessPath "$letter`:\" -ErrorAction SilentlyContinue
        $remaining = Get-Volume -Partition $factoryPartition `
            -ErrorAction SilentlyContinue
        if ($remaining -and $remaining.DriveLetter -and
            $remaining.DriveLetter.ToString() -eq $letter) {
            $cleanup = Join-Path $working 'RemoveAccess.txt'
@"
select disk $($factoryPartition.DiskNumber)
select partition $($factoryPartition.PartitionNumber)
remove letter=$letter
exit
"@ | Set-Content -LiteralPath $cleanup -Encoding ASCII
            & diskpart.exe /s $cleanup | Out-Null
        }
    }
}
