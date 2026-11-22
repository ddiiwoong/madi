using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Unicode;
using System.Threading.Channels;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Madi;

/// <summary>
/// 확인 실행 — <c>Madi.exe --smoke &lt;폴더&gt;</c>. 창 하나로 실제 길(파일 읽기 · 지켜보기 · 저장)을 지나며 본다:
/// <list type="number">
/// <item>시험 문서 다섯을 열어 편집기를 지나도 바이트가 그대로인지(UTF-8 · BOM · CRLF · UTF-16 · 섞인 줄 끝, CP949는 바뀜)</item>
/// <item>고쳐서 저장하면 BOM · CRLF가 그대로 남는지, 내가 쓴 것을 바깥 변경으로 읽지 않는지</item>
/// <item>로그(따라 보기)에 바깥에서 줄이 붙으면 따라가는지, 한 글자를 둘로 나눠 써도 한 번만 들어오는지</item>
/// <item>고친 것이 있는데 바깥에서 바뀌면 섞지 않고 묻는지(자동 저장을 멈추는지), '내 것 지키기'가 여기 것을 쓰는지</item>
/// <item>라이브 프리뷰와 목차를 켠 화면(<c>editor.png</c>)</item>
/// </list>
/// CI(<c>.github/workflows/windows.yml</c>)가 이것을 돌린다. 처음 다섯 문서는 <c>windows/editor/test/cases.ts</c>와 같은 바이트다.
/// </summary>
internal sealed class SmokeRun(MainWindow window, string directory)
{
    private sealed record Case(string Name, byte[] Bytes, string Encoding, bool Bom, string LineSeparator, string RoundTrip);

    private static byte[] Utf8(string text) => new UTF8Encoding(false).GetBytes(text);
    private static byte[] Join(params byte[][] parts) => parts.SelectMany(part => part).ToArray();

    private static readonly byte[] CrlfBom = Join([0xef, 0xbb, 0xbf], Utf8("# 메모장에서 저장한 글\r\n\r\n- 줄 끝은 CRLF\r\n- 맨 앞에 BOM\r\n"));
    private static readonly byte[] Showcase = Utf8(string.Join("\n",
        "# 마디 Windows 1단계",
        "",
        "**굵게**, *기울임*, `코드`, ~~취소선~~, [링크](https://github.com/ddiiwoong/madi).",
        "",
        "## 목록",
        "",
        "- 한글 · English · 日本語 · 😀",
        "  - 안쪽 목록",
        "- [ ] 할 일",
        "",
        "> 인용 — 캐럿이 없는 줄은 표식이 숨는다",
        "",
        "---",
        "",
        "### 코드",
        "",
        "```swift",
        "let 인사 = \"안녕\"",
        "```",
        ""));

    private static readonly Case[] Cases =
    [
        // "한글 메모\r\n"을 EUC-KR(CP949)로. 편집기는 읽되 그 꼴로 다시 쓰지는 않는다(저장은 UTF-8).
        new("cp949.txt", [0xc7, 0xd1, 0xb1, 0xdb, 0x20, 0xb8, 0xde, 0xb8, 0xf0, 0x0d, 0x0a], "euc-kr", false, "CRLF", "converted"),
        new("utf16le.txt", Join([0xff, 0xfe], Encoding.Unicode.GetBytes("메모장 UTF-16\r\n둘째 줄 😀\r\n")),
            "utf-16le", true, "CRLF", "exact"),
        new("mixed.log", Utf8("2026-11-22 10:00:01 INFO 시작\r\n2026-11-22 10:00:02 WARN 섞인 줄 끝\n끝\r"),
            "utf-8", false, "LF", "exact"),
        new("crlf-bom.md", CrlfBom, "utf-8", true, "CRLF", "exact"),
        new("lf-utf8.md", Utf8(string.Join("\n",
            "# 마디 Windows 0단계",
            "",
            "**굵게**, *기울임*, `코드`, [링크](https://github.com/ddiiwoong/madi).",
            "",
            "- 한글 · English · 日本語 · 😀",
            "- [ ] 할 일",
            "",
            "> 인용",
            "",
            "```swift",
            "let 인사 = \"안녕\"",
            "```",
            "")), "utf-8", false, "LF", "exact"),
    ];

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.Create(UnicodeRanges.All),
    };

    private readonly Channel<JsonElement> inbox = Channel.CreateUnbounded<JsonElement>();
    private readonly List<string> notes = [];
    private bool started;
    private DispatcherTimer? watchdog;

    public void Receive(JsonElement message) => inbox.Writer.TryWrite(message);

    public void Note(string message) => notes.Add(message);

    /// <summary>편집기가 3분 안에 끝내지 못하면(뜨지 않음, 답이 없음) 실패로 적고 닫는다.</summary>
    public void StartWatchdog()
    {
        watchdog = new DispatcherTimer { Interval = TimeSpan.FromMinutes(3) };
        watchdog.Tick += (_, _) =>
        {
            watchdog.Stop();
            WriteFailure("시간을 넘겼다 — 편집기가 준비되지 않았거나 답하지 않았다");
            window.Finish(2, TimeSpan.Zero);
        };
        watchdog.Start();
    }

    private static string? Field(JsonElement message, string name) =>
        message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool Flag(JsonElement message, string name) =>
        message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static int Number(JsonElement message, string name) =>
        message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetInt32() : -1;

    private async Task<JsonElement> WaitFor(string type, Func<JsonElement, bool>? match = null, double seconds = 15)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        try
        {
            while (true)
            {
                var message = await inbox.Reader.ReadAsync(timeout.Token);
                if (Field(message, "type") == type && (match?.Invoke(message) ?? true)) return message;
            }
        }
        catch (OperationCanceledException)
        {
            throw new TimeoutException($"{seconds}초 안에 '{type}'이 오지 않았다");
        }
    }

    private List<JsonElement> Drain()
    {
        var drained = new List<JsonElement>();
        while (inbox.Reader.TryRead(out var message)) drained.Add(message);
        return drained;
    }

    private static void AppendBytes(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        stream.Write(bytes);
    }

    private static string Sha(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    public async Task RunAsync(JsonElement ready)
    {
        if (started) return;
        started = true;
        var ok = true;
        var cases = new List<object>();
        var scenarios = new List<object>();

        void Check(string name, bool pass, object? detail = null)
        {
            ok &= pass;
            scenarios.Add(new { name, pass, detail });
        }

        async Task Scenario(string name, Func<Task> body)
        {
            try
            {
                await body();
            }
            catch (Exception error)
            {
                Check(name, false, error.Message);
            }
        }

        Directory.CreateDirectory(directory);

        // 1. 바이트 그대로
        await Scenario("열기 — 바이트 그대로", async () =>
        {
            foreach (var sample in Cases)
            {
                var path = Path.Combine(directory, sample.Name);
                await File.WriteAllBytesAsync(path, sample.Bytes);
                var reply = await window.LoadFileAsync(path).WaitAsync(TimeSpan.FromSeconds(30))
                            ?? throw new InvalidOperationException($"{sample.Name}: 답이 없다");
                var pass = Field(reply, "type") == "opened"
                    && Field(reply, "encoding") == sample.Encoding
                    && Flag(reply, "bom") == sample.Bom
                    && Field(reply, "lineSeparator") == sample.LineSeparator
                    && Field(reply, "roundTrip") == sample.RoundTrip
                    && (sample.RoundTrip != "exact" || Field(reply, "sha256") == Sha(sample.Bytes));
                ok &= pass;
                cases.Add(new { name = sample.Name, pass, reply });
            }
        });

        // 2. 고쳐서 저장 — BOM · CRLF가 남는다. 내가 쓴 것을 바깥 변경으로 읽지 않는다.
        await Scenario("저장", async () =>
        {
            var path = Path.Combine(directory, "edit.md");
            await File.WriteAllBytesAsync(path, CrlfBom);
            await window.LoadFileAsync(path);
            Drain();
            window.Post(new { type = "smoke", action = "type", at = 0, text = "추가 " });
            await WaitFor("state", message => Flag(message, "dirty"));
            window.Run("save");
            await WaitFor("state", message => !Flag(message, "dirty"));
            var expected = Join([0xef, 0xbb, 0xbf], Utf8("추가 # 메모장에서 저장한 글\r\n\r\n- 줄 끝은 CRLF\r\n- 맨 앞에 BOM\r\n"));
            var written = await File.ReadAllBytesAsync(path);
            Check("저장 — BOM · CRLF 그대로", written.AsSpan().SequenceEqual(expected), new { bytes = written.Length, expected = expected.Length });
            await Task.Delay(1500);
            var echoed = Drain().Where(message => Field(message, "type") == "applied").Select(message => Field(message, "change")).ToList();
            Check("저장 — 내가 쓴 것을 바깥 변경으로 읽지 않는다", echoed.Count == 0, echoed);
        });

        // 3. 로그 — 따라 보기, 끝에 붙는 줄, 둘로 나눠 쓴 한 글자
        await Scenario("로그", async () =>
        {
            var path = Path.Combine(directory, "follow.log");
            await File.WriteAllBytesAsync(path, Utf8("줄 1\n줄 2\n"));
            await window.LoadFileAsync(path);
            Check("로그 — 따라 보기 · 원본 보기로 연다", window.State.Follow && window.State.Source, window.State);
            Drain();
            AppendBytes(path, Utf8("줄 3\n"));
            var first = await WaitFor("applied");
            Check("로그 — 붙은 줄을 들이고 끝을 따라간다",
                Field(first, "change") == "append" && Number(first, "lines") == 4 && Flag(first, "atEnd"), first);
            AppendBytes(path, [0x61, 0xed, 0x95]);
            var half = await WaitFor("applied");
            AppendBytes(path, [0x9c, 0x0a]);
            var rest = await WaitFor("applied");
            window.Post(new { type = "smoke", action = "digest" });
            var digest = await WaitFor("digest");
            var onDisk = await File.ReadAllBytesAsync(path);
            Check("로그 — 둘로 나눠 쓴 글자도 한 번만, 편집기 글 = 파일",
                Field(half, "change") == "append" && Field(rest, "change") == "append"
                && Field(digest, "sha256") == Sha(onDisk) && (Field(digest, "text") ?? "").EndsWith("a한\n", StringComparison.Ordinal),
                new { half, rest, digest });
        });

        // 4. 부딪침 — 고친 것이 있는데 바깥에서 바뀌면 섞지 않는다. 자동 저장도 멈춘다.
        await Scenario("부딪침", async () =>
        {
            var path = Path.Combine(directory, "conflict.md");
            var original = Utf8("원래 글\n");
            await File.WriteAllBytesAsync(path, original);
            await window.LoadFileAsync(path);
            Drain();
            window.Post(new { type = "smoke", action = "type", at = 0, text = "x" });
            await WaitFor("state", message => Flag(message, "dirty"));
            AppendBytes(path, Utf8("바깥 줄\n"));
            var applied = await WaitFor("applied");
            Check("부딪침 — 섞지 않고 띠로 묻는다", Field(applied, "change") == "conflict" && window.State.Conflict, applied);
            await Task.Delay(2500); // 자동 저장(1.5초)보다 오래
            var untouched = await File.ReadAllBytesAsync(path);
            Check("부딪침 — 고를 때까지 자동 저장이 쓰지 않는다", untouched.AsSpan().SequenceEqual(Join(original, Utf8("바깥 줄\n"))));
            window.Run("keepMine");
            await WaitFor("state", message => !Flag(message, "dirty") && !Flag(message, "conflict"));
            var mine = await File.ReadAllBytesAsync(path);
            Check("부딪침 — '내 것 지키기'는 여기 것을 쓴다", mine.AsSpan().SequenceEqual(Utf8("x원래 글\n")));
        });

        // 5. 라이브 프리뷰 · 목차 화면
        await Scenario("화면", async () =>
        {
            var path = Path.Combine(directory, "showcase.md");
            await File.WriteAllBytesAsync(path, Showcase);
            await window.LoadFileAsync(path);
            window.Post(new { type = "smoke", action = "caret", at = 1_000_000 });
            Drain();
            window.Run("toggleOutline");
            await WaitFor("state", message => Flag(message, "outline"));
            await Task.Delay(700);
            window.Post(new { type = "smoke", action = "digest" });
            var digest = await WaitFor("digest");
            Check("화면 — 라이브 프리뷰가 장식을 단다", Number(digest, "previewDecorations") > 10, Number(digest, "previewDecorations"));
            await using var stream = File.Create(Path.Combine(directory, "editor.png"));
            await window.Core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
        });

        var fonts = ready.TryGetProperty("fonts", out var fontsValue) ? fontsValue : default;
        var fontsLoaded = fonts.ValueKind == JsonValueKind.Object && Flag(fonts, "pretendard") && Flag(fonts, "plexMono");
        // 실렸어도 다른 규칙에 밀리면 쓰이지 않는다 — 0단계의 처음 빌드가 그랬다(고정폭 기본 글꼴, 여백 없음).
        var editorFont = Field(ready, "editorFont");
        var fontApplied = editorFont?.TrimStart().TrimStart('"').StartsWith("Pretendard", StringComparison.Ordinal) == true;
        ok &= fontsLoaded && fontApplied;
        watchdog?.Stop();
        Write(new
        {
            ok,
            webView2 = window.Core.Environment.BrowserVersionString,
            userAgent = Field(ready, "userAgent"),
            fontsLoaded,
            fontApplied,
            editorFont,
            editorPaddingLeft = Field(ready, "editorPaddingLeft"),
            cases,
            scenarios,
            notes,
        });
        window.Finish(ok ? 0 : 1, TimeSpan.FromSeconds(5));
    }

    public void WriteFailure(string message)
    {
        watchdog?.Stop();
        Write(new { ok = false, error = message, notes });
    }

    private void Write(object result)
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(result, JsonOptions));
    }
}
