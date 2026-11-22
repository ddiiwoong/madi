using System.Globalization;

namespace Madi;

/// <summary>
/// PDF의 쪽 — 설정의 용지 · 방향 · 여백(macOS판 <c>printInfo</c>와 같은 값: 여백 24 · 48 · 84pt, A4 210×297mm, Letter 8.5×11in)을
/// WebView2의 프린트 설정(인치)으로. 프린트 창은 편집기의 <c>@page</c> 규칙(<c>src/core/output.ts</c>)이 같은 값을 준다.
/// </summary>
public sealed record PrintLayout(double PageWidth, double PageHeight, bool Landscape, double Margin)
{
    /// <summary>세로 크기(인치). 방향은 따로 준다 — 가로 크기에 가로 방향까지 주면 두 번 돈다(macOS판에서 적어 둔 것과 같다).</summary>
    public static readonly (double Width, double Height) A4 = (210 / 25.4, 297 / 25.4);
    public static readonly (double Width, double Height) Letter = (8.5, 11);

    /// <param name="systemPaper">기본 프린터의 용지(세로, 인치). 모르면 null — 지역이 미터법이면 A4, 아니면 Letter.</param>
    public static PrintLayout From(string? paper, string? orientation, string? margin, (double Width, double Height)? systemPaper,
        RegionInfo region)
    {
        var size = paper switch
        {
            "a4" => A4,
            "letter" => Letter,
            _ => systemPaper ?? (region.IsMetric ? A4 : Letter),
        };
        // 기본 프린터가 가로 용지를 주면 세로로 세운다.
        if (size.Width > size.Height) size = (size.Height, size.Width);
        var points = margin switch { "narrow" => 24.0, "wide" => 84.0, _ => 48.0 };
        return new PrintLayout(size.Width, size.Height, orientation == "landscape", points / 72);
    }
}
