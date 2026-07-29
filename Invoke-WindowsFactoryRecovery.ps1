#Requires -Version 5.1

<#
.SYNOPSIS
Interactive bootstrap for Windows Factory Recovery Manager.

.DESCRIPTION
Designed for:
  irm <raw GitHub URL>/Invoke-WindowsFactoryRecovery.ps1 | iex

The bootstrap downloads the full manager to a temporary file, gathers simple
operation inputs, and runs the manager with its original safety confirmations.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managerUrl =
    'https://raw.githubusercontent.com/yuanliuus/createWindowsFactoryRecovery/main/Manage-WindowsFactoryRecovery.ps1'

function Read-MenuChoice {
    while ($true) {
        $answer = (Read-Host 'Choose an operation').Trim().ToLowerInvariant()
        if ($answer -in @('1', '2', '3', '4', '5', '6', 'h', 'q')) {
            return $answer
        }
        Write-Host 'Enter 1, 2, 3, 4, 5, 6, h, or q.' -ForegroundColor Yellow
    }
}

function Read-RequiredWimPath {
    while ($true) {
        $path = (Read-Host 'Captured WIM path').Trim().Trim('"')
        if ($path) { return $path }
        Write-Host 'A WIM path is required.' -ForegroundColor Yellow
    }
}

function Add-ImageOptions {
    param(
        [Collections.Generic.List[string]] $Arguments,
        [switch] $IncludeSize
    )

    $Arguments.Add('--image-path')
    $Arguments.Add((Read-RequiredWimPath))

    $index = (Read-Host `
        'Lock to one image index? Enter a number or press Enter for all').Trim()
    if ($index) {
        $parsedIndex = 0
        if (-not [int]::TryParse($index, [ref]$parsedIndex) -or
            $parsedIndex -lt 1) {
            throw 'Image index must be a positive integer.'
        }
        $Arguments.Add('--image-index')
        $Arguments.Add($parsedIndex.ToString())
    }

    if ($IncludeSize) {
        $size = (Read-Host `
            'Recovery partition size in GB, or press Enter for 20').Trim()
        if ($size) {
            $parsedSize = 0
            if (-not [int]::TryParse($size, [ref]$parsedSize) -or
                $parsedSize -lt 8 -or $parsedSize -gt 2048) {
                throw 'Recovery size must be from 8 through 2048 GB.'
            }
            $Arguments.Add('--recovery-size-gb')
            $Arguments.Add($parsedSize.ToString())
        }
    }
}

Write-Host ''
Write-Host 'Windows Factory Recovery Manager' -ForegroundColor Cyan
Write-Host '  1  Create Factory Recovery (plan, prepare, and integrate)'
Write-Host '  2  Show a read-only plan'
Write-Host '  3  Prepare the recovery partition and files only'
Write-Host '  4  Integrate a prepared package with BCD and WinRE'
Write-Host '  5  Update an existing factory image'
Write-Host '  6  Remove Factory Recovery completely'
Write-Host '  h  Show manager help'
Write-Host '  q  Quit'
Write-Host ''

$choice = Read-MenuChoice
if ($choice -eq 'q') {
    Write-Host 'Cancelled; nothing was downloaded or changed.'
    return
}

$managerArguments = [Collections.Generic.List[string]]::new()
switch ($choice) {
    '1' {
        $managerArguments.Add('--create')
    }
    '2' { Add-ImageOptions $managerArguments -IncludeSize }
    '3' {
        Add-ImageOptions $managerArguments -IncludeSize
        $managerArguments.Add('--prepare')
    }
    '4' { $managerArguments.Add('--integrate') }
    '5' {
        Add-ImageOptions $managerArguments
        $managerArguments.Add('--update')
    }
    '6' { $managerArguments.Add('--remove') }
    'h' { $managerArguments.Add('--help') }
}

$downloadRoot = Join-Path $env:TEMP 'WindowsFactoryRecovery'
$managerPath = Join-Path $downloadRoot `
    "Manage-WindowsFactoryRecovery-$PID.ps1"
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12
    $managerSource = Invoke-RestMethod -Uri $managerUrl
    if ([string]::IsNullOrWhiteSpace($managerSource) -or
        $managerSource -notmatch 'Windows Factory Recovery Manager') {
        throw 'The downloaded manager did not pass the content check.'
    }
    $managerSource | Set-Content -LiteralPath $managerPath -Encoding UTF8
    $hash = (Get-FileHash -LiteralPath $managerPath -Algorithm SHA256).Hash
    Write-Host "Downloaded: $managerUrl"
    Write-Host "SHA-256:   $hash"

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdministrator = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($choice -eq 'h' -or $isAdministrator) {
        & $managerPath @managerArguments
        return
    }

    $quote = {
        param([string] $Value)
        '"' + $Value.Replace('"', '\"') + '"'
    }
    $processArguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (& $quote $managerPath)
    )
    $processArguments += @($managerArguments | ForEach-Object { & $quote $_ })
    Write-Host 'Administrator access is required; approve the UAC prompt.'
    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList $processArguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The manager exited with code $($process.ExitCode)."
    }
}
finally {
    Remove-Item -LiteralPath $managerPath -Force -ErrorAction SilentlyContinue
}
