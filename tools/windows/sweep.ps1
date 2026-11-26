# SPDX-License-Identifier: GPL-2.0-only
# Sweep the default render endpoint volume 0..100..0 in 1 % steps and log what
# Windows reports for each step. Run inside a USBPcap capture (tools\windows\cap.ps1).
#   powershell -ExecutionPolicy Bypass -File tools\windows\sweep.ps1
param([int]$DelayMs = 300, [int]$Restore = 60)

$code = @'
using System;
using System.Runtime.InteropServices;

[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume {
    // Method order must match the vtable exactly.
    int RegisterControlChangeNotify(IntPtr pNotify);
    int UnregisterControlChangeNotify(IntPtr pNotify);
    int GetChannelCount(out uint pnChannelCount);
    int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
    int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
    int GetMasterVolumeLevel(out float pfLevelDB);
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
    int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
    int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
    int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
    int GetVolumeStepInfo(out uint pnStep, out uint pnStepCount);
    int VolumeStepUp(ref Guid pguidEventContext);
    int VolumeStepDown(ref Guid pguidEventContext);
    int QueryHardwareSupport(out uint pdwHardwareSupportMask);
    int GetVolumeRange(out float pflVolumeMindB, out float pflVolumeMaxdB, out float pflVolumeIncrementdB);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
    int GetState(out int pdwState);
}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

public static class Vol {
    public static IAudioEndpointVolume Default(out string id) {
        var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        IMMDevice dev;
        Marshal.ThrowExceptionForHR(e.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out dev));
        Marshal.ThrowExceptionForHR(dev.GetId(out id));
        var iid = typeof(IAudioEndpointVolume).GUID;
        object o;
        Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out o));
        return (IAudioEndpointVolume)o;
    }
    // PowerShell sees the interface as a bare __ComObject: it can neither call its methods
    // nor pass it back into C#. So the endpoint lives in a static field and PowerShell only
    // calls these static wrappers.
    static IAudioEndpointVolume ep;
    static Guid ctx = Guid.Empty;
    public static string Open() { string id; ep = Default(out id); return id; }
    public static void SetScalar(float f) { Marshal.ThrowExceptionForHR(ep.SetMasterVolumeLevelScalar(f, ref ctx)); }
    public static float GetScalar() { float f; Marshal.ThrowExceptionForHR(ep.GetMasterVolumeLevelScalar(out f)); return f; }
    public static float GetDb() { float f; Marshal.ThrowExceptionForHR(ep.GetMasterVolumeLevel(out f)); return f; }
    public static float[] Range() { float a, b, c; Marshal.ThrowExceptionForHR(ep.GetVolumeRange(out a, out b, out c)); return new float[] { a, b, c }; }
    public static uint HwSupport() { uint m; Marshal.ThrowExceptionForHR(ep.QueryHardwareSupport(out m)); return m; }
}
'@
Add-Type -TypeDefinition $code

$id = [Vol]::Open()
$mn, $mx, $inc = [Vol]::Range()
$hw = [Vol]::HwSupport()
"endpoint: $id"
"range: $mn .. $mx dB, increment $inc dB, hw support mask 0x{0:x}" -f $hw

# <repo>\tools\windows -> <repo>
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out = Join-Path $root 'captures\sweep-volumes.csv'
'direction,percent,scalar_readback,db_readback' | Out-File $out -Encoding ascii
$steps = @(0..100) + @(99..0)
$dir = 'up'
foreach ($p in $steps) {
    if ($p -eq 99 -and $dir -eq 'up' -and $prev -eq 100) { $dir = 'down' }
    [Vol]::SetScalar([float]($p / 100.0))
    Start-Sleep -Milliseconds $DelayMs
    $s = [Vol]::GetScalar(); $db = [Vol]::GetDb()
    # invariant culture so the CSV gets dots, not the system's decimal commas
    ("{0},{1},{2},{3}" -f $dir, $p, $s.ToString([cultureinfo]::InvariantCulture), $db.ToString([cultureinfo]::InvariantCulture)) | Out-File $out -Append -Encoding ascii
    $prev = $p
}
[Vol]::SetScalar([float]($Restore / 100.0))
"done, restored $Restore %, log: $out"
