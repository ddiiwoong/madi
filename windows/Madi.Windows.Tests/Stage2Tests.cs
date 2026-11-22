using System.IO;
using System.Text;
using System.Text.Json;
using Madi;
using Xunit;

namespace Madi.Tests;

/// <summary>2단계 껍데기의 규칙 — 빠른 열기의 후보, 그림 경로, 설정 · 최근 파일.</summary>
public sealed class Stage2Tests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "madi-tests-" + Guid.NewGuid().ToString("N"));

    public Stage2Tests() => Directory.CreateDirectory(folder);

    public void Dispose() => Directory.Delete(folder, recursive: true);

    private string Touch(params string[] parts)
    {
        var path = Path.Combine(new[] { folder }.Concat(parts).ToArray());
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "x");
        return path;
    }

    [Fact]
    public void 빠른_열기는_건너뛸_폴더와_숨은_것을_빼고_열_수_있는_파일만()
    {
        var keep = new[]
        {
            Touch("a.md"), Touch("docs", "b.markdown"), Touch("docs", "deep", "c.txt"), Touch("logs", "d.log"),
        };
        Touch("node_modules", "x.md");
        Touch("vendor", "y.md");
        Touch("note.assets", "z.md");
        Touch(".git", "w.md");
        Touch("picture.png");
        var hidden = Touch("hidden.md");
        File.SetAttributes(hidden, FileAttributes.Hidden);
        var found = QuickOpenSources.FolderFiles(folder);
        Assert.Equal(keep.Order(StringComparer.OrdinalIgnoreCase), found);
    }

    [Fact]
    public void 빠른_열기는_상한에서_멈춘다()
    {
        for (var i = 0; i < 30; i++) Touch($"n{i:00}.md");
        Assert.Equal(10, QuickOpenSources.FolderFiles(folder, limit: 10).Count);
        Assert.True(QuickOpenSources.FolderFiles(folder, visitLimit: 5).Count <= 5);
    }

    [Fact]
    public void 후보는_열린_것_최근_폴더_차례로_한_번씩_둘째_줄은_폴더_기준_위치()
    {
        var home = Path.Combine(folder, "home");
        var root = Path.Combine(home, "notes");
        var open = Path.Combine(root, "a.md");
        var recent = Path.Combine(home, "other", "b.md");
        var inFolder = Path.Combine(root, "sub", "c.md");
        var outside = Path.Combine(Path.GetPathRoot(folder)!, "elsewhere", "d.md");
        var candidates = QuickOpenSources.Candidates(new[] { open }, new[] { recent, open.ToUpperInvariant(), outside },
            new[] { open, inFolder }, root, home);
        Assert.Equal(new[] { open, recent, outside, inFolder }, candidates.Select(candidate => candidate.Path));
        Assert.Equal(
            new[] { "notes", $"~{Path.DirectorySeparatorChar}other", Path.GetDirectoryName(outside)!, $"notes{Path.DirectorySeparatorChar}sub" },
            candidates.Select(candidate => candidate.Detail));
        Assert.Equal("~", QuickOpenSources.Detail(Path.Combine(home, "e.md"), null, home));
    }

    [Fact]
    public void 그림_경로는_문서_폴더_기준이고_절대_경로와_file_주소도_받는다()
    {
        var home = Path.Combine(folder, "home");
        var document = Path.Combine(folder, "docs", "글.md");
        Assert.Equal(Path.Combine(folder, "docs", "그림", "a.png"), ImageFiles.Resolve("그림/a.png", document, home));
        Assert.Equal(Path.Combine(folder, "b.png"), ImageFiles.Resolve("../b.png", document, home));
        Assert.Equal(Path.Combine(home, "c.png"), ImageFiles.Resolve("~/c.png", document, home));
        var absolute = Path.Combine(folder, "abs", "d.png");
        Assert.Equal(absolute, ImageFiles.Resolve(absolute, document, home));
        Assert.Equal(absolute, ImageFiles.Resolve(new Uri(absolute).AbsoluteUri, document, home));
        Assert.Null(ImageFiles.Resolve("a.png", null, home));
        Assert.Null(ImageFiles.Resolve("  ", document, home));
    }

    [Fact]
    public void 그림은_그림_확장자만_읽어_data_주소로()
    {
        var document = Path.Combine(folder, "글.md");
        File.WriteAllBytes(Path.Combine(folder, "a.png"), [0x89, 0x50, 0x4e, 0x47]);
        File.WriteAllText(Path.Combine(folder, "secret.txt"), "비밀");
        Assert.Equal("data:image/png;base64,iVBORw==", ImageFiles.Load("a.png", document, folder));
        var notImage = Assert.Throws<InvalidOperationException>(() => ImageFiles.Load("secret.txt", document, folder));
        Assert.Contains("그림 파일이 아닙니다", notImage.Message);
        Assert.Throws<FileNotFoundException>(() => ImageFiles.Load("없음.png", document, folder));
        Assert.Throws<InvalidOperationException>(() => ImageFiles.Load("a.png", null, folder));
    }

    [Fact]
    public void 설정은_받은_그대로_저장하고_깨진_파일은_빈_설정()
    {
        var store = new SettingsStore(Path.Combine(folder, "settings"));
        Assert.Empty(store.Settings);
        using (var value = JsonDocument.Parse("""{"theme":"github","appearance":"dark","bodySize":16,"loadsRemoteImages":true,"모르는":[1]}"""))
        {
            Assert.True(store.Save(value.RootElement));
        }
        var again = new SettingsStore(store.Folder);
        Assert.Equal("github", again.Text("theme"));
        Assert.True(again.Flag("loadsRemoteImages"));
        Assert.False(again.Flag("collapsesFrontMatter"));
        Assert.True(again.Settings.ContainsKey("모르는"), "모르는 값도 지우지 않는다 — 편집기가 정한다");
        using (var array = JsonDocument.Parse("[1]"))
        {
            Assert.False(again.Save(array.RootElement));
        }
        File.WriteAllText(Path.Combine(store.Folder, "settings.json"), "{ 깨진", Encoding.UTF8);
        Assert.Empty(new SettingsStore(store.Folder).Settings);
    }

    [Fact]
    public void 최근_문서는_새것이_앞_같은_파일은_한_번_스무_개까지()
    {
        var store = new SettingsStore(Path.Combine(folder, "settings"));
        for (var i = 0; i < 25; i++) store.AddRecent(Path.Combine(folder, $"f{i}.md"));
        store.AddRecent(Path.Combine(folder, "F10.MD"));
        var recent = new SettingsStore(store.Folder).Recent;
        Assert.Equal(SettingsStore.RecentLimit, recent.Count);
        Assert.Equal(Path.Combine(folder, "F10.MD"), recent[0]);
        Assert.Equal(Path.Combine(folder, "f24.md"), recent[1]);
        Assert.DoesNotContain(Path.Combine(folder, "f10.md"), recent);
        store.ClearRecent();
        Assert.Empty(new SettingsStore(store.Folder).Recent);
    }
}
