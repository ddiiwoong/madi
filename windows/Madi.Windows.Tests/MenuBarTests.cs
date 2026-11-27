using Madi;
using Xunit;

namespace Madi.Tests;

/// <summary>메뉴 막대의 아이콘(<see cref="LineIcons"/>) — lucide의 SVG 길을 WPF의 길로 옮긴 것.</summary>
public sealed class MenuBarTests
{
    [Fact]
    public void 아이콘은_모두_24칸_안에_그려진다()
    {
        // 옮기다 틀리면(호의 깃발을 붙여 쓴 'a4 4 0 010 8'을 그대로 두면 WPF가 010을 수 하나로 읽는다) 길이 칸 밖으로 나간다.
        foreach (var name in LineIcons.Names)
        {
            foreach (var geometry in LineIcons.Geometries(name))
            {
                var bounds = geometry.Bounds;
                Assert.False(bounds.IsEmpty, name);
                Assert.True(bounds.Left >= 0 && bounds.Top >= 0 && bounds.Right <= 24 && bounds.Bottom <= 24,
                    $"{name}: {bounds}");
            }
        }
    }

    [Fact]
    public void 굵게_아이콘은_lucide와_같은_자리에_있다()
    {
        // letter-b: 세로 줄은 x=6, 위 둥근 칸은 y=4~12, 아래 칸은 y=12~20, 오른쪽 끝은 x=4+15=19.
        var bold = LineIcons.Geometries("bold").Single().Bounds;
        Assert.Equal(6.0, bold.Left, 1);
        Assert.Equal(4.0, bold.Top, 1);
        Assert.Equal(20.0, bold.Bottom, 1);
        Assert.Equal(19.0, bold.Right, 1);
    }

    [Fact]
    public void 메뉴_막대가_쓰는_아이콘이_다_있다()
    {
        var known = LineIcons.Names.ToHashSet();
        foreach (var name in MenuBar.IconNames) Assert.Contains(name, known);
    }
}
