using System.Globalization;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shell;

namespace Madi;

/// <summary>
/// 제목 막대의 색 — 편집기가 보낸 테마 색(<c>chrome</c> 메시지, <c>core/palette.ts</c>의 값). 제목 막대와 글이 한 판으로 보이게 같은 바탕을 쓴다.
/// </summary>
public sealed record ChromeColors(Color Background, Color Text, Color Dim, Color Rule, Color Accent, bool Dark)
{
    public static readonly ChromeColors Light = new(Rgb("#FFFFFF"), Rgb("#1D1D1F"), Rgb("#6E6E73"), Rgb("#D8D8DC"), Rgb("#0068DA"), false);

    /// <summary>글자색을 바탕에 <paramref name="amount"/>만큼 섞은 색 — 누름 · 올림 · 칩의 바탕.</summary>
    public Color Tint(double amount) => Blend(Text, Background, amount);

    public static Color Blend(Color top, Color bottom, double amount) => Color.FromRgb(
        (byte)Math.Round(bottom.R + (top.R - bottom.R) * amount),
        (byte)Math.Round(bottom.G + (top.G - bottom.G) * amount),
        (byte)Math.Round(bottom.B + (top.B - bottom.B) * amount));

    public static Color Rgb(string hex)
    {
        var value = hex.Trim().TrimStart('#');
        if (value.Length != 6 || !int.TryParse(value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
        {
            throw new FormatException($"#RRGGBB가 아니다: {hex}");
        }
        return Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    }

    public static string Hex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";

    /// <summary>편집기의 <c>chrome</c> 메시지. 꼴이 틀리면 null.</summary>
    public static ChromeColors? From(JsonElement message)
    {
        try
        {
            string Text(string name) => message.GetProperty(name).GetString() ?? throw new FormatException(name);
            return new ChromeColors(Rgb(Text("background")), Rgb(Text("text")), Rgb(Text("dim")), Rgb(Text("rule")), Rgb(Text("accent")),
                message.TryGetProperty("dark", out var dark) && dark.ValueKind == JsonValueKind.True);
        }
        catch (Exception error) when (error is FormatException or KeyNotFoundException or InvalidOperationException)
        {
            return null;
        }
    }

    public string ToJson() => JsonSerializer.Serialize(new
    {
        background = Hex(Background), text = Hex(Text), dim = Hex(Dim), rule = Hex(Rule), accent = Hex(Accent), dark = Dark,
    });

    /// <summary>지난번에 쓴 색(<c>host.json</c>) — 다음에 켤 때 첫 그림부터 그 테마로(밝게 그렸다가 어둡게 바뀌지 않게).</summary>
    public static ChromeColors Load(string? json)
    {
        if (json is null) return Light;
        try
        {
            using var document = JsonDocument.Parse(json);
            return From(document.RootElement) ?? Light;
        }
        catch (JsonException)
        {
            return Light;
        }
    }
}

/// <summary>제목 막대의 단추 — 아이콘 하나. 초점을 가져가지 않는다(누른 뒤에도 캐럿이 편집기에 남는다).</summary>
public sealed class ChromeButton : Button
{
    public enum Kinds { Tool, Caption, Close }

    /// <summary>Windows 11의 아이콘 글꼴(없으면 Windows 10의 것). 창 단추(최소화 · 최대화 · 닫기)도 이 글꼴의 것이다.</summary>
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    private static readonly ControlTemplate Rounded = MakeTemplate(6);
    private static readonly ControlTemplate Square = MakeTemplate(0);

    private readonly Kinds kind;
    private readonly TextBlock glyph;
    private ChromeColors colors = ChromeColors.Light;
    private bool on;

    public ChromeButton(string icon, string tip, Kinds kind = Kinds.Tool)
    {
        this.kind = kind;
        glyph = new TextBlock
        {
            Text = icon, FontFamily = Icons, FontSize = kind == Kinds.Tool ? 15 : 10,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        Content = glyph;
        Template = kind == Kinds.Tool ? Rounded : Square;
        Width = kind == Kinds.Tool ? 34 : 46;
        Height = kind == Kinds.Tool ? 30 : TitleBar.BarHeight;
        // 도구 단추는 막대 가운데(위아래 5), 창 단추는 막대 높이를 다 쓴다(Windows의 창 단추처럼 모서리까지).
        Margin = kind == Kinds.Tool ? new Thickness(1, 5, 1, 5) : new Thickness(0);
        VerticalAlignment = VerticalAlignment.Top;
        Focusable = false;
        IsTabStop = false;
        ToolTip = tip;
        ToolTipService.SetInitialShowDelay(this, 500);
        AutomationProperties.SetName(this, tip);
        WindowChrome.SetIsHitTestVisibleInChrome(this, true);
        Refresh();
    }

    public string Icon
    {
        get => glyph.Text;
        set => glyph.Text = value;
    }

    /// <summary>켜진 단추(목차 · 원본 보기) — 옅게 칠해 둔다.</summary>
    public bool IsOn
    {
        get => on;
        set
        {
            on = value;
            Refresh();
        }
    }

    public void Apply(ChromeColors next)
    {
        colors = next;
        Refresh();
    }

    protected override void OnMouseEnter(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        Refresh();
    }

    protected override void OnMouseLeave(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        Refresh();
    }

    protected override void OnIsPressedChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnIsPressedChanged(e);
        Refresh();
    }

    private void Refresh()
    {
        var hover = IsMouseOver;
        if (kind == Kinds.Close && hover)
        {
            // Windows의 닫기 단추와 같은 빨강.
            Background = new SolidColorBrush(IsPressed ? Color.FromRgb(0x94, 0x1B, 0x0C) : Color.FromRgb(0xC4, 0x2B, 0x1C));
            Foreground = Brushes.White;
            return;
        }
        var amount = IsPressed ? 0.14 : hover ? 0.08 : on ? 0.09 : 0;
        Background = amount == 0 ? Brushes.Transparent : new SolidColorBrush(colors.Tint(amount));
        Foreground = new SolidColorBrush(on ? colors.Text : ChromeColors.Blend(colors.Text, colors.Background, 0.82));
    }

    private static ControlTemplate MakeTemplate(double radius)
    {
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(BackgroundProperty));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        return new ControlTemplate(typeof(Button)) { VisualTree = border };
    }
}

/// <summary>
/// 제목 막대 — 창의 맨 위 한 줄에 제목 · 도구 단추 · 창 단추. 전의 메뉴 막대(파일 · 편집 · 보기 …)와 아래 상태 줄을 대신한다(사용자 —
/// "디자인이 별로인데… loomm.ai/mark 이거 느낌"). 메뉴는 오른쪽 끝의 <c>…</c>(F10)에 모두 있고, 명령 팔레트(Ctrl+Shift+P)도 같다.
/// macOS판의 도구 막대(사이드바 · 검색 · 보기 · 버거 메뉴)와 같은 자리다.
///
/// 창의 테두리 안을 다 쓴다(<see cref="WindowChrome"/>) — 빈 자리를 끌면 창이 움직이고, 두 번 누르면 최대화, 오른쪽 단추는 시스템 메뉴.
/// </summary>
public sealed class TitleBar : Grid
{
    public const double BarHeight = 40;

    // Segoe Fluent Icons의 글자 — 목차(글머리 목록) · 찾기 · 코드 · 폴더 열기 · 더 보기 · 최소화 · 최대화 · 이전 크기 · 닫기.
    private const string OutlineIcon = "\uE8FD";
    private const string SearchIcon = "\uE721";
    private const string SourceIcon = "\uE943";
    private const string OpenIcon = "\uED25";
    private const string MoreIcon = "\uE712";
    private const string MinimizeIcon = "\uE921";
    private const string MaximizeIcon = "\uE922";
    private const string RestoreIcon = "\uE923";
    private const string CloseIcon = "\uE8BB";

    public ChromeButton Outline { get; } = new(OutlineIcon, "목차 (Ctrl+Shift+O)");
    public ChromeButton Search { get; } = new(SearchIcon, "찾기 (Ctrl+F)");
    public ChromeButton Source { get; } = new(SourceIcon, "원본 보기 (Ctrl+E)");
    public ChromeButton Open { get; } = new(OpenIcon, "열기 (Ctrl+O) · 빠른 열기 Ctrl+Alt+O");
    public ChromeButton More { get; } = new(MoreIcon, "메뉴 (F10) — 파일 · 편집 · 서식 · 보기 · 도구 · 도움말");
    public ChromeButton Minimize { get; } = new(MinimizeIcon, "최소화", ChromeButton.Kinds.Caption);
    public ChromeButton Maximize { get; } = new(MaximizeIcon, "최대화", ChromeButton.Kinds.Caption);
    public ChromeButton CloseButton { get; } = new(CloseIcon, "닫기", ChromeButton.Kinds.Close);

    private readonly TextBlock name = new()
    {
        FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
        Margin = new Thickness(6, 0, 0, 0),
    };
    private readonly TextBlock dirty = new() { Text = "●", FontSize = 8, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 1, 0, 0) };
    private readonly StackPanel notes = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private ChromeColors colors = ChromeColors.Light;
    private IReadOnlyList<string> noteTexts = [];

    public TitleBar()
    {
        Height = BarHeight;
        foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
        {
            ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }
        var font = new FontFamily("Segoe UI Variable Text, Segoe UI, Malgun Gothic");
        name.FontFamily = font;
        Outline.Margin = new Thickness(8, 5, 1, 5);
        Add(Outline, 0);

        // 제목 자리는 누르지 않는다 — 창을 끄는 자리다(WindowChrome의 제목 영역).
        var title = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        title.Children.Add(name);
        title.Children.Add(dirty);
        title.Children.Add(notes);
        Add(title, 1);

        var tools = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 6, 0) };
        foreach (var button in new[] { Search, Source, Open, More }) tools.Children.Add(button);
        Add(tools, 2);

        var caption = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var button in new[] { Minimize, Maximize, CloseButton }) caption.Children.Add(button);
        Add(caption, 3);

        Apply(ChromeColors.Light);

        void Add(UIElement element, int column)
        {
            SetColumn(element, column);
            Children.Add(element);
        }
    }

    public ChromeColors Colors => colors;

    /// <summary>확인 실행이 본다 — 제목 옆의 작은 표시.</summary>
    public IReadOnlyList<string> Notes => noteTexts;

    public void Apply(ChromeColors next)
    {
        colors = next;
        Background = new SolidColorBrush(next.Background);
        name.Foreground = new SolidColorBrush(ChromeColors.Blend(next.Text, next.Background, 0.86));
        dirty.Foreground = new SolidColorBrush(next.Dim);
        foreach (var button in new[] { Outline, Search, Source, Open, More, Minimize, Maximize, CloseButton }) button.Apply(next);
        RenderNotes();
    }

    public void SetTitle(string title, bool isDirty, IReadOnlyList<string> notesNow)
    {
        name.Text = title;
        dirty.Visibility = isDirty ? Visibility.Visible : Visibility.Collapsed;
        noteTexts = notesNow;
        RenderNotes();
    }

    public void SetMaximized(bool maximized)
    {
        Maximize.Icon = maximized ? RestoreIcon : MaximizeIcon;
        Maximize.ToolTip = maximized ? "이전 크기로" : "최대화";
    }

    private void RenderNotes()
    {
        notes.Children.Clear();
        foreach (var note in noteTexts)
        {
            notes.Children.Add(new Border
            {
                Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(7, 1, 7, 2), CornerRadius = new CornerRadius(5),
                Background = new SolidColorBrush(colors.Tint(0.07)), VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = note, FontSize = 11, Foreground = new SolidColorBrush(colors.Dim), FontFamily = name.FontFamily },
            });
        }
    }
}
