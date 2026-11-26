# SPDX-License-Identifier: GPL-2.0-only
# Start/stop a USBPcap capture of the GSX 1000.
#   powershell -File tools\windows\cap.ps1 start 02-ring-down
#   powershell -File tools\windows\cap.ps1 stop   # stops, then writes captures\<name>.txt via decode.ps1
param([Parameter(Mandatory)][ValidateSet('start','stop')][string]$Action, [string]$Name)

# <repo>\tools\windows -> <repo>
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$caps = Join-Path $root 'captures'
$state = Join-Path $caps '.capture.state'
$cmd = 'C:\Program Files\USBPcap\USBPcapCMD.exe'
if (-not (Test-Path $caps)) { New-Item -ItemType Directory -Path $caps | Out-Null }

if ($Action -eq 'start') {
    if (-not $Name) { throw 'Name required' }
    if (Test-Path $state) { throw "Capture already running: $(Get-Content $state)" }
    $out = Join-Path $caps "$Name.pcap"
    if (Test-Path $out) { throw "$out already exists" }
    # find the hub and device id that hold the GSX
    $hub = $null; $dev = $null
    foreach ($i in 1..10) {
        $h = "\\.\USBPcap$i"
        # plain `$x = & cmd` sometimes captures nothing from USBPcapCMD; going through a pipeline works
        $cfg = @(& $cmd --extcap-interface $h --extcap-config | ForEach-Object { $_ })
        $line = $cfg | Where-Object { $_ -match '\{arg=99\}\{value=(\d+)_\d+\}\{display=EPOS GSX' } | Select-Object -First 1
        if ($line -and $line -match '\{value=(\d+)_') { $hub = $h; $dev = $Matches[1]; break }
    }
    if (-not $hub) { throw 'GSX 1000 not found on any USBPcap hub' }
    $p = Start-Process -FilePath $cmd -PassThru -WindowStyle Hidden -ArgumentList `
        '-d', $hub, '--devices', $dev, '--capture-from-new-devices', '--inject-descriptors', '-s', '65535', '-o', $out
    Start-Sleep 1
    if ($p.HasExited) { throw 'USBPcapCMD exited immediately' }
    "$($p.Id)|$Name" | Out-File $state -Encoding ascii
    "capturing $Name on $hub device $dev (pid $($p.Id))"
} else {
    if (-not (Test-Path $state)) { throw 'No capture running' }
    $procId, $n = (Get-Content $state) -split '\|'
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    Remove-Item $state
    $pcap = Join-Path $caps "$n.pcap"
    & (Join-Path $PSScriptRoot 'decode.ps1') $pcap | Out-File (Join-Path $caps "$n.txt") -Encoding utf8
    "stopped $n, $((Get-Item $pcap).Length) bytes"
}
