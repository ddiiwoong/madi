using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shell;
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
public sealed partial class MainWindow : Window
{
    internal const string AppHost = "app.madi";
    private static readonly List<MainWindow> Windows = [];
    private static Task<CoreWebView2Environment>? environment;

    /// <summary>설정 · 최근 파일 — 모든 창이 함께. <see cref="Program"/>이 정한다(확인 실행은 그 폴더 안에).</summary>
    internal static SettingsStore Store { get; set; } = new(SettingsStore.DefaultFolder);

    /// <summary>테마 여덟 — 편집기의 <c>core/palette.ts</c>와 같은 이름 · 차례.</summary>
    private static readonly (string Id, string Label)[] Themes =
    [
        ("standard", "기본"), ("notion", "Notion"), ("confluence", "Confluence"), ("github", "GitHub"),
        ("obsidian", "Obsidian"), ("paper", "종이"), ("solarized", "Solarized"), ("highContrast", "고대비"),
    ];

    /// <summary>메뉴의 ✓ — 설정의 어느 값이 이 항목인가. 설정이 바뀌면 다시 단다.</summary>
    private readonly List<(MenuItem Item, string Field, string Value, string Default)> choiceItems = [];
    private readonly List<(MenuItem Item, string Field, bool Fallback)> flagItems = [];
    private readonly MenuItem recentMenu;
    /// <summary>제목 막대 — 메뉴 막대 · 상태 줄 대신(<see cref="TitleBar"/>).</summary>
    private readonly TitleBar titleBar = new();
    /// <summary>메뉴 — 제목 막대의 <c>…</c>(F10). 전의 메뉴 막대 전체와, 맨 위에 자주 쓰는 것(macOS판의 버거 메뉴와 같은 차례).</summary>
    private readonly ContextMenu burger = new();
    private readonly Border frame = new();
    private readonly WindowChrome chrome;

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

        // 창 테두리 안을 다 쓴다 — 제목 막대를 마디가 그린다. 위 테두리 6은 크기 바꾸기, 그 아래 제목 막대 높이는 창 끌기.
        WindowChrome.SetWindowChrome(this, chrome = new WindowChrome
        {
            CaptionHeight = TitleBar.BarHeight - 6,
            ResizeBorderThickness = new Thickness(6),
            // 한 줄만 남겨 Windows의 그림자를 받는다(0이면 Windows 10에서 그림자가 사라진다).
            GlassFrameThickness = new Thickness(0, 0, 0, 1),
            CornerRadius = new CornerRadius(0),
            UseAeroCaptionButtons = false,
        });
        var menu = burger;
        AddBurgerPicks();
        var file = Heading("파일(_F)");
        file.Items.Add(Item("새로 만들기(_N)", "Ctrl+N", () => OpenWindow(null)));
        file.Items.Add(Item("열기(_O)…", "Ctrl+O", ShowOpenDialog));
        file.Items.Add(Item("빠른 열기(_Q)…", "Ctrl+Alt+O", () => Run("quickOpen")));
        recentMenu = Heading("최근 문서(_R)");
        recentMenu.Items.Add(new MenuItem { Header = "(없음)", IsEnabled = false });
        recentMenu.SubmenuOpened += (_, _) => FillRecentMenu();
        file.Items.Add(recentMenu);
        file.Items.Add(new Separator());
        file.Items.Add(Item("저장(_S)", "Ctrl+S", () => Run("save")));
        file.Items.Add(Item("다른 이름으로 저장(_A)…", "Ctrl+Shift+S", () => Run("saveAs")));
        file.Items.Add(new Separator());
        file.Items.Add(Item("PDF 내보내기(_E)…", "", () => _ = ExportPdfAsync()));
        file.Items.Add(Item("프린트하기(_P)…", "Ctrl+P", () => Run("print")));
        var printMenu = Heading("프린트 설정(_T)");
        var marginMenu = Heading("여백(_M)");
        marginMenu.Items.Add(Choice("좁게", "setPrintMargin", "printMargin", "narrow", "normal"));
        marginMenu.Items.Add(Choice("보통", "setPrintMargin", "printMargin", "normal", "normal"));
        marginMenu.Items.Add(Choice("넓게", "setPrintMargin", "printMargin", "wide", "normal"));
        var orientationMenu = Heading("방향(_O)");
        orientationMenu.Items.Add(Choice("세로", "setPrintOrientation", "printOrientation", "portrait", "portrait"));
        orientationMenu.Items.Add(Choice("가로", "setPrintOrientation", "printOrientation", "landscape", "portrait"));
        var paperMenu = Heading("용지(_P)");
        paperMenu.Items.Add(Choice("시스템 기본", "setPrintPaper", "printPaper", "system", "system"));
        paperMenu.Items.Add(Choice("A4", "setPrintPaper", "printPaper", "a4", "system"));
        paperMenu.Items.Add(Choice("Letter", "setPrintPaper", "printPaper", "letter", "system"));
        printMenu.Items.Add(marginMenu);
        printMenu.Items.Add(orientationMenu);
        printMenu.Items.Add(paperMenu);
        file.Items.Add(printMenu);
        file.Items.Add(new Separator());
        file.Items.Add(Item("닫기(_C)", "Ctrl+W", Close));
        var edit = Heading("편집(_E)");
        edit.Items.Add(Item("실행 취소(_U)", "Ctrl+Z", () => Run("undo")));
        edit.Items.Add(Item("다시 실행(_R)", "Ctrl+Y", () => Run("redo")));
        edit.Items.Add(new Separator());
        edit.Items.Add(Item("모두 선택(_A)", "Ctrl+A", () => Run("selectAll")));
        edit.Items.Add(Item("찾기(_F)…", "Ctrl+F", () => Run("find")));
        // 서식 — macOS판의 서식 메뉴와 같은 차례 · 같은 단축키(⌘ → Ctrl). 글을 고르면 위에 뜨는 서식 막대(편집기)도 같은 명령이다.
        var format = Heading("서식(_O)");
        var headings = Heading("제목(_H)");
        headings.Items.Add(Item("본문(_0)", "Ctrl+Alt+0", () => Run("heading0")));
        for (var level = 1; level <= 6; level++)
        {
            var command = $"heading{level}";
            headings.Items.Add(Item($"제목 {level}(_{level})", $"Ctrl+{level}", () => Run(command)));
        }
        format.Items.Add(headings);
        format.Items.Add(new Separator());
        format.Items.Add(Item("굵게(_B)", "Ctrl+B", () => Run("bold")));
        format.Items.Add(Item("기울임(_I)", "Ctrl+I", () => Run("italic")));
        format.Items.Add(Item("취소선(_S)", "Ctrl+Shift+X", () => Run("strikethrough")));
        format.Items.Add(Item("인라인 코드(_C)", "Ctrl+Shift+C", () => Run("code")));
        format.Items.Add(Item("링크(_K)", "Ctrl+K", () => Run("link")));
        format.Items.Add(new Separator());
        format.Items.Add(Item("글머리 목록(_U)", "Ctrl+Shift+8", () => Run("bullet")));
        format.Items.Add(Item("번호 목록(_N)", "Ctrl+Shift+7", () => Run("numbered")));
        format.Items.Add(Item("할 일 목록(_T)", "Ctrl+Shift+9", () => Run("task")));
        format.Items.Add(Item("인용(_Q)", "Ctrl+Alt+Q", () => Run("quote")));
        format.Items.Add(new Separator());
        format.Items.Add(Item("코드 블록(_D)", "Ctrl+Alt+C", () => Run("codeBlock")));
        format.Items.Add(Item("표(_A)", "", () => Run("table")));
        format.Items.Add(Item("구분선(_R)", "", () => Run("rule")));
        var viewMenu = Heading("보기(_V)");
        viewMenu.Items.Add(Item("명령 팔레트(_P)…", "Ctrl+Shift+P", () => Run("commandPalette")));
        viewMenu.Items.Add(new Separator());
        outlineItem = Item("목차(_O)", "Ctrl+Shift+O", () => Run("toggleOutline"));
        sourceItem = Item("원본 보기(_S)", "Ctrl+E", () => Run("toggleSource"));
        followItem = Item("따라 보기(_L)", "Ctrl+Alt+L", () => Run("toggleFollow"));
        viewMenu.Items.Add(outlineItem);
        viewMenu.Items.Add(sourceItem);
        viewMenu.Items.Add(followItem);
        viewMenu.Items.Add(Item("문서 정보(_I)", "", () => Run("docInfo")));
        viewMenu.Items.Add(new Separator());
        viewMenu.Items.Add(ThemeMenu());
        var appearanceMenu = Heading("모양(_M)");
        appearanceMenu.Items.Add(Choice("시스템 따라(_S)", "setAppearance", "appearance", "system", "system"));
        appearanceMenu.Items.Add(Choice("밝게(_L)", "setAppearance", "appearance", "light", "system"));
        appearanceMenu.Items.Add(Choice("어둡게(_D)", "setAppearance", "appearance", "dark", "system"));
        viewMenu.Items.Add(appearanceMenu);
        var fontMenu = Heading("글꼴(_F)");
        fontMenu.Items.Add(Item("본문 글꼴(_B)…", "", () => Run("pickBodyFont")));
        fontMenu.Items.Add(Item("코드 글꼴(_C)…", "", () => Run("pickCodeFont")));
        viewMenu.Items.Add(fontMenu);
        viewMenu.Items.Add(Item("글자 크게(_I)", "Ctrl+=", () => Run("textBigger")));
        viewMenu.Items.Add(Item("글자 작게(_D)", "Ctrl+-", () => Run("textSmaller")));
        viewMenu.Items.Add(Item("글자 기본 크기(_Z)", "Ctrl+0", () => Run("textStandard")));
        var spacingMenu = Heading("줄 사이(_G)");
        spacingMenu.Items.Add(Choice("좁게", "setLineSpacing", "lineSpacing", "tight", "normal"));
        spacingMenu.Items.Add(Choice("보통", "setLineSpacing", "lineSpacing", "normal", "normal"));
        spacingMenu.Items.Add(Choice("넓게", "setLineSpacing", "lineSpacing", "loose", "normal"));
        viewMenu.Items.Add(spacingMenu);
        var widthMenu = Heading("글 폭(_W)");
        widthMenu.Items.Add(Choice("좁게", "setDocumentWidth", "documentWidth", "narrow", "normal"));
        widthMenu.Items.Add(Choice("보통", "setDocumentWidth", "documentWidth", "normal", "normal"));
        widthMenu.Items.Add(Choice("넓게", "setDocumentWidth", "documentWidth", "wide", "normal"));
        widthMenu.Items.Add(Choice("창 폭 전체", "setDocumentWidth", "documentWidth", "full", "normal"));
        viewMenu.Items.Add(widthMenu);
        viewMenu.Items.Add(new Separator());
        viewMenu.Items.Add(Flag("원격 그림 받기(_R)", "toggleRemoteImages", "loadsRemoteImages"));
        viewMenu.Items.Add(Flag("문서 메타데이터 접어 두기(_H)", "toggleFrontMatter", "collapsesFrontMatter"));
        var tools = Heading("도구(_T)");
        tools.Items.Add(Item("LLM 키(_K)…", "", () => new LlmKeysWindow(this).ShowDialog()));
        tools.Items.Add(Item("기본 앱 설정 열기(_D)…", "", OpenDefaultAppsSettings));
        var help = Heading("도움말(_H)");
        // Store판(MSIX)은 Store가 업데이트한다 — GitHub에 묻는 확인은 설치 파일판만.
        if (!PackageIdentity.IsPackaged)
        {
            help.Items.Add(Item("업데이트 확인(_U)…", "", () => _ = Updates.CheckAsync(this, interactive: true)));
            help.Items.Add(Flag("하루 한 번 새 판 확인(_D)", "toggleUpdateChecks", "checksForUpdates", fallback: true));
            help.Items.Add(new Separator());
        }
        help.Items.Add(Item("마디 정보(_A)", "", ShowAbout));
        UpdateSettingsMenu();
        menu.Items.Add(new Separator());
        menu.Items.Add(file);
        menu.Items.Add(edit);
        menu.Items.Add(format);
        menu.Items.Add(viewMenu);
        menu.Items.Add(tools);
        menu.Items.Add(help);

        // 제목 막대의 단추.
        titleBar.Outline.Click += (_, _) => Press(() => Run("toggleOutline"));
        titleBar.Search.Click += (_, _) => Press(() => Run("find"));
        titleBar.Source.Click += (_, _) => Press(() => Run("toggleSource"));
        titleBar.Open.Click += (_, _) => Press(ShowOpenDialog);
        titleBar.More.Click += (_, _) => OpenMenu(byKeyboard: false);
        titleBar.Minimize.Click += (_, _) => SystemCommands.MinimizeWindow(this);
        titleBar.Maximize.Click += (_, _) =>
        {
            if (WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(this);
            else SystemCommands.MaximizeWindow(this);
        };
        titleBar.CloseButton.Click += (_, _) => SystemCommands.CloseWindow(this);
        burger.PlacementTarget = titleBar.More;
        burger.Placement = PlacementMode.Custom;
        // 오른쪽 끝을 단추에 맞춘다(창의 오른쪽 위 — 화면 밖으로 나가지 않게).
        burger.CustomPopupPlacementCallback = (popup, target, _) =>
            [new CustomPopupPlacement(new Point(target.Width - popup.Width, target.Height + 4), PopupPrimaryAxis.Horizontal)];

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(TitleBar.BarHeight) });
        grid.RowDefinitions.Add(new RowDefinition());
        Grid.SetRow(webView, 1);
        grid.Children.Add(titleBar);
        grid.Children.Add(webView);
        frame.Child = grid;
        Content = frame;
        ApplyChrome(ChromeColors.Load(Store.HostText("chrome")));
        StateChanged += (_, _) => FitFrame();
        SourceInitialized += (_, _) => WindowFrame.Apply(this, titleBar.Colors);

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
        // 맨 위의 자주 쓰는 것 — macOS판 버거 메뉴(`AppMenu.burgerPicks`)와 같은 차례. 아래에 메뉴 막대 전체가 하위 메뉴로 온다.
        void AddBurgerPicks()
        {
            menu.Items.Add(Item("새로 만들기", "Ctrl+N", () => OpenWindow(null)));
            menu.Items.Add(Item("열기…", "Ctrl+O", ShowOpenDialog));
            menu.Items.Add(Item("빠른 열기…", "Ctrl+Alt+O", () => Run("quickOpen")));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("저장", "Ctrl+S", () => Run("save")));
            menu.Items.Add(Item("다른 이름으로 저장…", "Ctrl+Shift+S", () => Run("saveAs")));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("PDF 내보내기…", "", () => _ = ExportPdfAsync()));
            menu.Items.Add(Item("프린트하기…", "Ctrl+P", () => Run("print")));
            menu.Items.Add(new Separator());
            menu.Items.Add(ThemeMenu());
            menu.Items.Add(Item("명령 팔레트…", "Ctrl+Shift+P", () => Run("commandPalette")));
        }
        MenuItem ThemeMenu()
        {
            var themeMenu = Heading("테마(_T)");
            foreach (var (id, label) in Themes) themeMenu.Items.Add(Choice(label, "setTheme", "theme", id, "standard"));
            return themeMenu;
        }
        MenuItem Choice(string header, string command, string field, string value, string fallback)
        {
            var item = Item(header, "", () => Run(command, value));
            choiceItems.Add((item, field, value, fallback));
            return item;
        }
        MenuItem Flag(string header, string command, string field, bool fallback = false)
        {
            var item = Item(header, "", () => Run(command));
            flagItems.Add((item, field, fallback));
            return item;
        }
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

    // MARK: 제목 막대

    internal TitleBar Chrome => titleBar;

    /// <summary>제목 막대의 단추 — 하고 나서 초점을 편집기로(단추는 초점을 가져가지 않지만 대화상자가 가져갈 수 있다).</summary>
    private void Press(Action action)
    {
        action();
        webView.Focus();
    }

    /// <summary>메뉴(…) — 단추로, 또는 F10(편집기가 알린다). 키보드로 열었으면 첫 항목에 초점을 둬 화살표로 고른다.</summary>
    internal void OpenMenu(bool byKeyboard)
    {
        burger.IsOpen = true;
        if (byKeyboard)
        {
            Dispatcher.InvokeAsync(() => burger.Items.OfType<MenuItem>().FirstOrDefault()?.Focus(),
                System.Windows.Threading.DispatcherPriority.Input);
        }
    }

    internal bool MenuIsOpen => burger.IsOpen;

    internal void CloseMenu() => burger.IsOpen = false;

    /// <summary>편집기의 테마 색으로 — 제목 막대, 창 바탕(크기를 바꾸는 동안 보인다), 창 테두리, 메뉴의 밝기.</summary>
    private void ApplyChrome(ChromeColors colors)
    {
        titleBar.Apply(colors);
        Background = new SolidColorBrush(colors.Background);
        WindowFrame.Apply(this, colors);
        // 편집기가 그리기 전의 바탕 — 어두운 테마에서 흰 화면이 번쩍이지 않게.
        webView.DefaultBackgroundColor = System.Drawing.Color.FromArgb(colors.Background.R, colors.Background.G, colors.Background.B);
        Program.UseDarkMenus(colors.Dark);
    }

    /// <summary>최대화하면 화면 밖으로 나간 테두리만큼 안으로 — 제목 막대의 단추가 잘리지 않게.</summary>
    private void FitFrame()
    {
        var maximized = WindowState == WindowState.Maximized;
        var inset = maximized ? WindowFrame.MaximizedInset(this) : new Thickness(0);
        frame.Margin = inset;
        // 제목 영역은 창의 위 끝(최대화하면 화면 밖)에서 잰다 — 밀려 내려간 만큼 늘린다.
        chrome.CaptionHeight = TitleBar.BarHeight - chrome.ResizeBorderThickness.Top + inset.Top;
        titleBar.SetMaximized(maximized);
    }

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
        // 글자 크기는 설정(Ctrl+= · Ctrl+- · Ctrl+0)이다 — 브라우저의 확대(Ctrl+휠)가 따로 놀지 않게.
        settings.IsZoomControlEnabled = false;
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
        // 첫 그림부터 설정의 테마로 — 밝게 그렸다가 어둡게 바뀌지 않게. 값은 JSON 그대로(문자열은 이스케이프된다).
        await Core.AddScriptToExecuteOnDocumentCreatedAsync($"window.madiSettings = {Store.Settings.ToJsonString()};");
        // 껍데기에 대한 것 — Store판이면 명령 팔레트가 새 판 확인을 보이지 않는다.
        var host = JsonSerializer.Serialize(new { packaged = PackageIdentity.IsPackaged });
        await Core.AddScriptToExecuteOnDocumentCreatedAsync($"window.madiHost = {host};");
        // 확인 실행 중에는 링크로 연 창도 확인 메시지를 받는다(`SmokeMode`).
        var query = smoke is not null || SmokeMode ? "?smoke=1&autosave=1500" : "";
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
            Observer?.Invoke(this, message);
            switch (type)
            {
                case "ready":
                    editorReady = true;
                    if (smoke is not null)
                    {
                        await smoke.RunAsync(message);
                        break;
                    }
                    if (options.FilePath is { } file) await LoadFileAsync(file);
                    await ReadyAsync();
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
                case "chrome":
                    if (ChromeColors.From(message) is { } colors)
                    {
                        ApplyChrome(colors);
                        Store.SetHostText("chrome", colors.ToJson());
                    }
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
                        case "exportPdf": _ = ExportPdfAsync(); break;
                        case "llmKeys": new LlmKeysWindow(this).ShowDialog(); break;
                        case "checkForUpdates": _ = Updates.CheckAsync(this, interactive: true); break;
                        case "menu": OpenMenu(byKeyboard: true); break;
                    }
                    break;
                case "outputReady":
                    pendingOutput?.TrySetResult(message);
                    break;
                case "openUrl":
                    OpenUrl(Field(message, "url"));
                    break;
                case "reload":
                    if (path is not null) await LoadFileAsync(path, reload: true);
                    break;
                case "settings":
                    if (message.TryGetProperty("settings", out var settingsValue) && Store.Save(settingsValue)) BroadcastSettings();
                    break;
                case "listFiles":
                    await ReplyFilesAsync(Number(message, "id"));
                    break;
                case "listFonts":
                    Post(new { type = "fonts", id = Number(message, "id"), families = FontNames() });
                    break;
                case "loadImage":
                    await ReplyImageAsync(Number(message, "id"), Field(message, "path") ?? "");
                    break;
                case "openPath":
                    if (Field(message, "path") is { } picked && File.Exists(picked)) OpenPath(picked);
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

    private static int Number(JsonElement message, string name) =>
        message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : -1;

    private void UpdateState(JsonElement message)
    {
        bool Flag(string name) => message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;
        State = new DocumentState(Field(message, "name") ?? "제목 없음", Field(message, "path"),
            Flag("dirty"), Flag("conflict"), Flag("source"), Flag("follow"), Flag("outline"));
        Title = $"{(State.Dirty ? "*" : "")}{State.Name} - 마디";
        sourceItem.IsChecked = State.Source;
        followItem.IsChecked = State.Follow;
        outlineItem.IsChecked = State.Outline;
        var notes = message.TryGetProperty("notes", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(item => item.GetString()).OfType<string>().ToList()
            : [];
        titleBar.SetTitle(State.Name, State.Dirty, notes);
        titleBar.Source.IsOn = State.Source;
        titleBar.Outline.IsOn = State.Outline;
    }

    /// <summary>메뉴에서 고른 명령을 편집기에 — 단축키는 편집기가 직접 받는다. 설정 명령은 값을 <paramref name="arg"/>로.</summary>
    internal void Run(string command, string? arg = null)
    {
        if (!editorReady) return;
        if (arg is null) Post(new { type = "run", command });
        else Post(new { type = "run", command, arg });
    }

    // MARK: 설정 · 최근 문서 · 빠른 열기 · 글꼴 · 그림

    /// <summary>어느 창에서 바꾼 설정이든 모든 창에(바꾼 창에도 — 편집기가 같은 값을 다시 받아도 그대로다).</summary>
    private static void BroadcastSettings()
    {
        foreach (var window in Windows.ToList())
        {
            window.UpdateSettingsMenu();
            if (window.editorReady) window.Post(new { type = "settings", settings = Store.Settings });
        }
    }

    private void UpdateSettingsMenu()
    {
        foreach (var (item, field, value, fallback) in choiceItems) item.IsChecked = (Store.Text(field) ?? fallback) == value;
        foreach (var (item, field, fallback) in flagItems) item.IsChecked = Store.FlagOr(field, fallback);
    }

    private void FillRecentMenu()
    {
        recentMenu.Items.Clear();
        foreach (var file in Store.Recent)
        {
            var item = new MenuItem { Header = file.Replace("_", "__", StringComparison.Ordinal), ToolTip = file };
            var target = file;
            item.Click += (_, _) =>
            {
                if (File.Exists(target)) OpenPath(target);
                else ShowError($"파일이 없습니다: {target}");
            };
            recentMenu.Items.Add(item);
        }
        if (recentMenu.Items.Count == 0)
        {
            recentMenu.Items.Add(new MenuItem { Header = "(없음)", IsEnabled = false });
            return;
        }
        recentMenu.Items.Add(new Separator());
        var clear = new MenuItem { Header = "목록 지우기(_C)" };
        clear.Click += (_, _) => Store.ClearRecent();
        recentMenu.Items.Add(clear);
    }

    /// <summary>빠른 열기의 후보 — 폴더를 훑는 것(최대 20,000항목)과 최근 파일이 있는지 보는 것(네트워크 위치는 느리다)은 UI 밖에서.</summary>
    private async Task ReplyFilesAsync(int id)
    {
        var open = Windows.Where(window => window != this && window.path is not null).Select(window => window.path!).ToList();
        var recent = Store.Recent.ToList();
        var current = path;
        var root = current is null ? null : Path.GetDirectoryName(current);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = await Task.Run(() =>
        {
            var folder = root is null ? [] : QuickOpenSources.FolderFiles(root);
            return QuickOpenSources.Candidates(open, recent.Where(File.Exists), folder, root, home);
        });
        var items = candidates
            .Where(candidate => !string.Equals(candidate.Path, current, StringComparison.OrdinalIgnoreCase))
            .Select(candidate => new { path = candidate.Path, name = candidate.Name, detail = candidate.Detail });
        Post(new { type = "files", id, items });
    }

    /// <summary>
    /// 이 PC의 글꼴 이름. CSS의 <c>font-family</c>로 쓰므로 Edge가 아는 이름(영어 이름이 있으면 그것)으로. WPF의 합성 글꼴
    /// (<c>Global User Interface</c> 같은 것)은 실제 글꼴이 아니라 뺀다.
    /// </summary>
    private static List<string> FontNames()
    {
        var english = System.Windows.Markup.XmlLanguage.GetLanguage("en-us");
        return Fonts.SystemFontFamilies
            .Select(family => family.FamilyNames.TryGetValue(english, out var name) ? name : family.Source)
            .Where(name => !string.IsNullOrWhiteSpace(name) && !name.StartsWith("Global ", StringComparison.Ordinal))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    private async Task ReplyImageAsync(int id, string raw)
    {
        var document = path;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        try
        {
            var dataUrl = await Task.Run(() => ImageFiles.Load(raw, document, home));
            Post(new { type = "image", id, ok = true, dataUrl });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Post(new { type = "image", id, ok = false, message = error.Message });
        }
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
        if (!reload) Store.AddRecent(file);
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

    /// <summary>
    /// 열기 창 · 끌어다 놓기 · 두 번째 실행 · 링크. 이미 연 파일이면 그 창을, 이 창이 비었으면 여기에, 아니면 새 창에.
    /// <paramref name="then"/>은 그 창에 파일이 실린 뒤에(링크의 줄로 가기 · 찾기 · 끝에 더하기).
    /// </summary>
    internal void OpenPath(string file, Action<MainWindow>? then = null)
    {
        var full = Path.GetFullPath(file);
        if (FindWindow(full) is { } open)
        {
            Bring(open);
            if (then is not null) open.WhenLoaded(then);
            return;
        }
        if (path is null && !State.Dirty && editorReady)
        {
            _ = LoadAndThenAsync(full, then);
            return;
        }
        OpenWindow(full, then);
    }

    private async Task LoadAndThenAsync(string file, Action<MainWindow>? then)
    {
        var reply = await LoadFileAsync(file);
        if (then is not null && reply is { } opened && Field(opened, "type") == "opened") then(this);
    }

    private static void OpenWindow(string? file, Action<MainWindow>? then = null)
    {
        var window = new MainWindow(new LaunchOptions(file, null));
        if (then is not null) window.afterLoad.Add(then);
        window.Show();
    }

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
        if (!string.Equals(path, file, StringComparison.OrdinalIgnoreCase))
        {
            Watch(file, bytes);
            Store.AddRecent(file);
        }
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
        if (closeConfirmed || smoke is not null || SmokeMode || !State.Dirty) return;
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
        if (smoke is not null || SmokeMode)
        {
            SmokeNotes.Add(message);
            smoke?.Note(message);
            return;
        }
        // 편집기의 메시지를 받는 중일 수 있다 — 그 안에서 모달 창을 띄우지 않고 다음 차례에(WebView2가 권하는 방식).
        Dispatcher.InvokeAsync(() => MessageBox.Show(this, message, "마디", MessageBoxButton.OK, MessageBoxImage.Error));
    }
}
