using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Madi;

/// <summary>
/// 창 테두리 — 제목 막대를 마디가 그리므로(<see cref="TitleBar"/>) Windows가 그리던 것 가운데 몇을 맞춘다: Windows 11의 둥근 모서리,
/// 다크 테마의 창 테두리 색, 최대화했을 때 화면 밖으로 나가는 테두리 폭. 확인 실행이 쓰는 것(가리키는 자리의 판정 · 창 화면 찍기)도 여기.
/// </summary>
internal static class WindowFrame
{
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmwaBorderColor = 34;
    private const int DwmwaExtendedFrameBounds = 9;
    private const int DwmwcpRound = 2;
    private const int SmCxSizeFrame = 32;
    private const int SmCxPaddedBorder = 92;
    private const int WmNcHitTest = 0x0084;

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public Rect Monitor;
        public Rect Work;
        public int Flags;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out Rect value, int size);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, int flags);

    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr dc, IntPtr item);

    [DllImport("gdi32.dll")]
    private static extern bool BitBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, int operation);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr item);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr dc);

    /// <summary>둥근 모서리(Windows 11 — 그보다 옛 판은 무시한다), 다크면 어두운 창 틀, 테두리 색은 테마의 선 색.</summary>
    public static void Apply(Window window, ChromeColors colors)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        var round = DwmwcpRound;
        DwmSetWindowAttribute(hwnd, DwmwaWindowCornerPreference, ref round, sizeof(int));
        var dark = colors.Dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));
        var border = colors.Tint(colors.Dark ? 0.16 : 0.14);
        var colorRef = border.R | (border.G << 8) | (border.B << 16);
        DwmSetWindowAttribute(hwnd, DwmwaBorderColor, ref colorRef, sizeof(int));
    }

    /// <summary>
    /// 최대화한 창은 테두리 폭만큼 화면 밖으로 나간다(Windows가 테두리를 화면 밖에 둔다) — 그만큼 안쪽에 둔다. 장치 독립 단위.
    /// </summary>
    public static Thickness MaximizedInset(Window window)
    {
        var dpi = VisualTreeHelper.GetDpi(window);
        var pixels = (uint)Math.Round(dpi.PixelsPerInchX);
        try
        {
            var frame = GetSystemMetricsForDpi(SmCxSizeFrame, pixels) + GetSystemMetricsForDpi(SmCxPaddedBorder, pixels);
            return new Thickness(frame / dpi.DpiScaleX);
        }
        catch (EntryPointNotFoundException)
        {
            return new Thickness(8);
        }
    }

    /// <summary>화면의 한 점(물리 화소)에서 창이 무엇이라고 답하는가 — <c>WM_NCHITTEST</c>(1 글 영역, 2 제목, 12 위 테두리 …).</summary>
    public static int HitTest(Window window, Point screen)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        var lParam = ((int)screen.Y << 16) | ((int)screen.X & 0xFFFF);
        return (int)SendMessage(hwnd, WmNcHitTest, IntPtr.Zero, new IntPtr(lParam)).ToInt64();
    }

    /// <summary>창이 있는 모니터의 작업 영역(작업 표시줄을 뺀 곳, 물리 화소).</summary>
    public static System.Windows.Rect WorkArea(Window window)
    {
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        GetMonitorInfo(MonitorFromWindow(new WindowInteropHelper(window).Handle, 2), ref info);
        return new System.Windows.Rect(info.Work.Left, info.Work.Top, info.Work.Right - info.Work.Left, info.Work.Bottom - info.Work.Top);
    }

    /// <summary>창을 화면에서 찍는다(보이는 테두리 안 — 제목 막대까지). 편집기(WebView2)는 다른 창이라 WPF의 그림으로는 찍히지 않는다.</summary>
    public static void Capture(Window window, string path)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (DwmGetWindowAttribute(hwnd, DwmwaExtendedFrameBounds, out var bounds, Marshal.SizeOf<Rect>()) != 0) GetWindowRect(hwnd, out bounds);
        var width = bounds.Right - bounds.Left;
        var height = bounds.Bottom - bounds.Top;
        var screen = GetDC(IntPtr.Zero);
        var memory = CreateCompatibleDC(screen);
        var bitmap = CreateCompatibleBitmap(screen, width, height);
        var old = SelectObject(memory, bitmap);
        try
        {
            BitBlt(memory, 0, 0, width, height, screen, bounds.Left, bounds.Top, 0x00CC0020 /* SRCCOPY */);
            SelectObject(memory, old);
            var source = Imaging.CreateBitmapSourceFromHBitmap(bitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(source));
            using var stream = File.Create(path);
            encoder.Save(stream);
        }
        finally
        {
            DeleteObject(bitmap);
            DeleteDC(memory);
            ReleaseDC(IntPtr.Zero, screen);
        }
    }
}
