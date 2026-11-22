using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;

namespace Madi;

/// <summary>
/// 창 바깥에서 오는 것 — 두 번째로 켠 마디가 넘긴 파일 · 링크(<see cref="SingleInstance"/>), <c>madi://</c> 링크(<see cref="MadiUrl"/>),
/// 켤 때의 새 판 확인. 링크를 실행하는 규칙은 macOS판 <c>URLCommandRunner</c>와 같다: 여는 것(<c>open</c>)과 새 문서(<c>new</c>)는
/// 파일을 바꾸지 않으므로 묻지 않고, 파일을 바꾸는 <c>append</c>는 그 창에서 더할 글을 보이고 묻는다(기본 단추는 <c>아니요</c> — 링크가
/// 열린 순간 치던 Enter가 더하기를 누르지 않게). 링크는 웹 페이지도 누를 수 있다.
/// </summary>
public sealed partial class MainWindow
{
    /// <summary>확인 실행 중 — 어느 창이든 닫을 때 묻지 않고, 오류는 창 대신 기록에(<see cref="SmokeNotes"/>).</summary>
    internal static bool SmokeMode { get; set; }

    internal static readonly List<string> SmokeNotes = [];

    /// <summary>모든 창의 편집기 메시지를 본다 — 확인 실행이 다른 창(링크로 연 창)을 지켜볼 때.</summary>
    internal static Action<MainWindow, JsonElement>? Observer { get; set; }

    /// <summary>링크의 글 더하기를 묻는 대신 — 확인 실행이 답한다(파일 이름, 더할 글 → 더할지).</summary>
    internal static Func<string, string, bool>? ConfirmAppendOverride { get; set; }

    private static bool launchChecked;
    private readonly List<Action<MainWindow>> afterLoad = [];

    internal static IReadOnlyList<MainWindow> OpenWindows => Windows;

    internal static MainWindow? FindWindow(string full) =>
        Windows.FirstOrDefault(window => string.Equals(window.path, full, StringComparison.OrdinalIgnoreCase));

    /// <summary>넘겨받은 일을 할 창 — 맨 나중에 앞에 있던 창.</summary>
    private static MainWindow? Primary => Windows.FirstOrDefault(window => window.IsActive) ?? Windows.LastOrDefault();

    private static void Bring(MainWindow window)
    {
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    /// <summary>파일이 실린 창이면 곧, 아니면 실린 뒤에.</summary>
    internal void WhenLoaded(Action<MainWindow> action)
    {
        if (editorReady && pendingOpen is null && (options.FilePath is null || path is not null)) action(this);
        else afterLoad.Add(action);
    }

    /// <summary>편집기가 뜨고 첫 파일까지 실린 뒤 — 기다리던 일, 켤 때 받은 링크, 하루 한 번의 새 판 확인.</summary>
    private async Task ReadyAsync()
    {
        foreach (var action in afterLoad.ToList()) action(this);
        afterLoad.Clear();
        foreach (var url in options.Urls) await RunLinkAsync(url);
        if (!launchChecked && !SmokeMode)
        {
            launchChecked = true;
            Updates.CheckAtLaunch(this);
        }
    }

    /// <summary>두 번째로 켠 마디가 넘긴 것 — 경로와 링크. 아무것도 없으면(그냥 다시 켬) 새 창.</summary>
    internal static async Task HandleForwardedAsync(IReadOnlyList<string> items)
    {
        var target = Primary;
        if (target is null) return;
        var files = items.Where(item => !MadiUrl.IsMadiUrl(item) && item != SingleInstance.NewWindow).ToList();
        var urls = items.Where(MadiUrl.IsMadiUrl).ToList();
        if (files.Count == 0 && urls.Count == 0)
        {
            OpenWindow(null);
            return;
        }
        foreach (var file in files)
        {
            if (File.Exists(file)) target.OpenPath(file);
            else target.ShowError($"파일이 없습니다: {file}");
        }
        foreach (var url in urls) await target.RunLinkAsync(url);
    }

    // MARK: madi://

    internal async Task RunLinkAsync(string url)
    {
        MadiUrl.Command command;
        try
        {
            command = MadiUrl.Parse(url, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        }
        catch (MadiUrl.Failure failure)
        {
            LinkFailed(failure.Message);
            return;
        }
        switch (command)
        {
            case MadiUrl.Open open:
                if (!File.Exists(open.Path))
                {
                    LinkFailed($"파일이 없습니다: {open.Path}");
                    return;
                }
                OpenPath(open.Path, window =>
                {
                    if (open.Line is { } line) window.Run("goToLine", line.ToString(System.Globalization.CultureInfo.InvariantCulture));
                    if (open.Search is { } search) window.Run("search", search);
                });
                break;

            case MadiUrl.New { Path: { } file } created:
                await CreateFileAsync(file, MadiUrl.NewDocumentText(created.Text, created.Title, asFile: true));
                break;

            case MadiUrl.New created:
                var text = MadiUrl.NewDocumentText(created.Text, created.Title, asFile: false);
                OpenWindow(null, window =>
                {
                    // 글이 있으면 고친 상태 — 닫을 때 묻는다. 빈 새 문서는 평소의 새 문서와 같다.
                    if (text.Length > 0) window.Post(new { type = "compose", text });
                });
                break;

            case MadiUrl.Append append:
                if (!File.Exists(append.Path))
                {
                    LinkFailed($"파일이 없습니다: {append.Path}");
                    return;
                }
                OpenPath(append.Path, window =>
                {
                    if (window.ConfirmAppend(append.Path, append.Text)) window.Run("appendText", append.Text);
                });
                break;
        }
    }

    /// <summary><c>new?path=…</c> — 그 자리에 새 파일을 만들고 연다. 있는 파일은 덮지 않고(쓸 때도 <c>CreateNew</c>), 폴더는 만들지 않는다.</summary>
    private async Task CreateFileAsync(string file, string text)
    {
        if (File.Exists(file))
        {
            LinkFailed($"이미 있는 파일이라 덮어쓰지 않습니다: {file}\n끝에 더하려면 madi://append를 씁니다.");
            return;
        }
        var folder = Path.GetDirectoryName(file);
        if (folder is null || !Directory.Exists(folder))
        {
            LinkFailed($"폴더가 없습니다: {folder}");
            return;
        }
        try
        {
            await using var stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            await stream.WriteAsync(new System.Text.UTF8Encoding(false).GetBytes(text));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LinkFailed($"파일을 만들지 못했습니다: {error.Message}");
            return;
        }
        OpenPath(file, window => window.Run("caretEnd"));
    }

    private bool ConfirmAppend(string file, string text)
    {
        if (ConfirmAppendOverride is { } answer) return answer(file, text);
        var preview = text.Length > 400 ? text[..400] + "…" : text;
        var result = MessageBox.Show(this, $"링크가 이 문서 끝에 글을 더하려 합니다.\n\n{Path.GetFileName(file)}에 더할 글:\n\n{preview}\n\n더할까요?",
            "마디", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
        return result == MessageBoxResult.Yes;
    }

    private void LinkFailed(string message) => ShowError($"madi:// 링크를 열 수 없습니다.\n{message}");

    // MARK: 도구 · 도움말

    /// <summary>Windows 설정 ▸ 기본 앱의 마디 쪽(설치 파일이 <c>RegisteredApplications</c>에 <c>Madi</c>로 올린다).</summary>
    private void OpenDefaultAppsSettings()
    {
        try
        {
            Process.Start(new ProcessStartInfo("ms-settings:defaultapps?registeredAppUser=Madi") { UseShellExecute = true });
        }
        catch (System.ComponentModel.Win32Exception error)
        {
            ShowError($"설정을 열지 못했습니다: {error.Message}");
        }
    }

    private void ShowAbout()
    {
        var webView2 = editorReady ? Core.Environment.BrowserVersionString : "(아직 뜨지 않음)";
        MessageBox.Show(this,
            $"마디 Windows판 {Updates.Current}\nWebView2 {webView2}\n\n" +
            $"포함된 오픈 소스와 라이선스: {Path.Combine(AppContext.BaseDirectory, "editor", "THIRD-PARTY.txt")}\n" +
            "글꼴: Pretendard · IBM Plex Mono(SIL OFL 1.1)\n\ngithub.com/ddiiwoong/madi",
            "마디 정보", MessageBoxButton.OK, MessageBoxImage.Information);
    }
}
