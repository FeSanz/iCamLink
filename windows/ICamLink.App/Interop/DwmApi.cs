using System.Runtime.InteropServices;

namespace ICamLink.App.Interop;

/// <summary>Dark title bar to match the dark theme (silently no-ops on Windows builds that don't support it).</summary>
internal static class DwmApi
{
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int dwAttribute, ref int pvAttribute, int cbAttribute);

    public static void SetImmersiveDarkMode(IntPtr hwnd, bool dark)
    {
        var value = dark ? 1 : 0;
        try { DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref value, sizeof(int)); }
        catch (DllNotFoundException) { }
    }
}
