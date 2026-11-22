using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Unicode;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Madi;

/// <summary>
/// 확인 실행 — <c>Madi.exe --smoke &lt;폴더&gt;</c>. 시험 문서를 그 폴더에 쓰고 하나씩 열어, 편집기를 지나도 바이트가 그대로인지
/// (UTF-8 · BOM · CRLF · UTF-16 · 섞인 줄 끝) 견주고, 편집기 화면을 찍어(<c>editor.png</c>) <c>result.json</c>에 적는다.
/// CI(<c>.github/workflows/windows.yml</c>)가 이것을 돌린다. 시험 문서는 <c>windows/editor/test/cases.ts</c>와 같은 바이트다.
/// </summary>
internal sealed class SmokeRun(MainWindow window, string directory)
{
    private sealed record Case(string Name, byte[] Bytes, string Encoding, bool Bom, string LineSeparator, string RoundTrip);

    private static byte[] Utf8(string text) => new UTF8Encoding(false).GetBytes(text);
    private static byte[] Join(params byte[][] parts) => parts.SelectMany(part => part).ToArray();

    private static readonly Case[] Cases =
    [
        // "한글 메모\r\n"을 EUC-KR(CP949)로. 편집기는 읽되 그 꼴로 다시 쓰지는 않는다(저장은 UTF-8).
        new("cp949.txt", [0xc7, 0xd1, 0xb1, 0xdb, 0x20, 0xb8, 0xde, 0xb8, 0xf0, 0x0d, 0x0a], "euc-kr", false, "CRLF", "converted"),
        new("utf16le.txt", Join([0xff, 0xfe], Encoding.Unicode.GetBytes("메모장 UTF-16\r\n둘째 줄 😀\r\n")),
            "utf-16le", true, "CRLF", "exact"),
        new("mixed.log", Utf8("2026-11-22 10:00:01 INFO 시작\r\n2026-11-22 10:00:02 WARN 섞인 줄 끝\n끝\r"),
            "utf-8", false, "LF", "exact"),
        new("crlf-bom.md", Join([0xef, 0xbb, 0xbf], Utf8("# 메모장에서 저장한 글\r\n\r\n- 줄 끝은 CRLF\r\n- 맨 앞에 BOM\r\n")),
            "utf-8", true, "CRLF", "exact"),
        // 마지막 것이 화면에 남는다 — editor.png.
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

    private bool started;
    private DispatcherTimer? watchdog;

    /// <summary>편집기가 2분 안에 끝내지 못하면(뜨지 않음, 답이 없음) 실패로 적고 닫는다.</summary>
    public void StartWatchdog()
    {
        watchdog = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        watchdog.Tick += (_, _) =>
        {
            watchdog.Stop();
            WriteFailure("시간을 넘겼다 — 편집기가 준비되지 않았거나 답하지 않았다");
            window.Finish(2, TimeSpan.Zero);
        };
        watchdog.Start();
    }

    public async Task RunAsync(JsonElement ready)
    {
        if (started) return;
        started = true;
        var ok = true;
        var results = new List<object>();
        try
        {
            Directory.CreateDirectory(directory);
            foreach (var sample in Cases)
            {
                var path = Path.Combine(directory, sample.Name);
                await File.WriteAllBytesAsync(path, sample.Bytes);
                var onDisk = await File.ReadAllBytesAsync(path);
                var reply = await window.SendOpenAsync(path, onDisk).WaitAsync(TimeSpan.FromSeconds(30));
                var expectedSha = Convert.ToHexStringLower(SHA256.HashData(sample.Bytes));
                string? Field(string name) =>
                    reply.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
                var bom = reply.TryGetProperty("bom", out var bomValue) && bomValue.ValueKind == JsonValueKind.True;
                var pass = Field("type") == "opened"
                    && Field("encoding") == sample.Encoding
                    && bom == sample.Bom
                    && Field("lineSeparator") == sample.LineSeparator
                    && Field("roundTrip") == sample.RoundTrip
                    && (sample.RoundTrip != "exact" || Field("sha256") == expectedSha);
                ok &= pass;
                results.Add(new
                {
                    name = sample.Name,
                    pass,
                    expected = new { encoding = sample.Encoding, bom = sample.Bom, lineSeparator = sample.LineSeparator, roundTrip = sample.RoundTrip, sha256 = expectedSha },
                    reply,
                });
            }
            await using var stream = File.Create(Path.Combine(directory, "editor.png"));
            await window.Core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
        }
        catch (Exception error)
        {
            ok = false;
            results.Add(new { error = error.ToString() });
        }

        var fonts = ready.TryGetProperty("fonts", out var fontsValue) ? fontsValue : default;
        var fontsLoaded = fonts.ValueKind == JsonValueKind.Object
            && fonts.TryGetProperty("pretendard", out var pretendard) && pretendard.ValueKind == JsonValueKind.True
            && fonts.TryGetProperty("plexMono", out var plex) && plex.ValueKind == JsonValueKind.True;
        ok &= fontsLoaded;
        watchdog?.Stop();
        Write(new
        {
            ok,
            webView2 = window.Core.Environment.BrowserVersionString,
            userAgent = ready.TryGetProperty("userAgent", out var agent) ? agent.GetString() : null,
            fontsLoaded,
            cases = results,
        });
        window.Finish(ok ? 0 : 1, TimeSpan.FromSeconds(5));
    }

    public void WriteFailure(string message)
    {
        watchdog?.Stop();
        Write(new { ok = false, error = message });
    }

    private void Write(object result)
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(result, JsonOptions));
    }
}
