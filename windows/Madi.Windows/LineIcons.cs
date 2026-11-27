using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Shape = System.Windows.Shapes.Path;

namespace Madi;

/// <summary>
/// 메뉴 막대의 서식 단추 아이콘 — 편집기의 서식 막대(<c>editor/formatbar.ts</c>)와 같은 lucide 1.79.0 아이콘(ISC, 라이선스는
/// <c>editor\THIRD-PARTY.txt</c>). 24×24 칸의 선 그림이라 WPF의 길(<see cref="Geometry"/>)로 그대로 옮겼다.
///
/// 옮길 때 하나 고쳤다: lucide의 SVG 길은 호(<c>a</c>)의 두 깃발을 붙여 쓴다(<c>a4 4 0 010 8</c> = 깃발 0 · 1, 끝점 0,8). WPF의 길
/// 문법은 그것을 수 <c>010</c>으로 읽으므로 깃발 · 수를 모두 띄어 썼다. 시험(<c>MenuBarTests</c>)이 아이콘마다 24×24 칸 안에 드는지 본다.
/// </summary>
public static class LineIcons
{
    /// <summary>둥근 모서리 사각형 — <c>rect x y width height rx</c>.</summary>
    private sealed record Box(double X, double Y, double Width, double Height, double Radius);

    private static readonly Dictionary<string, object[]> Shapes = new()
    {
        ["heading"] = ["M18,20 V4", "M6,12 H18", "M6,20 V4"],
        ["bold"] = ["M6,12 h9 a4,4 0 0 1 0,8 H7 a1,1 0 0 1 -1,-1 V5 a1,1 0 0 1 1,-1 h7 a4,4 0 0 1 0,8"],
        ["italic"] = ["M19,4 L10,4", "M14,20 L5,20", "M15,4 L9,20"],
        ["strikethrough"] = ["M16,4 H9 a3,3 0 0 0 -2.83,4", "M14,12 a4,4 0 0 1 0,8 H6", "M4,12 L20,12"],
        ["code"] = ["M16,18 l6,-6 l-6,-6", "M8,6 l-6,6 l6,6"],
        ["link"] =
        [
            "M10,13 a5,5 0 0 0 7.54,0.54 l3,-3 a5,5 0 0 0 -7.07,-7.07 l-1.72,1.71",
            "M14,11 a5,5 0 0 0 -7.54,-0.54 l-3,3 a5,5 0 0 0 7.07,7.07 l1.71,-1.71",
        ],
        ["bullet"] = ["M3,5 h0.01", "M3,12 h0.01", "M3,19 h0.01", "M8,5 h13", "M8,12 h13", "M8,19 h13"],
        ["numbered"] =
        [
            "M11,5 h10", "M11,12 h10", "M11,19 h10", "M4,4 h1 v5", "M4,9 h2",
            "M6.5,20 H3.4 c0,-1 2.6,-1.925 2.6,-3.5 a1.5,1.5 0 0 0 -2.6,-1.02",
        ],
        ["task"] = ["M13,5 h8", "M13,12 h8", "M13,19 h8", "M3,17 l2,2 l4,-4", "M3,7 l2,2 l4,-4"],
        ["quote"] = ["M17,5 H3", "M21,12 H8", "M21,19 H8", "M3,12 v7"],
        ["codeBlock"] = ["M10,9 l-3,3 l3,3", "M14,15 l3,-3 l-3,-3", new Box(3, 3, 18, 18, 2)],
        ["table"] = ["M12,3 v18", new Box(3, 3, 18, 18, 2), "M3,9 h18", "M3,15 h18"],
        ["rule"] = ["M16,16 l-4,4 l-4,-4", "M3,12 h18", "M8,8 l4,-4 l4,4"],
        ["chevron"] = ["M6,9 l6,6 l6,-6"],
    };

    public static IEnumerable<string> Names => Shapes.Keys;

    /// <summary>아이콘의 길들 — 시험이 칸을 잰다.</summary>
    public static IReadOnlyList<Geometry> Geometries(string name) =>
        Shapes[name].Select(shape => shape switch
        {
            string data => Geometry.Parse(data),
            Box box => (Geometry)new RectangleGeometry(new Rect(box.X, box.Y, box.Width, box.Height), box.Radius, box.Radius),
            _ => throw new InvalidOperationException(name),
        }).ToList();

    /// <summary>그린 아이콘 — 한 변 <paramref name="size"/>, 선은 lucide처럼 2(24 칸 기준)에 둥근 끝.</summary>
    public static IconView Make(string name, double size = 16) => new(Geometries(name), size);
}

/// <summary>아이콘 하나 — 선 색은 <see cref="Paint"/>로(단추가 글자색을 바꿀 때 함께).</summary>
public sealed class IconView : Viewbox
{
    private readonly List<Shape> paths = [];

    internal IconView(IEnumerable<Geometry> geometries, double size)
    {
        Width = size;
        Height = size;
        Stretch = Stretch.Uniform;
        var canvas = new Canvas { Width = 24, Height = 24 };
        foreach (var geometry in geometries)
        {
            var path = new Shape
            {
                Data = geometry, StrokeThickness = 2, StrokeLineJoin = PenLineJoin.Round,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
            };
            paths.Add(path);
            canvas.Children.Add(path);
        }
        Child = canvas;
        IsHitTestVisible = false;
    }

    public void Paint(Brush brush)
    {
        foreach (var path in paths) path.Stroke = brush;
    }

    /// <summary>단추 안의 아이콘(하나, 또는 패널 안의 여럿)을 모두 칠한다.</summary>
    public static void PaintAll(object? content, Brush brush)
    {
        switch (content)
        {
            case IconView icon:
                icon.Paint(brush);
                break;
            case Panel panel:
                foreach (var child in panel.Children) PaintAll(child, brush);
                break;
        }
    }
}
