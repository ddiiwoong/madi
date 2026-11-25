using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Unicode;
using System.Threading.Channels;
using System.Windows;
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
/// <item>블록 그림 — 앞머리 카드 · 표 · Mermaid · KaTeX · 그림이 모두 그려지는지, 할 일 상자를 누르면 파일이 바뀌는지(<c>blocks.png</c> ·
/// <c>blocks-end.png</c>)</item>
/// <item>명령 팔레트 · 빠른 열기가 거르는지(<c>palette.png</c> · <c>quickopen.png</c>)</item>
/// <item>한 번만 켜기 · <c>madi://</c> — 두 번째로 켠 마디가 넘기고 끝나는지, open(줄) · append(묻고) · new(제목 · 경로) ·
/// 네트워크 경로 거절</item>
/// <item>모양 — 서식 막대가 뜨고 누르면 고치는지, 제목 막대가 끌기 · 누르기 · 크기 바꾸기를 맞게 답하는지, 최대화해도 단추가 화면 안인지
/// (<c>design.png</c>)</item>
/// <item>설정 — 테마 · 다크 · 글자 크기가 편집기와 제목 막대에 쓰이고 <c>settings.json</c>에 남는지(<c>blocks-dark.png</c> · <c>design-dark.png</c>)</item>
/// <item>PDF — 다크에서 내보내도 흰 종이 · 문서 전체(쪽 수), 끝나면 다크로 돌아오는지(<c>output.png</c> · <c>export.pdf</c>, 마지막 화면)</item>
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
        "print(인사)",
        "```",
        ""));

    /// <summary>블록 그림을 모두 담은 문서 — 캐럿은 끝 줄(블록 밖)에 둔다.</summary>
    private static readonly string BlocksDocument = string.Join("\n",
        "---",
        "title: 마디 Windows 2단계",
        "tags: [표, 다이어그램, 수식]",
        "---",
        "",
        "# 블록 그림",
        "",
        "| 기능 | 상태 | 수 |",
        "|:--|:-:|--:|",
        "| **표** | 완료 | 1 |",
        "| `코드` | [링크](https://github.com/ddiiwoong/madi) | 22 |",
        "",
        "```mermaid",
        "graph LR",
        "  A[열기] --> B[고치기] --> C[저장]",
        "```",
        "",
        "$$",
        "\\int_0^1 x^2\\,dx = \\frac{1}{3}",
        "$$",
        "",
        "```math",
        "e^{i\\pi} + 1 = 0",
        "```",
        "",
        "![체크무늬](그림/dot.png)",
        "",
        "- [ ] 첫 일",
        "- [x] 끝낸 일",
        "",
        "> [!TIP]",
        "> 알림 상자 — 제목이 Tip으로 보인다",
        "",
        "끝",
        "");

    /// <summary>160×48 체크무늬 PNG(204바이트).</summary>
    private static readonly byte[] CheckerPng = Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAAKAAAAAwCAIAAAAZy+Y5AAAAk0lEQVR42u3aMQ0AMAhFQYxVT21VSjVVQTUwkcAlzG/4txKxb+reWanTL+4bCDAAwAAA6wPW" +
        "B6wPWB8wYAMBBgAYAGB9wPqA9QGP7Ru0dx8wYACAAQDWB6wPWB+wPmDABgIMADAAwPqA9QHrA54LbFAfHQAAAwCsD1gfsD5gfcCADQQYAGAAgPUB6wPWBwzY" +
        "QC37H0FebJUItSnGAAAAAElFTkSuQmCC");

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

    // 없는 것(객체가 아닌 값)은 없는 것으로 — 편집기의 답 모양이 틀려도 예외가 아니라 실패로 적힌다.
    private static string? Field(JsonElement message, string name) =>
        Child(message, name) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;

    private static bool Flag(JsonElement message, string name) => Child(message, name).ValueKind == JsonValueKind.True;

    private static int Number(JsonElement message, string name) =>
        Child(message, name) is { ValueKind: JsonValueKind.Number } value && value.TryGetInt32(out var number) ? number : -1;

    private static JsonElement Child(JsonElement message, string name) =>
        message.ValueKind == JsonValueKind.Object && message.TryGetProperty(name, out var value) ? value : default;

    private static Dictionary<string, int> Counts(JsonElement value) =>
        value.ValueKind == JsonValueKind.Object
            ? value.EnumerateObject().ToDictionary(property => property.Name, property => property.Value.GetInt32())
            : [];

    private async Task<JsonElement> Digest()
    {
        window.Post(new { type = "smoke", action = "digest" });
        return await WaitFor("digest");
    }

    /// <summary>조건이 설 때까지 몇 번 다시 잰다(다이어그램 · 그림은 늦게 그려진다).</summary>
    private async Task<JsonElement> DigestUntil(Func<JsonElement, bool> done, double seconds = 30)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (true)
        {
            var digest = await Digest();
            if (done(digest) || DateTime.UtcNow > deadline) return digest;
            await Task.Delay(400);
        }
    }

    private readonly Channel<(MainWindow Window, JsonElement Message)> others = Channel.CreateUnbounded<(MainWindow, JsonElement)>();

    /// <summary>링크로 연 다른 창의 답.</summary>
    private async Task<JsonElement> WaitForOther(MainWindow from, string type, Func<JsonElement, bool>? match = null, double seconds = 20)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        try
        {
            while (true)
            {
                var (sender, message) = await others.Reader.ReadAsync(timeout.Token);
                if (sender == from && Field(message, "type") == type && (match?.Invoke(message) ?? true)) return message;
            }
        }
        catch (OperationCanceledException)
        {
            throw new TimeoutException($"{seconds}초 안에 다른 창의 '{type}'이 오지 않았다");
        }
    }

    /// <summary>지난 답을 버린다 — 다음에 기다리는 답이 이번 일의 것이게.</summary>
    private void DrainOthers()
    {
        while (others.Reader.TryRead(out _)) { }
    }

    private static async Task<T?> Until<T>(Func<T?> probe, double seconds) where T : class
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < deadline)
        {
            if (probe() is { } found) return found;
            await Task.Delay(200);
        }
        return probe();
    }

    /// <summary>두 번째 마디를 켠다 — 확인 실행의 이름(<c>smoke</c>)으로 넘기게. 끝 코드(넘겼으면 0, 곧 끝난다).</summary>
    private static async Task<int> Second(params string[] arguments)
    {
        using var process = Process.Start(Environment.ProcessPath!, ["--instance", "smoke", .. arguments])!;
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
        return process.ExitCode;
    }

    private static string Link(string action, params (string Name, string Value)[] values) =>
        $"madi://{action}?" + string.Join("&", values.Select(value => $"{value.Name}={Uri.EscapeDataString(value.Value)}"));

    private async Task Capture(string name)
    {
        await using var stream = File.Create(Path.Combine(directory, name));
        await window.Core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
    }

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
            // 언어 꾸러미는 처음 보일 때 싣는다 — 실릴 때까지 다시 잰다.
            var colored = await DigestUntil(message => Field(message, "codeKeyword") is { } color
                && color != Field(Child(message, "colors"), "text"), seconds: 15);
            Check("화면 — 코드 블록에 문법 색(Swift의 let이 본문과 다른 색)",
                Field(colored, "codeKeyword") is { } keyword && keyword != Field(Child(colored, "colors"), "text"),
                new { keyword = Field(colored, "codeKeyword"), text = Field(Child(colored, "colors"), "text") });
            await Capture("editor.png");
            window.Run("toggleOutline");
            await WaitFor("state", message => !Flag(message, "outline"));

            // 코드 복사 단추 — 마우스를 코드 블록에 올리면 뜨고, 누르면 펜스를 뺀 코드가 클립보드에(Windows의 CRLF로). 실제 클립보드를 읽는다.
            Clipboard.SetText("복사 전");
            window.Activate();
            window.Post(new { type = "smoke", action = "hoverCode" });
            var hovered = await DigestUntil(message => Flag(Child(message, "codeCopy"), "shown"), seconds: 10);
            await Capture("codecopy.png");
            window.Post(new { type = "smoke", action = "codeCopyPress" });
            var expectedCode = "let 인사 = \"안녕\"\r\nprint(인사)";
            string? clipboard = null;
            for (var tries = 0; tries < 30 && clipboard != expectedCode; tries++)
            {
                await Task.Delay(100);
                clipboard = Clipboard.ContainsText() ? Clipboard.GetText() : null;
            }
            var pressed = Child(await Digest(), "codeCopy");
            Check("코드 복사 — 코드 블록 위에 마우스를 두면 단추가 뜨고, 누르면 펜스를 뺀 코드가 클립보드에(CRLF) · '복사됨'",
                Flag(Child(hovered, "codeCopy"), "shown") && Field(Child(hovered, "codeCopy"), "language") == "swift"
                && clipboard == expectedCode && Field(pressed, "label") == "복사됨",
                new { hovered = Child(hovered, "codeCopy"), pressed, clipboard });
        });

        // 6. 블록 그림 — 앞머리 · 표 · 다이어그램 · 수식 둘 · 그림, 할 일 상자를 누르면 파일의 글자 하나가 바뀐다
        await Scenario("블록", async () =>
        {
            var folder = Path.Combine(directory, "blocks");
            Directory.CreateDirectory(Path.Combine(folder, "그림"));
            await File.WriteAllBytesAsync(Path.Combine(folder, "그림", "dot.png"), CheckerPng);
            var path = Path.Combine(folder, "blocks.md");
            await File.WriteAllBytesAsync(path, Utf8(BlocksDocument));
            await window.LoadFileAsync(path);
            // 연 그대로 — 캐럿이 앞머리 다음 줄(5)이라 앞머리가 카드다. 전에는 캐럿이 맨 처음이라 원문(YAML)이 펼쳐진 채 열렸다.
            var fresh = await Digest();
            Check("앞머리 — 파일을 열면 카드로 보인다(캐럿은 앞머리 다음 줄)",
                Number(fresh, "caretLine") == 5 && Counts(Child(Child(fresh, "blocks"), "kinds")).GetValueOrDefault("frontmatter") == 1,
                new { caretLine = Number(fresh, "caretLine"), kinds = Child(Child(fresh, "blocks"), "kinds") });
            window.Post(new { type = "smoke", action = "caret", at = 1_000_000 });
            var expected = new Dictionary<string, int> { ["frontmatter"] = 1, ["table"] = 1, ["mermaid"] = 1, ["math"] = 2, ["image"] = 1 };
            var digest = await DigestUntil(message =>
            {
                var states = Counts(Child(Child(message, "blocks"), "states"));
                return states.GetValueOrDefault("ready") + states.GetValueOrDefault("error") >= 6;
            });
            var blocks = Child(digest, "blocks");
            var kinds = Counts(Child(blocks, "kinds"));
            var readyStates = Counts(Child(blocks, "states"));
            Check("블록 — 앞머리 · 표 · 다이어그램 · 수식 · 그림을 그린다",
                kinds.Count == expected.Count && expected.All(pair => kinds.GetValueOrDefault(pair.Key) == pair.Value)
                && readyStates.GetValueOrDefault("ready") == 6,
                blocks);
            Check("블록 — 할 일 상자 둘 · 알림 제목", Number(digest, "tasks") == 2, Number(digest, "tasks"));
            await Capture("blocks.png");
            window.Post(new { type = "smoke", action = "scrollEnd" });
            await Task.Delay(600);
            await Capture("blocks-end.png"); // 아래쪽 — 그림 · 할 일 상자 · 알림

            Drain();
            window.Post(new { type = "smoke", action = "toggleTask" });
            await WaitFor("state", message => Flag(message, "dirty"));
            await WaitFor("state", message => !Flag(message, "dirty"), seconds: 10); // 자동 저장(1.5초)
            var written = Encoding.UTF8.GetString(await File.ReadAllBytesAsync(path));
            Check("블록 — 할 일 상자를 누르면 [ ] → [x], 나머지는 그대로",
                written == BlocksDocument.Replace("- [ ] 첫 일", "- [x] 첫 일", StringComparison.Ordinal),
                written.Length);
        });

        // 6½. 모양 — 제목 막대(메뉴 막대 대신)와 서식 막대. 창째 찍는다(`design.png` — 제목 막대까지).
        await Scenario("모양", async () =>
        {
            var path = Path.Combine(directory, "blocks", "blocks.md");
            var text = Encoding.UTF8.GetString(await File.ReadAllBytesAsync(path));
            var word = text.IndexOf("첫 일", StringComparison.Ordinal);
            window.Activate();
            window.Post(new { type = "smoke", action = "select", from = word, to = word + "첫 일".Length });
            var shown = await DigestUntil(message => Flag(Child(message, "formatBar"), "shown"), seconds: 10);
            var bar = Child(shown, "formatBar");
            var buttons = Child(bar, "buttons").ValueKind == JsonValueKind.Array
                ? Child(bar, "buttons").EnumerateArray().Select(item => item.GetString()).ToList() : [];
            Check("서식 막대 — 글을 고르면 위에 뜬다(제목 ▾ · 꾸밈 다섯 · 목록 · 인용 · 블록)",
                Flag(bar, "shown") && buttons.Contains("bold") && buttons.Contains("heading") && buttons.Contains("table"), bar);
            await Task.Delay(300);
            WindowFrame.Capture(window, Path.Combine(directory, "design.png"));

            Drain();
            window.Post(new { type = "smoke", action = "formatPress", command = "bold" });
            await WaitFor("state", message => Flag(message, "dirty"));
            await WaitFor("state", message => !Flag(message, "dirty"), seconds: 10); // 자동 저장
            var bolded = Encoding.UTF8.GetString(await File.ReadAllBytesAsync(path));
            await Task.Delay(300);
            var toast = Child(await Digest(), "toast");
            Check("서식 막대 — 굵게를 누르면 고른 글만 **로 감싸고 자동 저장한다(자동 저장은 알림을 띄우지 않는다)",
                bolded == text.Replace("첫 일", "**첫 일**", StringComparison.Ordinal) && !Flag(toast, "shown"), new { toast, length = bolded.Length });

            // 메뉴(…) — 메뉴 막대가 하던 것. Windows 11 모양의 메뉴(Fluent)로 뜨는지 찍는다.
            window.OpenMenu(byKeyboard: false);
            await Task.Delay(500);
            var menuOpen = window.MenuIsOpen;
            WindowFrame.Capture(window, Path.Combine(directory, "menu.png"));
            window.CloseMenu();
            Check("메뉴(…) — 제목 막대의 단추로 연다", menuOpen);

            // 제목 막대 — 빈 자리는 창 끌기(2), 단추는 누르기(1), 맨 위 끝은 크기 바꾸기(12).
            var bar2 = window.Chrome;
            Point Screen(FrameworkElement element, double x, double y) => element.PointToScreen(new Point(x, y));
            var empty = WindowFrame.HitTest(window, Screen(bar2, bar2.ActualWidth * 0.55, 20));
            var search = WindowFrame.HitTest(window, Screen(bar2.Search, bar2.Search.ActualWidth / 2, bar2.Search.ActualHeight / 2));
            var top = WindowFrame.HitTest(window, Screen(bar2, bar2.ActualWidth * 0.55, 2));
            Check("제목 막대 — 빈 자리는 창을 끌고, 단추는 누르고, 맨 위 끝은 크기를 바꾼다", empty == 2 && search == 1 && top == 12,
                new { empty, search, top });

            // 최대화 — 화면 밖으로 나간 테두리만큼 안으로. 닫기 단추가 작업 영역 안에 다 보인다.
            window.WindowState = WindowState.Maximized;
            await Task.Delay(800);
            var close = bar2.CloseButton;
            var corner = Screen(close, close.ActualWidth, 0);
            var area = WindowFrame.WorkArea(window);
            var draggable = WindowFrame.HitTest(window, Screen(bar2, bar2.ActualWidth * 0.55, TitleBar.BarHeight - 4));
            Check("제목 막대 — 최대화해도 창 단추가 화면 안에, 막대 아래쪽까지 창을 끈다",
                corner.X <= area.Right + 0.5 && corner.Y >= area.Top - 0.5 && draggable == 2,
                new { corner = $"{corner.X},{corner.Y}", area = area.ToString(System.Globalization.CultureInfo.InvariantCulture), draggable });
            window.WindowState = WindowState.Normal;
            await Task.Delay(500);

            // 제목 옆의 작은 표시 — UTF-8이 아닌 인코딩은 늘 보인다(전의 상태 줄 대신).
            await window.LoadFileAsync(Path.Combine(directory, "cp949.txt"));
            await Task.Delay(300);
            Check("제목 막대 — EUC-KR 문서는 '저장하면 UTF-8'을 제목 옆에", window.Chrome.Notes.Any(note => note.StartsWith("EUC-KR", StringComparison.Ordinal)),
                window.Chrome.Notes);
            // 다음 시나리오(설정의 다크 화면)가 블록 문서를 본다.
            await window.LoadFileAsync(path);
            window.Post(new { type = "smoke", action = "caret", at = 1_000_000 });
        });

        // 7. 명령 팔레트 · 빠른 열기
        await Scenario("고르기", async () =>
        {
            window.Run("commandPalette");
            window.Post(new { type = "smoke", action = "pickerType", query = "githb" });
            var palette = Child(await Digest(), "picker");
            var shown = Child(palette, "shown").ValueKind == JsonValueKind.Array
                ? Child(palette, "shown").EnumerateArray().Select(item => item.GetString()).ToList() : [];
            await Capture("palette.png");
            window.Post(new { type = "smoke", action = "pickerClose" });
            Check("명령 팔레트 — 띄엄띄엄 친 `githb`가 보기 ▸ 테마 ▸ GitHub를 찾는다", Flag(palette, "open") && shown.FirstOrDefault() == "GitHub", palette);

            window.Run("quickOpen");
            var loaded = await DigestUntil(message => Number(Child(message, "picker"), "items") > 0, seconds: 15);
            window.Post(new { type = "smoke", action = "pickerType", query = "showcase" });
            var quick = Child(await Digest(), "picker");
            var first = Child(quick, "shown").ValueKind == JsonValueKind.Array
                ? Child(quick, "shown").EnumerateArray().Select(item => item.GetString()).FirstOrDefault() : null;
            await Capture("quickopen.png");
            window.Post(new { type = "smoke", action = "pickerClose" });
            Check("빠른 열기 — 최근 문서에서 showcase.md를 찾는다",
                Number(Child(loaded, "picker"), "items") >= 5 && first == "showcase.md", new { items = Number(Child(loaded, "picker"), "items"), quick });
        });

        // 8. 한 번만 켜기 · madi:// — 두 번째로 켠 마디(같은 exe)가 넘기고, 켜진 마디(이 확인 실행)가 연다.
        await Scenario("링크", async () =>
        {
            var folder = Path.Combine(directory, "links");
            Directory.CreateDirectory(folder);
            var linked = Path.Combine(folder, "linked.md");
            await File.WriteAllBytesAsync(linked, Utf8("# 링크\n\n- 하나\n- 둘\n"));
            var prompts = new List<string>();
            MainWindow.Observer = (from, message) =>
            {
                if (from != window) others.Writer.TryWrite((from, message));
            };
            MainWindow.ConfirmAppendOverride = (_, text) =>
            {
                prompts.Add(text);
                return true;
            };
            try
            {
                var code = await Second(linked);
                var target = await Until(() => MainWindow.FindWindow(linked) is { State.Path: not null } found ? found : null, 20);
                Check("한 번만 켜기 — 두 번째 마디는 넘기고 끝나고(0), 켜진 마디가 새 창에 연다", code == 0 && target is not null, code);
                if (target is null) return;

                DrainOthers();
                await Second(Link("open", ("path", linked), ("line", "3")));
                target.Post(new { type = "smoke", action = "digest" });
                var atLine = await WaitForOther(target, "digest");
                // 이미 연 창이라 바로 간다 — 한 번 더 재어 늦게 온 것도 본다.
                if (Number(atLine, "caretLine") != 3)
                {
                    await Task.Delay(500);
                    target.Post(new { type = "smoke", action = "digest" });
                    atLine = await WaitForOther(target, "digest");
                }
                Check("madi://open — 열린 창으로 가서 3번째 줄", Number(atLine, "caretLine") == 3, Number(atLine, "caretLine"));

                DrainOthers();
                await Second(Link("append", ("path", linked), ("text", "- 셋")));
                await WaitForOther(target, "state", message => !Flag(message, "dirty") && prompts.Count == 1, seconds: 15);
                await Task.Delay(300);
                var appended = Encoding.UTF8.GetString(await File.ReadAllBytesAsync(linked));
                Check("madi://append — 묻고(한 번), 목록 끝에 빈 줄 없이 잇고, 자동 저장",
                    prompts.Count == 1 && appended == "# 링크\n\n- 하나\n- 둘\n- 셋\n", new { prompts, appended });

                DrainOthers();
                var before = MainWindow.OpenWindows.ToList();
                await Second(Link("new", ("title", "회의"), ("text", "안건 #1 + 100%")));
                var composed = await Until(() => MainWindow.OpenWindows.Except(before).FirstOrDefault(), 20);
                JsonElement draft = default;
                if (composed is not null)
                {
                    await WaitForOther(composed, "state", message => Flag(message, "dirty"), seconds: 20);
                    composed.Post(new { type = "smoke", action = "digest" });
                    draft = await WaitForOther(composed, "digest");
                }
                Check("madi://new — 제목과 글로 새 창(고친 상태, `#` · `+` · `%`는 글 그대로)",
                    Field(draft, "text") == "# 회의\n\n안건 #1 + 100%", Field(draft, "text"));

                var created = Path.Combine(folder, "created.md");
                await Second(Link("new", ("path", created), ("text", "새 글")));
                var createdWindow = await Until(() => MainWindow.FindWindow(created), 20);
                Check("madi://new?path — 새 파일을 만들어 연다(줄바꿈으로 맺음)",
                    createdWindow is not null && File.Exists(created) && await File.ReadAllTextAsync(created) == "새 글\n");
                var exists = await Second(Link("new", ("path", created), ("text", "덮어쓰기")));
                await Task.Delay(800);
                Check("madi://new?path — 있는 파일은 덮지 않는다",
                    await File.ReadAllTextAsync(created) == "새 글\n" && MainWindow.SmokeNotes.Any(note => note.Contains("덮어쓰지 않습니다")), exists);

                var notesBefore = MainWindow.SmokeNotes.Count;
                await Second(Link("open", ("path", @"\\madi-smoke-host\share\a.md")));
                await Task.Delay(800);
                var refused = MainWindow.SmokeNotes.Skip(notesBefore).ToList();
                Check("madi:// — 네트워크 경로는 열지 않는다(자격 증명이 나가지 않게)",
                    refused.Any(note => note.Contains("네트워크 경로")), refused);
            }
            finally
            {
                MainWindow.Observer = null;
                MainWindow.ConfirmAppendOverride = null;
                foreach (var extra in MainWindow.OpenWindows.Where(other => other != window).ToList()) extra.Close();
            }
        });

        // 9. 설정 — 테마 · 다크 · 글자 크기. 편집기가 정한 값을 껍데기가 저장한다. 마지막 화면(CI가 창째 한 장 더 찍는다).
        await Scenario("설정", async () =>
        {
            Drain();
            window.Run("setTheme", "github");
            window.Run("setAppearance", "dark");
            window.Run("textBigger");
            await WaitFor("settings", message =>
            {
                var value = Child(message, "settings");
                return Field(value, "appearance") == "dark" && Number(value, "bodySize") == 16;
            });
            await Task.Delay(500);
            var digest = await Digest();
            var colors = Child(digest, "colors");
            Check("설정 — GitHub 다크 · 16px이 편집기에 쓰인다",
                Field(colors, "background") == "rgb(13, 17, 23)" && Field(colors, "scheme") == "dark" && Field(digest, "fontSize") == "16px",
                new { colors, fontSize = Field(digest, "fontSize") });
            var saved = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(MainWindow.Store.Folder, "settings.json"))).RootElement;
            Check("설정 — settings.json에 남는다",
                Field(saved, "theme") == "github" && Field(saved, "appearance") == "dark" && Number(saved, "bodySize") == 16,
                saved.GetRawText());
            await DigestUntil(message => Counts(Child(Child(message, "blocks"), "states")).GetValueOrDefault("ready") >= 6, seconds: 20);
            await Capture("blocks-dark.png");
            var titleColor = ChromeColors.Hex(window.Chrome.Colors.Background);
            Check("설정 — 제목 막대도 GitHub 다크(편집기와 같은 바탕)", titleColor == "#0D1117", titleColor);
            window.Activate();
            await Task.Delay(300);
            WindowFrame.Capture(window, Path.Combine(directory, "design-dark.png"));
        });

        // 10. PDF — 다크에서 내보내도 흰 종이 · 문서 전체. 끝나면 다크로 돌아온다. 마지막 화면.
        await Scenario("PDF", async () =>
        {
            // 블록 문서와 같은 폴더 — 그림(`그림/dot.png`)이 풀리게.
            var path = Path.Combine(directory, "blocks", "long.md");
            var longer = BlocksDocument + string.Concat(Enumerable.Range(1, 160).Select(line => $"\n줄 {line} — 쪽을 넘기는 글"));
            await File.WriteAllBytesAsync(path, Utf8(longer + "\n"));
            await window.LoadFileAsync(path);
            window.Post(new { type = "smoke", action = "caret", at = 0 }); // 캐럿이 메타데이터 안 — 내보낼 때는 상관없어야 한다
            await DigestUntil(message => Counts(Child(Child(message, "blocks"), "states")).GetValueOrDefault("pending") == 0, seconds: 20);

            Drain();
            window.Post(new { type = "output", action = "begin", id = 900 });
            var ready = await WaitFor("outputReady", seconds: 60);
            var output = await Digest();
            await Capture("output.png");
            window.Post(new { type = "output", action = "end" });
            var colors = Child(output, "colors");
            var blocks = Counts(Child(Child(output, "blocks"), "kinds"));
            var drawn = Counts(Child(Child(output, "blocks"), "states"));
            Check("PDF — 내보내는 동안 흰 종이 · 기본 색 · 문서 전체 · 메타데이터 없음 · 블록 다섯 모두 그려짐",
                Flag(output, "output") && Field(colors, "background") == "rgb(255, 255, 255)"
                && drawn.GetValueOrDefault("ready") == 5 && drawn.Count == 1
                // 블록 그림이 갈아 끼운 줄(메타데이터 4 · 표 4 · 다이어그램 4 · 수식 6 · 그림 1)만 빠진다 — 보이는 화면만 그렸다면 수십 줄이다.
                && Number(output, "renderedLines") >= Number(ready, "lines") - 30
                && !blocks.ContainsKey("frontmatter") && blocks.GetValueOrDefault("mermaid") == 1,
                new { lines = Number(ready, "lines"), rendered = Number(output, "renderedLines"), colors, blocks, drawn });

            var pdf = Path.Combine(directory, "export.pdf");
            var written = await window.ExportPdfToAsync(pdf);
            var bytes = written && File.Exists(pdf) ? await File.ReadAllBytesAsync(pdf) : [];
            var text = Encoding.Latin1.GetString(bytes);
            var pages = Regex.Matches(text, @"/Type\s*/Page(?![a-zA-Z])").Count;
            Check("PDF — 파일을 쓰고, 보이는 화면이 아니라 문서 전체가 여러 쪽", written && text.StartsWith("%PDF-", StringComparison.Ordinal) && pages >= 3,
                new { written, bytes = bytes.Length, pages });

            await Task.Delay(500);
            var after = await DigestUntil(message => !Flag(message, "output"), seconds: 10);
            Check("PDF — 끝나면 다크(GitHub)로 돌아온다", Field(Child(after, "colors"), "background") == "rgb(13, 17, 23)",
                Child(after, "colors"));
            await DigestUntil(message => Counts(Child(Child(message, "blocks"), "states")).GetValueOrDefault("pending") == 0, seconds: 20);
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
            // MSIX로 깔아 돌렸으면 꾸러미 계열 이름 — CI가 정말 꾸러미 안에서 돌았는지 본다.
            packageFamilyName = PackageIdentity.FamilyName,
            cases,
            scenarios,
            notes,
            smokeNotes = MainWindow.SmokeNotes,
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
