using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Win32 = Microsoft.Win32;

namespace Madi;

/// <summary>편집기가 알려 준 문서의 상태(<c>state</c> 메시지).</summary>
public sealed record DocumentState(string Name, string? Path, bool Dirty, bool Conflict, bool Source, bool Follow, bool Outline)
{
    public static readonly DocumentState Untitled = new("제목 없음", null, false, false, false, false, false);
}

/// <summary>
/// 문서 창 하나 — 메뉴와 WebView2. 편집기(<c>windows/editor</c>)는 exe 옆의 <c>editor\</c> 폴더를 <c>https://app.madi/</c>로
/// 연다(가상 호스트). 바깥 주소로는 가지 않고, 호스트 객체는 열지 않으며, 주고받는 것은 웹 메시지뿐이다.
///
/// 이 창이 하는 일: 파일을 읽고 쓰기(같은 폴더의 임시 파일을 거쳐), 파일 지켜보기(<see cref="FileWatcher"/> ·
/// <see cref="DiskBaseline"/>), 열기 · 저장 창, 닫을 때 묻기. 글로 읽는 일 · 고친 상태 · 자동 저장은 편집기가 한다.
/// </summary>
public sealed class MainWindow : Window
{
    internal const string AppHost = "app.madi";
    private static readonly List<MainWindow> Windows = [];
    private static Task<CoreWebView2Environment>? environment;

    private readonly WebView2 webView = new();
    private readonly LaunchOptions options;
    private readonly SmokeRun? smoke;
    private readonly MenuItem sourceItem;
    private readonly MenuItem followItem;
    private readonly MenuItem outlineItem;

    private string? path;
    private DiskBaseline? baseline;
    private FileWatcher? watcher;
    private bool editorReady;
    private bool closeConfirmed;
    private TaskCompletionSource<JsonElement>? pendingOpen;
    private TaskCompletionSource<bool>? pendingSave;

    internal DocumentState State { get; private set; } = DocumentState.Untitled;

    /// <summary>프로세스의 끝 코드. 확인 실행이 정한다(0 통과, 1 실패, 2 시간 넘김 · 시작 못 함).</summary>
    public int ExitCode { get; private set; }

    internal string? FilePath => path;

    public MainWindow(LaunchOptions options)
    {
        this.options = options;
        Title = "제목 없음 - 마디";
        // 화면이 작으면(CI는 1024×768) 그 안에 든다.
        var area = SystemParameters.WorkArea;
        Width = Math.Min(1100, area.Width * 0.92);
        Height = Math.Min(800, area.Height * 0.92);
        MinWidth = 520;
        MinHeight = 380;
        WindowStartupLocation = Windows.Count == 0 ? WindowStartupLocation.CenterScreen : WindowStartupLocation.Manual;
        if (Windows.LastOrDefault() is { } previous)
        {
            Left = previous.Left + 28;
            Top = previous.Top + 28;
        }

        var menu = new Menu();
        var file = Heading("파일(_F)");
        file.Items.Add(Item("새로 만들기(_N)", "Ctrl+N", () => OpenWindow(null)));
        file.Items.Add(Item("열기(_O)…", "Ctrl+O", ShowOpenDialog));
        file.Items.Add(new Separator());
        file.Items.Add(Item("저장(_S)", "Ctrl+S", () => Run("save")));
        file.Items.Add(Item("다른 이름으로 저장(_A)…", "Ctrl+Shift+S", () => Run("saveAs")));
        file.Items.Add(new Separator());
        file.Items.Add(Item("닫기(_C)", "Ctrl+W", Close));
        var edit = Heading("편집(_E)");
        edit.Items.Add(Item("실행 취소(_U)", "Ctrl+Z", () => Run("undo")));
        edit.Items.Add(Item("다시 실행(_R)", "Ctrl+Y", () => Run("redo")));
        edit.Items.Add(new Separator());
        edit.Items.Add(Item("모두 선택(_A)", "Ctrl+A", () => Run("selectAll")));
        edit.Items.Add(Item("찾기(_F)…", "Ctrl+F", () => Run("find")));
        var viewMenu = Heading("보기(_V)");
        outlineItem = Item("목차(_O)", "Ctrl+Shift+O", () => Run("toggleOutline"));
        sourceItem = Item("원본 보기(_S)", "Ctrl+E", () => Run("toggleSource"));
        followItem = Item("따라 보기(_L)", "Ctrl+Alt+L", () => Run("toggleFollow"));
        viewMenu.Items.Add(outlineItem);
        viewMenu.Items.Add(sourceItem);
        viewMenu.Items.Add(followItem);
        menu.Items.Add(file);
        menu.Items.Add(edit);
        menu.Items.Add(viewMenu);

        var dock = new DockPanel();
        DockPanel.SetDock(menu, Dock.Top);
        dock.Children.Add(menu);
        dock.Children.Add(webView);
        Content = dock;

        if (options.SmokeDirectory is { } directory) smoke = new SmokeRun(this, directory);
        Windows.Add(this);
        Loaded += async (_, _) => await StartAsync();
        Activated += (_, _) => CheckDisk();
        Closing += OnClosing;
        Closed += (_, _) =>
        {
            watcher?.Dispose();
            baseline?.Dispose();
            Windows.Remove(this);
        };

        MenuItem Heading(string header) => new() { Header = header };
        MenuItem Item(string header, string gesture, Action action)
        {
            var item = new MenuItem { Header = header, InputGestureText = gesture };
            item.Click += (_, _) =>
            {
                action();
                webView.Focus();
            };
            return item;
        }
    }

    internal CoreWebView2 Core => webView.CoreWebView2;

    // MARK: 띄우기

    private async Task StartAsync()
    {
        smoke?.StartWatchdog();
        try
        {
            // 창마다 따로 띄우되 브라우저 프로세스는 함께 쓴다(같은 환경). 사용자 데이터는 exe 옆에 두지 않는다 —
            // Program Files에 설치하면 쓸 수 없다.
            var dataFolder = smoke is not null
                ? Path.Combine(options.SmokeDirectory!, "webview2-data")
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Madi", "WebView2");
            environment ??= CoreWebView2Environment.CreateAsync(null, dataFolder);
            await webView.EnsureCoreWebView2Async(await environment);
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
        // 브라우저의 단축키(F5 새로 고침 · Ctrl+P …)를 끈다 — 새로 고침은 고친 글을 버린다. 편집 키(Ctrl+C · V · Z)는 그대로고,
        // Ctrl+S · O · N · W는 편집기가 받는다.
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
        var query = smoke is not null ? "?smoke=1&autosave=1500" : "";
        Core.Navigate($"https://{AppHost}/index.html{query}");
    }

    private static bool IsAppUri(string uri) =>
        Uri.TryCreate(uri, UriKind.Absolute, out var parsed)
        && parsed.Scheme == Uri.UriSchemeHttps
        && string.Equals(parsed.Host, AppHost, StringComparison.OrdinalIgnoreCase);

    // MARK: 편집기에서 온 것

    private async void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!IsAppUri(e.Source)) return;
        try
        {
            using var document = JsonDocument.Parse(e.WebMessageAsJson);
            var message = document.RootElement.Clone();
            var type = Field(message, "type");
            smoke?.Receive(message);
            switch (type)
            {
                case "ready":
                    editorReady = true;
                    if (smoke is not null) await smoke.RunAsync(message);
                    else if (options.FilePath is { } file) await LoadFileAsync(file);
                    break;
                case "opened":
                case "error":
                    if (pendingOpen is { } pending)
                    {
                        pendingOpen = null;
                        pending.TrySetResult(message);
                    }
                    else if (type == "error")
                    {
                        ShowError(Field(message, "message") ?? "편집기에서 오류가 났습니다");
                    }
                    break;
                case "state":
                    UpdateState(message);
                    break;
                case "save":
                    await SaveAsync(Bytes(message), autosave: message.TryGetProperty("autosave", out var auto) && auto.ValueKind == JsonValueKind.True);
                    break;
                case "saveAs":
                    await SaveAsAsync(Bytes(message), Field(message, "suggestedName") ?? "제목 없음.md");
                    break;
                case "command":
                    switch (Field(message, "name"))
                    {
                        case "new": OpenWindow(null); break;
                        case "open": ShowOpenDialog(); break;
                        case "close": Close(); break;
                    }
                    break;
                case "openUrl":
                    OpenUrl(Field(message, "url"));
                    break;
                case "reload":
                    if (path is not null) await LoadFileAsync(path, reload: true);
                    break;
                case "drop":
                    foreach (var dropped in e.AdditionalObjects?.OfType<CoreWebView2File>() ?? Enumerable.Empty<CoreWebView2File>())
                    {
                        OpenPath(dropped.Path);
                    }
                    break;
            }
        }
        catch (Exception error)
        {
            Fail($"편집기와 주고받다 오류가 났습니다: {error.Message}");
        }
    }

    private static string? Field(JsonElement message, string name) =>
        message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static byte[] Bytes(JsonElement message) => Convert.FromBase64String(Field(message, "bytes") ?? "");

    private void UpdateState(JsonElement message)
    {
        bool Flag(string name) => message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;
        State = new DocumentState(Field(message, "name") ?? "제목 없음", Field(message, "path"),
            Flag("dirty"), Flag("conflict"), Flag("source"), Flag("follow"), Flag("outline"));
        Title = $"{(State.Dirty ? "*" : "")}{State.Name} - 마디";
        sourceItem.IsChecked = State.Source;
        followItem.IsChecked = State.Follow;
        outlineItem.IsChecked = State.Outline;
    }

    /// <summary>메뉴에서 고른 명령을 편집기에 — 단축키는 편집기가 직접 받는다.</summary>
    internal void Run(string command)
    {
        if (!editorReady) return;
        Post(new { type = "run", command });
    }

    internal void Post(object message) => Core.PostWebMessageAsJson(JsonSerializer.Serialize(message));

    // MARK: 열기

    /// <summary>파일을 이 창에 싣는다 — 읽고, 기준을 잡고, 지켜보기 시작하고, 편집기에 넘겨 답(<c>opened</c>)을 기다린다.</summary>
    internal async Task<JsonElement?> LoadFileAsync(string file, bool reload = false)
    {
        byte[] bytes;
        try
        {
            bytes = DiskBaseline.ReadAll(file);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            ShowError($"파일을 열지 못했습니다: {file}\n{error.Message}");
            return null;
        }
        Watch(file, bytes);
        var reply = await SendOpenAsync(file, bytes, reload);
        if (Field(reply, "type") == "error")
        {
            ShowError($"파일을 열지 못했습니다: {file}\n{Field(reply, "message")}");
            return reply;
        }
        return reply;
    }

    private void Watch(string file, byte[] bytes)
    {
        path = file;
        baseline?.Dispose();
        baseline = DiskBaseline.From(bytes);
        watcher?.Dispose();
        try
        {
            watcher = new FileWatcher(file, Dispatcher, CheckDisk);
        }
        catch (Exception error) when (error is ArgumentException or IOException)
        {
            // 지켜볼 수 없는 자리(일부 네트워크 위치) — 창으로 돌아올 때만 본다.
            watcher = null;
        }
    }

    private Task<JsonElement> SendOpenAsync(string file, byte[] bytes, bool reload)
    {
        pendingOpen?.TrySetCanceled();
        var pending = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pendingOpen = pending;
        Post(new
        {
            type = "open",
            path = file,
            name = Path.GetFileName(file),
            bytes = Convert.ToBase64String(bytes),
            reason = reload ? "reload" : "open",
        });
        return pending.Task;
    }

    /// <summary>열기 창 · 끌어다 놓기 · 두 번째 실행. 이미 연 파일이면 그 창을, 이 창이 비었으면 여기에, 아니면 새 창에.</summary>
    internal void OpenPath(string file)
    {
        var full = Path.GetFullPath(file);
        if (Windows.FirstOrDefault(window => string.Equals(window.path, full, StringComparison.OrdinalIgnoreCase)) is { } open)
        {
            open.Activate();
            return;
        }
        if (path is null && !State.Dirty && editorReady) _ = LoadFileAsync(full);
        else OpenWindow(full);
    }

    private static void OpenWindow(string? file) => new MainWindow(new LaunchOptions(file, null)).Show();

    private void ShowOpenDialog()
    {
        var dialog = new Win32.OpenFileDialog
        {
            Title = "열기",
            Filter = "마크다운 · 글 · 로그|*.md;*.markdown;*.mdown;*.mkd;*.mkdn;*.mdx;*.txt;*.text;*.log|모든 파일|*.*",
            Multiselect = true,
        };
        if (path is not null) dialog.InitialDirectory = Path.GetDirectoryName(path);
        if (dialog.ShowDialog(this) != true) return;
        foreach (var file in dialog.FileNames) OpenPath(file);
    }

    private void OpenUrl(string? url)
    {
        // 문서의 링크는 남이 쓴 것일 수 있다 — 웹 주소와 메일만 연다(file: · 실행 파일은 열지 않는다).
        if (url is null || !Uri.TryCreate(url, UriKind.Absolute, out var parsed)) return;
        if (parsed.Scheme != Uri.UriSchemeHttps && parsed.Scheme != Uri.UriSchemeHttp && parsed.Scheme != Uri.UriSchemeMailto) return;
        Process.Start(new ProcessStartInfo(parsed.AbsoluteUri) { UseShellExecute = true });
    }

    // MARK: 바깥 변경

    /// <summary>지켜보는 파일을 기준과 견주고, 바뀐 것을 편집기에 넘긴다. 들일지 · 띠로 물을지는 편집기가 정한다(고친 것이 있는가).</summary>
    private void CheckDisk()
    {
        if (path is null || baseline is null || !editorReady) return;
        DiskChange change;
        try
        {
            change = baseline.Detect(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return; // 쓰는 중이라 잠겼다 — 다음 신호에 다시 본다.
        }
        switch (change.Kind)
        {
            case DiskChangeKind.Appended:
                Post(new { type = "appended", bytes = Convert.ToBase64String(change.Bytes) });
                break;
            case DiskChangeKind.Replaced:
                Post(new { type = "replaced", bytes = Convert.ToBase64String(change.Bytes) });
                break;
        }
    }

    // MARK: 저장

    private async Task SaveAsync(byte[] bytes, bool autosave)
    {
        if (path is null)
        {
            await SaveAsAsync(bytes, $"{State.Name}.md");
            return;
        }
        Write(path, bytes, autosave);
    }

    private async Task SaveAsAsync(byte[] bytes, string suggestedName)
    {
        await Task.Yield();
        var dialog = new Win32.SaveFileDialog
        {
            Title = "다른 이름으로 저장",
            FileName = suggestedName,
            Filter = "마크다운|*.md|글|*.txt|모든 파일|*.*",
            AddExtension = true,
            DefaultExt = ".md",
        };
        if (path is not null) dialog.InitialDirectory = Path.GetDirectoryName(path);
        if (dialog.ShowDialog(this) != true)
        {
            Post(new { type = "saveCancelled" });
            CompleteSave(false);
            return;
        }
        Write(Path.GetFullPath(dialog.FileName), bytes, autosave: false);
    }

    /// <summary>쓰고, 쓴 바이트를 그 자리에서 기준으로 삼는다 — 늦게 잡으면 지켜보기가 내가 쓴 것을 바깥 변경으로 읽는다(macOS판에서 겪었다).</summary>
    internal void Write(string file, byte[] bytes, bool autosave)
    {
        try
        {
            AtomicFile.Write(file, bytes);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Post(new { type = "saveFailed", message = error.Message });
            if (!autosave) ShowError($"저장하지 못했습니다: {file}\n{error.Message}");
            CompleteSave(false);
            return;
        }
        if (!string.Equals(path, file, StringComparison.OrdinalIgnoreCase)) Watch(file, bytes);
        else
        {
            baseline?.Dispose();
            baseline = DiskBaseline.From(bytes);
        }
        Post(new { type = "saved", path = file, name = Path.GetFileName(file) });
        CompleteSave(true);
    }

    private void CompleteSave(bool saved)
    {
        if (pendingSave is { } pending)
        {
            pendingSave = null;
            pending.TrySetResult(saved);
        }
    }

    /// <summary>편집기에 저장을 시키고 끝날 때까지 — 닫기 전에.</summary>
    internal Task<bool> RequestSaveAsync()
    {
        var pending = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        pendingSave = pending;
        Run("save");
        return pending.Task;
    }

    // MARK: 닫기

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (closeConfirmed || smoke is not null || !State.Dirty) return;
        e.Cancel = true;
        _ = ConfirmCloseAsync();
    }

    /// <summary>
    /// 고친 것이 있으면 — 이름 있는 문서는 저장하고 닫는다(자동 저장과 같다, macOS판처럼 묻지 않는다). 저장한 적 없는 문서이거나
    /// 바깥 변경과 부딪친 중이면 묻는다.
    /// </summary>
    private async Task ConfirmCloseAsync()
    {
        if (State.Path is not null && !State.Conflict)
        {
            if (await RequestSaveAsync()) CloseNow();
            return;
        }
        var answer = MessageBox.Show(this,
            State.Conflict
                ? $"'{State.Name}'이(가) 다른 곳에서 바뀌었고, 여기서 고친 것은 저장하지 않았습니다. 여기서 고친 것으로 덮어쓸까요?"
                : $"'{State.Name}'의 바뀐 내용을 저장할까요?",
            "마디", MessageBoxButton.YesNoCancel, MessageBoxImage.Warning);
        if (answer == MessageBoxResult.Cancel) return;
        if (answer == MessageBoxResult.No || await RequestSaveAsync()) CloseNow();
    }

    private void CloseNow()
    {
        closeConfirmed = true;
        Close();
    }

    // MARK: 확인 실행 · 오류

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

    private void ShowError(string message)
    {
        if (smoke is not null)
        {
            smoke.Note(message);
            return;
        }
        // 편집기의 메시지를 받는 중일 수 있다 — 그 안에서 모달 창을 띄우지 않고 다음 차례에(WebView2가 권하는 방식).
        Dispatcher.InvokeAsync(() => MessageBox.Show(this, message, "마디", MessageBoxButton.OK, MessageBoxImage.Error));
    }
}
