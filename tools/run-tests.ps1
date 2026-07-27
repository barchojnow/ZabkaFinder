<#
.SYNOPSIS
    Runs the Connect IQ unit tests across several devices in one go.

.DESCRIPTION
    The Connect IQ simulator only ever runs one device at a time, so
    "all devices at once" means a sequential loop: build a unit-test
    binary per device, run it, collect the result.

    The tested logic (GeoMath, StoreList) is device-independent, so
    running all 66 products is mostly redundant - what differs per
    device is memory and compilation, and `Export Project` already
    covers compilation everywhere. The default list below is the
    representative set: tightest memory, oldest API, newest hardware,
    touch, and no-compass.

.EXAMPLE
    .\tools\run-tests.ps1
    .\tools\run-tests.ps1 -Devices fenix5,venu2
    .\tools\run-tests.ps1 -All          # every product in manifest.xml
#>

param(
    [string[]] $Devices = @('fr55', 'fenix5', 'venu2', 'fenix847mm'),
    [switch]   $All,
    [string]   $DeveloperKey
)

$ErrorActionPreference = 'Stop'
$project = Resolve-Path "$PSScriptRoot\.."
$jungle  = Join-Path $project 'monkey.jungle'
$outDir  = Join-Path $project 'bin\test'

# Developer key: usually kept outside the repo (it must never be
# committed). Look in the usual spots unless one was passed in.
if (-not $DeveloperKey) {
    $candidates = @(
        "$project\..\..\developer_key",   # vs_projects\developer_key
        "$project\..\developer_key",      # zabka_finder\developer_key
        "$env:APPDATA\Garmin\ConnectIQ\developer_key"
    )
    $DeveloperKey = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $DeveloperKey -or -not (Test-Path $DeveloperKey)) {
    throw "Developer key not found. Pass it explicitly: .\tools\run-tests.ps1 -DeveloperKey C:\path\to\developer_key"
}
$DeveloperKey = (Resolve-Path $DeveloperKey).Path
Write-Host "Developer key: $DeveloperKey" -ForegroundColor DarkGray

# Locate the active SDK the same way the VS Code extension does.
$sdkCfg = Join-Path $env:APPDATA 'Garmin\ConnectIQ\current-sdk.cfg'
if (Test-Path $sdkCfg) {
    $sdk = (Get-Content $sdkCfg -Raw).Trim()
} else {
    $sdk = (Get-ChildItem "$env:APPDATA\Garmin\ConnectIQ\Sdks" -Directory |
            Sort-Object Name -Descending | Select-Object -First 1).FullName
}
$monkeyc  = Join-Path $sdk 'bin\monkeyc.bat'
$monkeydo = Join-Path $sdk 'bin\monkeydo.bat'

if ($All) {
    $Devices = ([xml](Get-Content (Join-Path $project 'manifest.xml'))).
        manifest.application.products.product.id
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# monkeydo pushes to a running simulator - start it if needed.
if (-not (Get-Process -Name 'simulator' -ErrorAction SilentlyContinue)) {
    Write-Host 'Starting the Connect IQ simulator...' -ForegroundColor DarkGray
    Start-Process -FilePath (Join-Path $sdk 'bin\simulator.exe')
    Start-Sleep -Seconds 6
}

$results = @()

foreach ($device in $Devices) {
    Write-Host "`n=== $device ===" -ForegroundColor Cyan
    $prg = Join-Path $outDir "ZabkaFinderTest-$device.prg"

    & $monkeyc -f $jungle -o $prg -y $DeveloperKey -d $device --unit-test 2>&1 |
        Where-Object { $_ -notmatch 'WARNING' }
    if ($LASTEXITCODE -ne 0) {
        $results += [pscustomobject]@{ Device = $device; Result = 'BUILD FAILED' }
        continue
    }

    # Note: on Windows monkeydo takes slash-flags (/t), not -t.
    $output = & $monkeydo $prg $device /t 2>&1
    $output | Write-Host

    $summary = $output | Select-String -Pattern '^(PASSED|FAILED)' | Select-Object -First 1
    $results += [pscustomobject]@{
        Device = $device
        Result = if ($summary) { $summary.Line.Trim() } else { 'NO RESULT' }
    }
}

Write-Host "`n================ SUMMARY ================" -ForegroundColor Yellow
$results | Format-Table -AutoSize
if ($results | Where-Object { $_.Result -notlike 'PASSED*' }) { exit 1 }
