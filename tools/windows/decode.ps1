# SPDX-License-Identifier: GPL-2.0-only
# Decode a GSX 1000 capture: UAC control requests (with GET responses) and HID ring events.
# Usage: powershell -File tools\windows\decode.ps1 captures\01-reconnect.pcap
param([Parameter(Mandatory)][string]$Pcap)

$tshark = "C:\Program Files\Wireshark\tshark.exe"
$fields = 'frame.number','frame.time_relative','usb.device_address','usb.endpoint_address',
          'usb.irp_info.direction','usbaudio.bRequest','usbaudio.wValue','usbaudio.wIndex',
          'usbaudio.wVolume','usb.data_fragment','usbhid.data','usb.request_in','usb.capdata','usbaudio.bMute'
$args2 = @('-r', $Pcap, '-Y', 'usb.transfer_type != 0x00', '-T', 'fields', '-E', 'separator=/t', '-E', 'occurrence=f')
foreach ($f in $fields) { $args2 += @('-e', $f) }

$req = @{ '1'='SET_CUR'; '129'='GET_CUR'; '130'='GET_MIN'; '131'='GET_MAX'; '132'='GET_RES'
          '0x01'='SET_CUR'; '0x81'='GET_CUR'; '0x82'='GET_MIN'; '0x83'='GET_MAX'; '0x84'='GET_RES' }
$pending = @{}
# wVolume comes out as raw uint16; UAC1 volume is int16 in 1/256 dB
function DB($raw) { $v = [int]$raw; if ($v -ge 32768) { $v -= 65536 }; '{0:F2} dB' -f ($v / 256) }

& $tshark @args2 | ForEach-Object {
    $c = $_ -split "`t"
    $n, $t, $addr, $ep, $dir, $br, $wv, $wi, $vol, $frag, $hid, $reqIn, $cap, $mute = $c
    $ts = '{0,9:F3}' -f [double]$t

    if ($hid -or ($ep -eq '0x82' -and $cap)) {
        $d = if ($hid) { $hid } else { $cap }
        $bits = if ($d.Length -ge 4 -and $d.Substring(0,2) -eq '02') {
            $b = [Convert]::ToInt32($d.Substring(2,2),16)
            $s = @(); if ($b -band 1) { $s += 'Vol+' }; if ($b -band 2) { $s += 'Vol-' }; if ($b -band 4) { $s += 'Mute' }
            if ($s) { $s -join '+' } else { 'release' }
        } else { "report $d" }
        "$ts  a$addr  HID   $bits"
        return
    }
    if ($br) {
        $wvI = [Convert]::ToInt32($wv,16); $wiI = [Convert]::ToInt32($wi,16)
        $cs = switch ($wvI -shr 8) { 1 {'MUTE'} 2 {'VOL'} default {"cs$($wvI -shr 8)"} }
        $target = "unit{0}/if{1} {2} ch{3}" -f ($wiI -shr 8), ($wiI -band 0xff), $cs, ($wvI -band 0xff)
        $name = $req[$br]; if (-not $name) { $name = "req$br" }
        if ($name -eq 'SET_CUR') {
            $val = if ($vol) { DB $vol } elseif ($frag) { "data $frag" } else { '' }
            "$ts  a$addr  $name $target = $val"
        } else {
            $pending[$n] = "$ts  a$addr  $name $target"
        }
        return
    }
    if ($reqIn -and $pending.ContainsKey($reqIn)) {
        $val = if ($vol) { DB $vol } elseif ($mute) { "mute=$mute" } elseif ($cap) { "data $cap" } elseif ($frag) { "data $frag" } else { '?' }
        "$($pending[$reqIn]) -> $val"
        $pending.Remove($reqIn)
    }
}
