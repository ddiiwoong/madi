using System.Runtime.InteropServices;

namespace Madi;

/// <summary>
/// 클립보드에 글을 넣는다 — Win32를 바로(<c>OpenClipboard</c> · <c>SetClipboardData(CF_UNICODETEXT)</c>), Chromium과 같은 길.
///
/// WPF의 <c>Clipboard.SetText</c>는 OLE 클립보드(<c>OleSetClipboard</c> → <c>OleFlushClipboard</c>)라 글을 나중에 그려 준다. 클립보드를
/// 지켜보는 프로그램(가상 머신의 클립보드 공유 같은 것)이 바뀐 것을 보자마자 읽으려 들면, 그 읽기는 마디의 UI 스레드가 그려 줘야
/// 끝나는데 WPF는 그 스레드에서 잠들며 다시 해 보기를 되풀이해 <c>CLIPBRD_E_CANT_OPEN</c>으로 끝났다(사용자 — "복사하면 빨간 에러남",
/// Ctrl+C는 됐다). 여기서는 글을 바로 넣고 바로 닫는다 — 기다릴 것이 없다.
/// </summary>
internal static class TextClipboard
{
    private const uint UnicodeText = 13; // CF_UNICODETEXT
    private const uint Moveable = 0x0002; // GMEM_MOVEABLE

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr owner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint format, IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr memory);

    /// <summary>
    /// <paramref name="owner"/>는 창의 핸들 — 없으면(<c>IntPtr.Zero</c>) <c>EmptyClipboard</c>가 주인을 비워 <c>SetClipboardData</c>가
    /// 실패한다. 다른 프로그램이 클립보드를 열고 있으면 잠깐씩 쉬며 다시 연다(합쳐 0.4초까지). 넣었으면 null, 못 넣었으면 까닭.
    /// </summary>
    public static string? SetText(IntPtr owner, string text)
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            if (!OpenClipboard(owner))
            {
                Thread.Sleep(20);
                continue;
            }
            try
            {
                if (!EmptyClipboard()) return $"클립보드를 비우지 못했습니다(Win32 {Marshal.GetLastWin32Error()})";
                if (text.Length == 0) return null;
                var memory = GlobalAlloc(Moveable, (UIntPtr)((text.Length + 1) * sizeof(char)));
                if (memory == IntPtr.Zero) return "클립보드에 넣을 메모리를 잡지 못했습니다";
                var pointer = GlobalLock(memory);
                if (pointer == IntPtr.Zero)
                {
                    GlobalFree(memory);
                    return "클립보드에 넣을 메모리를 잡지 못했습니다";
                }
                Marshal.Copy(text.ToCharArray(), 0, pointer, text.Length);
                Marshal.WriteInt16(pointer, text.Length * sizeof(char), 0);
                GlobalUnlock(memory);
                if (SetClipboardData(UnicodeText, memory) == IntPtr.Zero)
                {
                    var code = Marshal.GetLastWin32Error();
                    GlobalFree(memory);
                    return $"클립보드에 넣지 못했습니다(Win32 {code})";
                }
                // 넣은 뒤로는 메모리가 시스템의 것이다 — 풀지 않는다.
                return null;
            }
            finally
            {
                CloseClipboard();
            }
        }
        return "다른 프로그램이 클립보드를 쓰고 있어 열 수 없습니다";
    }
}
