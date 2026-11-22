using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Printing;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Win32 = Microsoft.Win32;

namespace Madi;

/// <summary>
/// PDF 내보내기 — 편집기를 흰 종이 · 문서 전체로 그리게 한 뒤(<c>output begin</c> → <c>outputReady</c>) WebView2가 PDF로 쓰고, 편집기를
/// 되돌린다(<c>output end</c>). macOS판과 같은 약속: 고른 테마와 상관없이 기본 색, 캐럿 줄의 표식도 숨기고, 메타데이터는 내지 않으며,
/// 프린트와 같은 설정(용지 · 방향 · 여백). 프린트하기(Ctrl+P)는 편집기가 같은 준비를 하고 프린트 창을 띄운다(<c>window.print()</c>).
/// </summary>
public sealed partial class MainWindow
{
    private TaskCompletionSource<JsonElement>? pendingOutput;
    private int outputCounter;

    private async Task ExportPdfAsync()
    {
        if (!editorReady) return;
        await Task.Yield();
        var dialog = new Win32.SaveFileDialog
        {
            Title = "PDF 내보내기",
            FileName = Path.ChangeExtension(State.Name, ".pdf"),
            Filter = "PDF|*.pdf",
            AddExtension = true,
            DefaultExt = ".pdf",
        };
        if (path is not null) dialog.InitialDirectory = Path.GetDirectoryName(path);
        if (dialog.ShowDialog(this) != true) return;
        var pdf = Path.GetFullPath(dialog.FileName);
        if (await ExportPdfToAsync(pdf))
        {
            // 내보낸 파일을 보인다(macOS판은 Finder에서).
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{pdf}\"") { UseShellExecute = true });
        }
    }

    /// <summary>쓴 쪽 수를 셀 수 있게 결과를 돌려준다(확인 실행).</summary>
    internal async Task<bool> ExportPdfToAsync(string pdf)
    {
        var pending = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pendingOutput = pending;
        Post(new { type = "output", action = "begin", id = ++outputCounter });
        var temp = Path.Combine(Path.GetDirectoryName(pdf)!, $".{Path.GetFileName(pdf)}.{Guid.NewGuid():N}.madi-tmp");
        try
        {
            await pending.Task.WaitAsync(TimeSpan.FromSeconds(60));
            var layout = PrintLayout.From(Store.Text("printPaper"), Store.Text("printOrientation"), Store.Text("printMargin"),
                SystemPaper(), RegionInfo.CurrentRegion);
            var settings = Core.Environment.CreatePrintSettings();
            settings.Orientation = layout.Landscape ? CoreWebView2PrintOrientation.Landscape : CoreWebView2PrintOrientation.Portrait;
            settings.PageWidth = layout.PageWidth;
            settings.PageHeight = layout.PageHeight;
            settings.MarginTop = settings.MarginBottom = settings.MarginLeft = settings.MarginRight = layout.Margin;
            settings.ShouldPrintBackgrounds = true;
            settings.ShouldPrintHeaderAndFooter = false;
            // 같은 폴더의 임시 파일에 다 쓴 뒤 바꿔 넣는다 — 쓰다 멈춰도 반쯤 쓴 PDF가 남지 않게.
            if (!await Core.PrintToPdfAsync(temp, settings)) throw new IOException("WebView2가 PDF를 쓰지 못했습니다");
            File.Move(temp, pdf, overwrite: true);
            return true;
        }
        catch (Exception error) when (error is TimeoutException or IOException or UnauthorizedAccessException or ArgumentException
                                          or System.Runtime.InteropServices.COMException)
        {
            ShowError($"PDF 내보내기에 실패했습니다: {pdf}\n{error.Message}");
            return false;
        }
        finally
        {
            pendingOutput = null;
            if (File.Exists(temp)) File.Delete(temp);
            Post(new { type = "output", action = "end" });
        }
    }

    /// <summary>기본 프린터의 용지(세로, 인치) — 설정이 <c>시스템 기본</c>일 때. 프린터가 없거나 읽지 못하면 null(지역에 맞춘다).</summary>
    private static (double Width, double Height)? SystemPaper()
    {
        try
        {
            using var queue = LocalPrintServer.GetDefaultPrintQueue();
            var size = queue.DefaultPrintTicket?.PageMediaSize;
            if (size?.Width is double width && size.Height is double height && width > 0 && height > 0) return (width / 96, height / 96);
        }
        catch (Exception error) when (error is PrintSystemException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // 프린터가 없다(CI) · 스풀러가 꺼졌다.
        }
        return null;
    }
}
