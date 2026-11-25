using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using Madi;
using Xunit;

namespace Madi.Tests;

/// <summary>3단계 껍데기의 규칙 — madi:// 링크, 새 판 확인, PDF의 쪽, LLM 키 확인 · 저장, 한 번만 켜기.</summary>
public sealed class Stage3Tests
{
    private const string Home = @"C:\Users\마디";

    private static MadiUrl.Command Parse(string url) => MadiUrl.Parse(url, Home);

    private static string Fails(string url) => Assert.Throws<MadiUrl.Failure>(() => Parse(url)).Message;

    [Fact]
    public void 링크_open은_줄과_찾을_말을_읽고_경로의_점점은_푼_뒤에_확장자를_본다()
    {
        Assert.Equal(new MadiUrl.Open(@"C:\notes\회의.md", 3, "다음 주"),
            Parse("madi://open?path=C%3A%5Cnotes%5C%ED%9A%8C%EC%9D%98.md&line=3&search=%EB%8B%A4%EC%9D%8C%20%EC%A3%BC"));
        Assert.Equal(new MadiUrl.Open(@"C:\notes\a.md", null, null), Parse("madi:open?path=C:/notes/x/../a.md"));
        Assert.Equal(new MadiUrl.Open(@"C:\a b.md", null, null), Parse("madi:///open?path=file:///C:/a%20b.md"));
        Assert.Equal(new MadiUrl.Open(Path.Combine(Home, "메모", "a.txt"), null, null), Parse(@"madi://open?path=~\메모\a.txt"));
        Assert.Equal(new MadiUrl.Open(@"C:\a.md", null, null), Parse("MADI://OPEN/?path=C:\\a.md&path=C:\\b.md"));
        Assert.Contains("1 이상의 정수", Fails("madi://open?path=C:\\a.md&line=0"));
        Assert.Contains("1 이상의 정수", Fails("madi://open?path=C:\\a.md&line=+2"));
        Assert.Contains("드라이브부터", Fails("madi://open?path=notes\\a.md"));
        Assert.Contains("드라이브부터", Fails("madi://open?path=\\a.md"));
        Assert.Contains("마크다운", Fails("madi://open?path=C:\\notes\\..\\Windows\\win.ini"));
        Assert.Contains("마크다운", Fails("madi://open?path=C:\\Users\\me\\.ssh\\config"));
        Assert.Contains("'path'", Fails("madi://open"));
    }

    [Fact]
    public void 링크는_네트워크_경로를_받지_않는다()
    {
        foreach (var path in new[] { @"\\server\share\a.md", "//server/share/a.md", "file://server/share/a.md", @"\\?\UNC\server\share\a.md",
                     @"\\.\pipe\a.md" })
        {
            Assert.Contains("네트워크 경로", Fails("madi://open?path=" + Uri.EscapeDataString(path)));
        }
    }

    [Fact]
    public void 링크_new와_append_더하기_기호와_퍼센트는_글_그대로()
    {
        Assert.Equal(new MadiUrl.New("a+b 100% #태그", null, null), Parse("madi://new?text=a+b%20100%%20#태그"));
        Assert.Equal(new MadiUrl.New("", "회의", @"C:\a.md"), Parse("madi://new?title=%ED%9A%8C%EC%9D%98&path=C:\\a.md"));
        Assert.Equal(new MadiUrl.New("글", null, null), Parse("madi://new?text=글&title=%20%20"));
        Assert.Equal(new MadiUrl.Append(@"C:\a.md", "- [ ] 우유"), Parse("madi://append?path=C:\\a.md&text=-%20%5B%20%5D%20%EC%9A%B0%EC%9C%A0"));
        Assert.Contains("'text'", Fails("madi://append?path=C:\\a.md&text="));
        Assert.Contains("모르는 명령", Fails("madi://delete?path=C:\\a.md"));
        Assert.Contains("명령이 없습니다", Fails("madi://?path=C:\\a.md"));
        Assert.Contains("madi:// 주소가 아닙니다", Fails("https://example.com"));
        Assert.Equal("# 제목\n\n", MadiUrl.NewDocumentText("", "제목", asFile: true));
        Assert.Equal("# 제목\n\n", MadiUrl.NewDocumentText("", "제목", asFile: false));
        Assert.Equal("글\n", MadiUrl.NewDocumentText("글", null, asFile: true));
        Assert.Equal("", MadiUrl.NewDocumentText("", null, asFile: true));
    }

    [Fact]
    public void 켤_때_링크와_파일을_나눠_받는다()
    {
        var options = LaunchOptions.Parse(["--instance", "smoke", "madi://open?path=C:\\a.md", "문서.md"]);
        Assert.Equal("smoke", options.Instance);
        Assert.Equal(new[] { "madi://open?path=C:\\a.md" }, options.Urls);
        Assert.Equal(new[] { Path.GetFullPath("문서.md"), "madi://open?path=C:\\a.md" }, options.Forwarded);
    }

    private static string Release(string tag, string? assetName = null, string html = "https://github.com/ddiiwoong/madi/releases/tag/v0.2.0",
        string download = "https://github.com/ddiiwoong/madi/releases/download/v0.2.0/", bool prerelease = false)
    {
        var name = assetName ?? ReleaseFeed.InstallerName(tag);
        return $$"""
            {"tag_name":"{{tag}}","draft":false,"prerelease":{{(prerelease ? "true" : "false")}},"html_url":"{{html}}",
             "assets":[{"name":"Madi-0.2.0.zip","browser_download_url":"https://github.com/ddiiwoong/madi/releases/download/v0.2.0/Madi-0.2.0.zip"},
                       {"name":"{{name}}","browser_download_url":"{{download}}{{name}}","digest":"sha256:{{new string('A', 64)}}"}]}
            """;
    }

    [Fact]
    public void 새_판은_Windows판_파일이_있고_판이_높을_때만()
    {
        var current = ReleaseVersion.Parse("0.1.4")!;
        var release = ReleaseFeed.Parse(Release("v0.2.0"));
        Assert.Equal("Madi-0.2.0-windows-x64-setup.exe", ReleaseFeed.InstallerName("v0.2.0"));
        Assert.NotNull(release.Installer);
        Assert.Equal(new string('a', 64), release.InstallerSha256);
        Assert.True(ReleaseFeed.IsNewer(release, current));
        Assert.False(ReleaseFeed.IsNewer(release, ReleaseVersion.Parse("0.2")!), "0.2와 0.2.0은 같은 판");
        var macOnly = ReleaseFeed.Parse(Release("v0.2.0", assetName: "Madi-0.2.0.dmg"));
        Assert.Null(macOnly.Installer);
        Assert.False(ReleaseFeed.IsNewer(macOnly, current), "macOS판만 낸 판은 Windows판의 새 판이 아니다");
        Assert.Throws<ReleaseFeed.ParseError>(() => ReleaseFeed.Parse(Release("v0.2.0", prerelease: true)));
        Assert.Throws<ReleaseFeed.ParseError>(() => ReleaseFeed.Parse(Release("v0.2.0-beta")));
        Assert.Throws<ReleaseFeed.ParseError>(() => ReleaseFeed.Parse(Release("v0.2.0", html: "https://evil.example/ddiiwoong/madi/releases")));
        Assert.Throws<ReleaseFeed.ParseError>(() => ReleaseFeed.Parse(Release("v0.2.0", download: "http://github.com/ddiiwoong/madi/releases/download/v0.2.0/")));
        Assert.Throws<ReleaseFeed.ParseError>(() => ReleaseFeed.Parse("[]"));
        Assert.True(ReleaseVersion.Parse("v0.10.0")! > ReleaseVersion.Parse("0.9.9")!);
        Assert.Null(ReleaseVersion.Parse("1.2.3.4.5"));
        Assert.Null(ReleaseVersion.Parse("1..2"));
    }

    [Fact]
    public void 새_판_확인은_하루에_한_번_시계를_되돌리면_다시()
    {
        var now = new DateTimeOffset(2026, 11, 23, 9, 0, 0, TimeSpan.Zero);
        Assert.True(ReleaseFeed.IsCheckDue(null, now));
        Assert.False(ReleaseFeed.IsCheckDue(now.AddHours(-23), now));
        Assert.True(ReleaseFeed.IsCheckDue(now.AddHours(-24), now));
        Assert.True(ReleaseFeed.IsCheckDue(now.AddMinutes(5), now));
    }

    [Fact]
    public void PDF의_쪽은_macOS판과_같은_값()
    {
        var korea = new RegionInfo("KR");
        var us = new RegionInfo("US");
        var a4 = PrintLayout.From("a4", "landscape", "wide", null, us);
        Assert.Equal(210 / 25.4, a4.PageWidth, 6);
        Assert.Equal(297 / 25.4, a4.PageHeight, 6);
        Assert.True(a4.Landscape);
        Assert.Equal(84.0 / 72, a4.Margin, 6);
        var fallback = PrintLayout.From("system", null, null, null, korea);
        Assert.Equal((210 / 25.4, 297 / 25.4), (fallback.PageWidth, fallback.PageHeight));
        Assert.Equal(48.0 / 72, fallback.Margin, 6);
        Assert.False(fallback.Landscape);
        Assert.Equal((8.5, 11.0), (PrintLayout.From("system", null, "narrow", null, us).PageWidth, 11.0));
        Assert.Equal(24.0 / 72, PrintLayout.From("letter", null, "narrow", null, korea).Margin, 6);
        var printer = PrintLayout.From("system", "portrait", null, (11.69, 8.27), us);
        Assert.Equal((8.27, 11.69), (printer.PageWidth, printer.PageHeight));
    }

    [Fact]
    public void LLM_키_확인은_서비스마다_헤더가_다르고_문서를_싣지_않는다()
    {
        using var anthropic = LlmService.Anthropic.ModelListRequest("  sk-ant  ")!;
        Assert.Equal(HttpMethod.Get, anthropic.Method);
        Assert.Null(anthropic.Content);
        Assert.Equal("sk-ant", anthropic.Headers.GetValues("x-api-key").Single());
        Assert.Equal("2023-06-01", anthropic.Headers.GetValues("anthropic-version").Single());
        using var gemini = LlmService.Gemini.ModelListRequest("g")!;
        Assert.Equal("g", gemini.Headers.GetValues("x-goog-api-key").Single());
        Assert.DoesNotContain("key=", gemini.RequestUri!.Query);
        using var groq = LlmService.Groq.ModelListRequest("q")!;
        Assert.Equal("Bearer q", groq.Headers.Authorization!.ToString());
        using var bedrock = LlmService.Bedrock.ModelListRequest("b", "ap-northeast-2")!;
        Assert.Equal("https://bedrock.ap-northeast-2.amazonaws.com/foundation-models", bedrock.RequestUri!.AbsoluteUri);
        Assert.Null(LlmService.Bedrock.ModelListRequest("b", "evil.com/x?"));
        Assert.Null(LlmService.OpenAI.ModelListRequest("   "));
        Assert.Equal(new[] { "gemini-3.5-flash-lite", "x" }, LlmService.Gemini.ModelIds("""{"models":[{"name":"models/gemini-3.5-flash-lite"},{"name":"x"}]}"""));
        Assert.Equal(new[] { "amazon.nova-lite-v1:0" }, LlmService.Bedrock.ModelIds("""{"modelSummaries":[{"modelId":"amazon.nova-lite-v1:0"}]}"""));
        Assert.Empty(LlmService.OpenAI.ModelIds("not json"));
        Assert.Equal("bad key", LlmServices.ErrorMessage("""{"error":{"message":"bad key"}}"""));
        Assert.Equal("nope", LlmServices.ErrorMessage("""{"Message":"nope"}"""));
    }

    private sealed class Replies(HttpStatusCode status, string body) : HttpMessageHandler
    {
        public HttpRequestMessage? Seen { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Seen = request;
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }

    [Fact]
    public async Task LLM_키_확인의_한_줄()
    {
        var ok = new Replies(HttpStatusCode.OK, """{"data":[{"id":"claude-haiku-5-5"},{"id":"claude-x"}]}""");
        Assert.Equal("키가 맞습니다 — 모델 2개, 권장 모델 claude-haiku-5-5 있음", await LlmService.Anthropic.CheckAsync("k", null, ok));
        Assert.Equal("https://api.anthropic.com/v1/models?limit=1000", ok.Seen!.RequestUri!.AbsoluteUri);
        var other = new Replies(HttpStatusCode.OK, """{"data":[{"id":"gpt-4"}]}""");
        Assert.Contains("목록에 권장 모델이 없습니다: gpt-5.5", await LlmService.OpenAI.CheckAsync("k", null, other));
        var rejected = new Replies(HttpStatusCode.Unauthorized, """{"error":{"message":"invalid x-api-key"}}""");
        Assert.Equal("키가 거절됐습니다 (HTTP 401): invalid x-api-key", await LlmService.Anthropic.CheckAsync("k", null, rejected));
        Assert.Contains("HTTP 500", await LlmService.Groq.CheckAsync("k", null, new Replies(HttpStatusCode.InternalServerError, "boom")));
    }

    [Fact]
    public void 키는_자격_증명_관리자에_두고_지울_수_있다()
    {
        var name = "tests/" + Guid.NewGuid().ToString("N");
        try
        {
            try
            {
                Assert.Null(CredentialStore.Read(name));
            }
            catch (System.ComponentModel.Win32Exception error) when (error.NativeErrorCode == 1312)
            {
                // ERROR_NO_SUCH_LOGON_SESSION — 사용자 프로필 없이 도는 서비스 세션(CI의 일부 러너)에는 자격 증명 관리자가 없다.
                Assert.Skip("이 세션에는 자격 증명 관리자가 없다");
            }
            CredentialStore.Write(name, "sk-한글-키");
            Assert.Equal("sk-한글-키", CredentialStore.Read(name));
            CredentialStore.Write(name, "둘째");
            Assert.Equal("둘째", CredentialStore.Read(name));
            Assert.True(CredentialStore.Delete(name));
            Assert.Null(CredentialStore.Read(name));
        }
        finally
        {
            CredentialStore.Delete(name);
        }
        Assert.False(CredentialStore.Delete(name));
    }

    [Fact]
    public async Task 한_번만_켜기_둘째는_넘기고_첫째가_받는다()
    {
        var name = "tests-" + Guid.NewGuid().ToString("N");
        using var first = new SingleInstance(name);
        Assert.True(first.IsPrimary);
        var received = new TaskCompletionSource<IReadOnlyList<string>>(TaskCreationOptions.RunContinuationsAsynchronously);
        first.Listen(items => received.TrySetResult(items));
        // 같은 프로세스 안이라 뮤텍스는 다시 얻는다 — 둘째 자리는 다른 스레드에서 연다.
        var forwarded = await Task.Run(() =>
        {
            using var second = new SingleInstance(name);
            return second.Forward([@"C:\a.md", "madi://open?path=C:\\a.md"], TimeSpan.FromSeconds(5));
        });
        Assert.True(forwarded);
        Assert.Equal(new[] { @"C:\a.md", "madi://open?path=C:\\a.md" }, await received.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Empty(SingleInstance.Decode(Encoding.UTF8.GetBytes("{\"x\":1}")));
        Assert.Empty(SingleInstance.Decode([0xff, 0xfe]));
        using var lonely = new SingleInstance("tests-" + Guid.NewGuid().ToString("N"));
        Assert.False(lonely.Forward(["x"], TimeSpan.FromMilliseconds(200)), "받는 마디가 없으면 넘기지 못한다");
    }
}
