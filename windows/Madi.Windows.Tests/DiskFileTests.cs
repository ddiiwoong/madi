using System.IO;
using System.Text;
using Madi;
using Xunit;

namespace Madi.Tests;

public sealed class DiskBaselineTests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "madi-tests-" + Guid.NewGuid().ToString("N"));

    public DiskBaselineTests() => Directory.CreateDirectory(folder);

    public void Dispose() => Directory.Delete(folder, recursive: true);

    private string Write(string name, byte[] bytes)
    {
        var path = Path.Combine(folder, name);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);

    private static void Append(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        stream.Write(bytes);
    }

    [Fact]
    public void 끝에_붙은_것은_붙은_바이트만_읽는다()
    {
        var head = Utf8(string.Concat(Enumerable.Repeat("앞줄입니다 INFO 2026-11-22\n", 400)));
        var path = Write("app.log", head);
        using var baseline = DiskBaseline.From(head);
        Append(path, Utf8("더한 줄\n"));
        var change = baseline.Detect(path);
        Assert.Equal(DiskChangeKind.Appended, change.Kind);
        Assert.Equal(Utf8("더한 줄\n"), change.Bytes);
        Assert.Equal(DiskChangeKind.Unchanged, baseline.Detect(path).Kind);
        Append(path, Utf8("또\n"));
        Assert.Equal(Utf8("또\n"), baseline.Detect(path).Bytes);
    }

    [Fact]
    public void 수정_시각만_바뀐_것은_그대로다()
    {
        var bytes = Utf8("하나\n둘\n");
        var path = Write("a.md", bytes);
        using var baseline = DiskBaseline.From(bytes);
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(5));
        Assert.Equal(DiskChangeKind.Unchanged, baseline.Detect(path).Kind);
    }

    [Fact]
    public void 같은_길이로_바꿔_쓰거나_줄거나_끝_조각이_바뀌면_통째로()
    {
        var bytes = Utf8("하나\n둘\n");
        var path = Write("a.md", bytes);
        using var baseline = DiskBaseline.From(bytes);
        File.WriteAllBytes(path, Utf8("하나\n셋\n"));
        var rewritten = baseline.Detect(path);
        Assert.Equal(DiskChangeKind.Replaced, rewritten.Kind);
        Assert.Equal(Utf8("하나\n셋\n"), rewritten.Bytes);
        File.WriteAllBytes(path, Utf8("하나\n"));
        Assert.Equal(DiskChangeKind.Replaced, baseline.Detect(path).Kind);
        File.WriteAllBytes(path, Utf8("둘\n하나\n더\n"));
        Assert.Equal(DiskChangeKind.Replaced, baseline.Detect(path).Kind);
    }

    [Fact]
    public void 지워지면_없음_같은_것으로_다시_생기면_그대로()
    {
        var bytes = Utf8("내용\n");
        var path = Write("a.md", bytes);
        using var baseline = DiskBaseline.From(bytes);
        File.Delete(path);
        Assert.Equal(DiskChangeKind.Missing, baseline.Detect(path).Kind);
        File.WriteAllBytes(path, bytes);
        Assert.Equal(DiskChangeKind.Unchanged, baseline.Detect(path).Kind);
    }

    [Fact]
    public void 쓰는_프로그램이_열어_둔_로그도_읽는다()
    {
        var path = Write("live.log", Utf8("시작\n"));
        using var baseline = DiskBaseline.From(Utf8("시작\n"));
        using var writer = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
        writer.Write(Utf8("줄\n"));
        writer.Flush();
        var change = baseline.Detect(path);
        Assert.Equal(DiskChangeKind.Appended, change.Kind);
        Assert.Equal(Utf8("줄\n"), change.Bytes);
    }

    [Fact]
    public void 저장은_임시_파일을_거쳐_바꿔_넣고_남기지_않는다()
    {
        var path = Path.Combine(folder, "새 글.md");
        AtomicFile.Write(path, Utf8("처음\n"));
        Assert.Equal(Utf8("처음\n"), File.ReadAllBytes(path));
        AtomicFile.Write(path, Utf8("다시\r\n"));
        Assert.Equal(Utf8("다시\r\n"), File.ReadAllBytes(path));
        Assert.Single(Directory.GetFiles(folder));
    }

    [Fact]
    public void 켤_때_받은_것()
    {
        var options = LaunchOptions.Parse(["--smoke", "out", "문서.md", "둘째.md"]);
        Assert.Equal(Path.GetFullPath("out"), options.SmokeDirectory);
        Assert.Equal(Path.GetFullPath("문서.md"), options.FilePath);
        Assert.Null(LaunchOptions.Parse([]).FilePath);
    }
}
