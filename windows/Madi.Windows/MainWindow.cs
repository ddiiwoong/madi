using System.IO;
using System.Text.Json;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Madi;

/// <summary>
/// 문서 창 — WebView2 하나에 편집기(<c>windows/editor</c>)를 띄운다. 편집기는 exe 옆의 <c>editor\</c> 폴더를
/// <c>https://app.madi/</c>로 연다(가상 호스트). 바깥 주소로는 가지 않고, 호스트 객체는 열지 않으며, 주고받는 것은 웹 메시지뿐이다.
/// </summary>
public sealed class MainWindow : Window
{
    internal const string AppHost = "app.madi";

    private readonly WebView2 webView = new();
    private readonly LaunchOptions options;
    private readonly SmokeRun? smoke;
    private TaskCompletionSource<JsonElement>? pendingOpen;

    /// <summary>프로세스의 끝 코드. 확인 실행이 정한다(0 통과, 1 실패, 2 시간 넘김 · 시작 못 함).</summary>
    public int ExitCode { get; private set; }

    public MainWindow(LaunchOptions options)
    {
        this.options = options;
        Title = "마디";
        Width = 1100;
        Height = 800;
        MinWidth = 520;
        MinHeight = 380;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = webView;
        if (options.SmokeDirectory is { } directory) smoke = new SmokeRun(this, directory);
        Loaded += async (_, _) => await StartAsync();
    }

    internal CoreWebView2 Core => webView.CoreWebView2;

    private async Task StartAsync()
    {
        smoke?.StartWatchdog();
        try
        {
            // 사용자 데이터(캐시 · 설정)를 exe 옆에 두지 않는다 — Program Files에 설치하면 쓸 수 없다.
            var dataFolder = smoke is not null
                ? Path.Combine(options.SmokeDirectory!, "webview2-data")
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Madi", "WebView2");
            var environment = await CoreWebView2Environment.CreateAsync(null, dataFolder);
            await webView.EnsureCoreWebView2Async(environment);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            Fail("Microsoft Edge WebView2 런타임이 없습니다. https://developer.microsoft.com/microsoft-edge/webview2/ 에서 " +
                 "'Evergreen Bootstrapper'를 받아 설치한 뒤 다시 엽니다.");
            return;
        }
        catch (Exception error)
        {
            Fail($"편집기를 띄우지 못했습니다: {error.Message}");
            return;
        }

        var settings = Core.Settings;
        settings.AreHostObjectsAllowed = false;
        settings.IsWebMessageEnabled = true;
        settings.IsGeneralAutofillEnabled = false;
        settings.IsPasswordAutosaveEnabled = false;
        settings.IsStatusBarEnabled = false;
        // 브라우저의 단축키(F5 새로 고침 · Ctrl+F · Ctrl+P)를 끈다 — 새로 고침은 고친 글을 버린다. 편집 키(Ctrl+C · V · Z)는 그대로다.
        settings.AreBrowserAcceleratorKeysEnabled = false;
#if !DEBUG
        settings.AreDevToolsEnabled = false;
#endif

        var editorFolder = Path.Combine(AppContext.BaseDirectory, "editor");
        if (!File.Exists(Path.Combine(editorFolder, "index.html")))
        {
            Fail($"편집기 파일이 없습니다: {editorFolder}");
            return;
        }
        Core.SetVirtualHostNameToFolderMapping(AppHost, editorFolder, CoreWebView2HostResourceAccessKind.Deny);
        Core.NavigationStarting += (_, e) =>
        {
            if (!IsAppUri(e.Uri)) e.Cancel = true;
        };
        Core.NewWindowRequested += (_, e) => e.Handled = true;
        Core.WebMessageReceived += OnWebMessage;
        Core.Navigate($"https://{AppHost}/index.html");
    }

    private static bool IsAppUri(string uri) =>
        Uri.TryCreate(uri, UriKind.Absolute, out var parsed)
        && parsed.Scheme == Uri.UriSchemeHttps
        && string.Equals(parsed.Host, AppHost, StringComparison.OrdinalIgnoreCase);

    private async void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!IsAppUri(e.Source)) return;
        try
        {
            using var document = JsonDocument.Parse(e.WebMessageAsJson);
            var message = document.RootElement.Clone();
            var type = message.TryGetProperty("type", out var value) ? value.GetString() : null;
            switch (type)
            {
                case "ready":
                    if (smoke is not null) await smoke.RunAsync(message);
                    else if (options.FilePath is { } path) await OpenAsync(path);
                    break;
                case "opened":
                case "error":
                    if (pendingOpen is { } pending)
                    {
                        pendingOpen = null;
                        pending.TrySetResult(message);
                    }
                    break;
            }
        }
        catch (Exception error)
        {
            Fail($"편집기와 주고받다 오류가 났습니다: {error.Message}");
        }
    }

    /// <summary>파일을 읽어 편집기에 넘긴다. 글로 읽는 일(인코딩 · BOM · 줄 끝)은 편집기가 한다.</summary>
    private async Task OpenAsync(string path)
    {
        byte[] bytes;
        try
        {
            bytes = await File.ReadAllBytesAsync(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            ShowError($"파일을 열지 못했습니다: {path}\n{error.Message}");
            return;
        }
        var reply = await SendOpenAsync(path, bytes);
        if (reply.GetProperty("type").GetString() == "error")
        {
            ShowError($"파일을 열지 못했습니다: {path}\n{reply.GetProperty("message").GetString()}");
            return;
        }
        Title = $"{Path.GetFileName(path)} - 마디";
    }

    /// <summary>편집기에 바이트를 넘기고 답(<c>opened</c> · <c>error</c>)을 기다린다.</summary>
    internal Task<JsonElement> SendOpenAsync(string path, byte[] bytes)
    {
        pendingOpen?.TrySetCanceled();
        var pending = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pendingOpen = pending;
        var message = JsonSerializer.Serialize(new
        {
            type = "open",
            path,
            name = Path.GetFileName(path),
            bytes = Convert.ToBase64String(bytes),
        });
        Core.PostWebMessageAsJson(message);
        return pending.Task;
    }

    /// <summary>끝 코드를 정하고, <paramref name="hold"/>만큼 보인 뒤 닫는다(CI가 그동안 화면을 찍는다).</summary>
    internal async void Finish(int exitCode, TimeSpan hold)
    {
        ExitCode = exitCode;
        if (hold > TimeSpan.Zero) await Task.Delay(hold);
        Close();
    }

    private void Fail(string message)
    {
        if (smoke is not null)
        {
            smoke.WriteFailure(message);
            Finish(2, TimeSpan.Zero);
            return;
        }
        ShowError(message);
        Close();
    }

    private void ShowError(string message) =>
        MessageBox.Show(this, message, "마디", MessageBoxButton.OK, MessageBoxImage.Error);
}
