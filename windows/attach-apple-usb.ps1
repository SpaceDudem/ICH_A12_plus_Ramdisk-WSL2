[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Fail 'usbipd-win is not installed or usbipd.exe is not on PATH.'
}

$service = Get-Service usbipd -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Running') {
    try {
        Start-Service usbipd
    }
    catch {
        Fail 'The usbipd service is stopped and could not be started. Re-run this once from elevated PowerShell.'
    }
}

$list = (& usbipd list 2>&1 | Out-String)
$line = $list -split "`r?`n" | Where-Object { $_ -match '(?i)05ac:(1227|1281)' } | Select-Object -First 1

if (-not $line) {
    Write-Host 'No Apple DFU/Recovery USB device found.'
    Write-Host 'Expected VID:PID: 05ac:1227 (DFU) or 05ac:1281 (Recovery).'
    exit 2
}

if ($line -notmatch '^\s*(\S+)') {
    Fail "Could not parse BUSID from usbipd output: $line"
}

$busid = $Matches[1]
Write-Host "Apple USB device: $line"
Write-Host "BUSID: $busid"

if ($line -match '(?i)not shared') {
    Write-Host 'Binding BUSID to usbipd...'
    & usbipd bind --busid $busid
    if ($LASTEXITCODE -ne 0) {
        Fail "usbipd bind failed. Binding normally requires elevated PowerShell. Run: usbipd bind --busid $busid"
    }
}

Write-Host 'Attaching Apple USB device to WSL...'
& usbipd attach --wsl --auto-attach --busid $busid
if ($LASTEXITCODE -ne 0) {
    & usbipd attach --wsl --busid $busid
}
if ($LASTEXITCODE -ne 0) {
    Fail "usbipd attach failed for BUSID $busid"
}

Write-Host 'Attached. In WSL, verify with: lsusb | grep -i 05ac'
Write-Host 'DFU -> Recovery changes the USB identity; rerun this helper if WSL loses the device during that transition.'
