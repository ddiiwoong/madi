using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace Madi;

/// <summary>
/// 메뉴 막대 — 제목 막대 아래 한 줄에 왼쪽은 메뉴(파일 · 편집 · 서식 · 보기 · 도구 · 도움말), 가운데는 서식 단추. Windows 11 메모장과 같은
/// 차림이다(사용자 — "메뉴바를 볼수 있도록 하는 기능을 넣어주고 기본값은 현재 처럼"). 기본은 숨김(설정 <c>showsMenuBar</c>) — 메뉴는 제목
/// 막대의 <c>…</c>에도 모두 있다. 서식 단추는 글을 고르면 뜨는 서식 막대(편집기)와 같은 명령 · 같은 아이콘이다.
///
/// 막대는 창의 제목 영역(<see cref="System.Windows.Shell.WindowChrome"/>의 CaptionHeight) 밖이라 누르면 누른 것이다 — 창을 끌지 않는다.
/// </summary>
public sealed class MenuBar : Grid
{
    public const double BarHeight = 44;

    /// <summary>서식 단추 — 명령은 편집기의 서식 명령(<c>core/formatting.ts</c>), <c>null</c>은 칸막이.</summary>
    private static readonly (string Command, string Icon, string Tip)?[] FormatButtons =
    [
        ("bold", "bold", "굵게 (Ctrl+B)"),
        ("italic", "italic", "기울임 (Ctrl+I)"),
        ("strikethrough", "strikethrough", "취소선 (Ctrl+Shift+X)"),
        ("code", "code", "인라인 코드 (Ctrl+Shift+C)"),
        ("link", "link", "링크 (Ctrl+K)"),
        null,
        ("quote", "quote", "인용 (Ctrl+Alt+Q)"),
        ("codeBlock", "codeBlock", "코드 블록 (Ctrl+Alt+C)"),
        ("table", "table", "표"),
        ("rule", "rule", "구분선"),
    ];

    private readonly Menu menu = new() { VerticalAlignment = VerticalAlignment.Center, Background = Brushes.Transparent };
    private readonly StackPanel tools = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border rule = new() { Height = 1, VerticalAlignment = VerticalAlignment.Bottom };
    private readonly List<ChromeButton> buttons = [];
    private readonly List<Border> gaps = [];
    private readonly Dictionary<string, ChromeButton> byCommand = [];
    private readonly Action<string> run;

    /// <param name="menus">위 단계 메뉴 — 껍데기가 만든 것(<c>…</c> 메뉴와 같은 항목, 따로 만든 사본).</param>
    /// <param name="run">서식 명령을 편집기에 — 하고 나서 초점을 편집기로 돌린다.</param>
    public MenuBar(IEnumerable<MenuItem> menus, Action<string> run)
    {
        this.run = run;
        Height = BarHeight;
        Visibility = Visibility.Collapsed;
        ClipToBounds = true;
        menu.Margin = new Thickness(6, 0, 0, 0);
        menu.HorizontalAlignment = HorizontalAlignment.Left;
        foreach (var item in menus)
        {
            // 하위 메뉴의 닫힘도 여기로 올라온다 — 다른 메뉴로 옮겨 가는 중이면 곧 다른 것이 열린다. 다 닫힌 뒤에 알린다.
            item.SubmenuClosed += (_, _) => Dispatcher.InvokeAsync(() =>
            {
                if (!AnyOpen) MenusClosed?.Invoke(this, EventArgs.Empty);
            }, System.Windows.Threading.DispatcherPriority.Background);
            menu.Items.Add(item);
        }
        // 메뉴가 닫힌 채 Esc — 메뉴에서 나간다(초점을 편집기로).
        menu.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape && !AnyOpen) MenusClosed?.Invoke(this, EventArgs.Empty);
        };
        Children.Add(menu);

        tools.Children.Add(Dropdown("heading", "제목 (Ctrl+1~6 · 본문 Ctrl+Alt+0)",
            [("본문", "heading0"), .. Enumerable.Range(1, 6).Select(level => ($"제목 {level}", $"heading{level}"))]));
        tools.Children.Add(Dropdown("bullet", "목록 — 글머리 · 번호 · 할 일",
            [("글머리 목록 (Ctrl+Shift+8)", "bullet"), ("번호 목록 (Ctrl+Shift+7)", "numbered"), ("할 일 목록 (Ctrl+Shift+9)", "task")]));
        tools.Children.Add(Gap());
        foreach (var entry in FormatButtons)
        {
            if (entry is not { } button)
            {
                tools.Children.Add(Gap());
                continue;
            }
            var made = MakeButton(LineIcons.Make(button.Icon), button.Tip);
            made.Click += (_, _) => run(button.Command);
            byCommand[button.Command] = made;
            tools.Children.Add(made);
        }
        Children.Add(tools);
        Children.Add(rule);
        SizeChanged += (_, _) => PlaceTools();
        menu.SizeChanged += (_, _) => PlaceTools();
        Apply(ChromeColors.Light);
    }

    /// <summary>이 막대가 그리는 아이콘 — 시험이 <see cref="LineIcons"/>에 다 있는지 본다(없으면 창을 만들다 멈춘다).</summary>
    public static IEnumerable<string> IconNames =>
        FormatButtons.OfType<(string Command, string Icon, string Tip)>().Select(button => button.Icon).Concat(["heading", "bullet", "chevron"]);

    /// <summary>위 단계 메뉴의 이름 — 확인 실행이 본다.</summary>
    public IReadOnlyList<string> MenuNames => menu.Items.OfType<MenuItem>().Select(item => item.Header?.ToString() ?? "").ToList();

    /// <summary>서식 단추의 명령(드롭다운은 그 이름) — 확인 실행이 본다.</summary>
    public IReadOnlyList<string> ToolCommands => [.. byCommand.Keys];

    /// <summary>열린 위 단계 메뉴의 이름 — 없으면 null.</summary>
    public string? OpenMenuName => menu.Items.OfType<MenuItem>().FirstOrDefault(item => item.IsSubmenuOpen)?.Header?.ToString();

    public bool IsShown => Visibility == Visibility.Visible;

    /// <summary>
    /// 이름이 잘린 위 단계 메뉴 — 확인 실행이 본다. 둘을 잰다: 메뉴 항목과 그 글자 칸(템플릿의 <c>HeaderPresenter</c>)이 바라는 높이보다
    /// 좁은 자리를 받았는가(WPF는 좁은 자리에 넣으면 그 자리로 잘라 그린다 — 처음엔 47px 메뉴가 38px 막대에서 그렇게 위가 잘렸다), 그리고
    /// 글자 칸이 막대의 위아래 안에 드는가.
    /// </summary>
    public IReadOnlyList<string> ClippedMenuNames()
    {
        var clipped = new List<string>();
        foreach (var item in menu.Items.OfType<MenuItem>())
        {
            var header = item.Template?.FindName("HeaderPresenter", item) as FrameworkElement;
            foreach (var element in new[] { item, header }.OfType<FrameworkElement>())
            {
                var slot = LayoutInformation.GetLayoutSlot(element);
                if (slot.Height + 0.5 < element.DesiredSize.Height)
                {
                    clipped.Add($"{item.Header}: {element.GetType().Name} {slot.Height:0.#} < {element.DesiredSize.Height:0.#}");
                }
            }
            if (header is null || header.ActualHeight <= 0) continue;
            var box = header.TransformToAncestor(this).TransformBounds(new Rect(0, 0, header.ActualWidth, header.ActualHeight));
            if (box.Top < -0.5 || box.Bottom > ActualHeight + 0.5) clipped.Add($"{item.Header}: {box.Top:0.#}~{box.Bottom:0.#}/{ActualHeight:0.#}");
        }
        return clipped;
    }

    /// <summary>확인 실행 — 단추를 사람이 누른 것처럼(드롭다운이면 그 메뉴를 연다).</summary>
    public void Press(string command) => byCommand[command].RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent, byCommand[command]));

    /// <summary>키보드로(F10 · Alt) — 위 단계 메뉴 하나를 열고 첫 항목에 초점. <paramref name="index"/>가 없으면 첫 메뉴(파일).</summary>
    public void Open(int index = 0)
    {
        var items = menu.Items.OfType<MenuItem>().ToList();
        if (items.Count == 0) return;
        var item = items[Math.Clamp(index, 0, items.Count - 1)];
        foreach (var other in items.Where(other => other != item)) other.IsSubmenuOpen = false;
        item.Focus();
        item.IsSubmenuOpen = true;
        Dispatcher.InvokeAsync(() => item.Items.OfType<MenuItem>().FirstOrDefault(child => child.IsEnabled)?.Focus(),
            System.Windows.Threading.DispatcherPriority.Input);
    }

    public void CloseMenus()
    {
        foreach (var item in menu.Items.OfType<MenuItem>()) item.IsSubmenuOpen = false;
    }

    private bool AnyOpen => menu.Items.OfType<MenuItem>().Any(item => item.IsSubmenuOpen);

    /// <summary>메뉴 · 고르는 메뉴가 다 닫혔을 때 — 껍데기가 초점을 편집기로 돌린다.</summary>
    public event EventHandler? MenusClosed;

    public void Apply(ChromeColors next)
    {
        Background = new SolidColorBrush(next.Background);
        rule.Background = new SolidColorBrush(next.Tint(next.Dark ? 0.12 : 0.08));
        foreach (var button in buttons) button.Apply(next);
        foreach (var gap in gaps) gap.Background = new SolidColorBrush(next.Tint(0.14));
    }

    /// <summary>
    /// 서식 단추는 창 가운데에(메모장처럼). 창이 좁아 메뉴와 겹치면 메뉴 바로 오른쪽에 붙인다 — 그래도 모자라면 오른쪽이 잘린다.
    /// </summary>
    private void PlaceTools()
    {
        // Fluent 테마의 위 단계 메뉴는 47px 남짓이다(바깥 여백 4 + 안쪽 여백 10, 위아래로 — 바꿀 속성이 없다). 칸보다 크면 WPF가 위에 붙여
        // 글자가 아래로 밀려 잘렸다(확인 실행의 menubar.png). 메뉴가 잰 높이만큼 위아래로 넓혀 가운데에 두고, 넘친 만큼은 투명한 바깥 여백이
        // 막대 밖으로 잘리게 한다.
        menu.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var spill = Math.Max(0, Math.Ceiling(menu.DesiredSize.Height - BarHeight) / 2);
        if (Math.Abs(menu.Margin.Top + spill) > 0.1) menu.Margin = new Thickness(6, -spill, 0, -spill);
        tools.Measure(new Size(double.PositiveInfinity, BarHeight));
        var width = tools.DesiredSize.Width;
        var menuRight = menu.Margin.Left + menu.ActualWidth + 16;
        var centered = (ActualWidth - width) / 2;
        tools.HorizontalAlignment = HorizontalAlignment.Left;
        tools.Margin = new Thickness(Math.Max(centered, menuRight), 0, 0, 0);
    }

    private ChromeButton MakeButton(UIElement icon, string tip)
    {
        var button = new ChromeButton(icon, tip)
        {
            Width = 32, Height = 28, Margin = new Thickness(1, 0, 1, 0), VerticalAlignment = VerticalAlignment.Center,
        };
        buttons.Add(button);
        return button;
    }

    /// <summary>아이콘 ▾ — 누르면 고르는 메뉴(제목 단계 · 목록 셋).</summary>
    private ChromeButton Dropdown(string icon, string tip, (string Title, string Command)[] choices)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(LineIcons.Make(icon));
        var chevron = LineIcons.Make("chevron", 10);
        chevron.Margin = new Thickness(3, 1, 0, 0);
        content.Children.Add(chevron);
        var button = MakeButton(content, tip);
        button.Width = 44;
        var picker = new ContextMenu { PlacementTarget = button, Placement = PlacementMode.Bottom, VerticalOffset = 4 };
        foreach (var (title, command) in choices)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => run(command);
            picker.Items.Add(item);
        }
        picker.Closed += (_, _) => MenusClosed?.Invoke(this, EventArgs.Empty);
        button.Click += (_, _) => picker.IsOpen = true;
        AutomationProperties.SetName(button, tip);
        byCommand[icon] = button;
        return button;
    }

    private Border Gap()
    {
        var gap = new Border { Width = 1, Height = 18, Margin = new Thickness(6, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
        gaps.Add(gap);
        return gap;
    }
}
