using System.IO;

namespace Madi;

/// <summary>
/// <c>madi://</c> 링크 — 다른 앱 · 바로 가기 · 셸(<c>start "" "madi://…"</c>)에서 마디에 일을 시키는 주소. macOS판 <c>MadiURL</c>과 같은
/// 명령 · 같은 규칙이다. 여기는 주소를 읽기만 한다(순수 계산). 실행은 <see cref="MainWindow"/>가 한다.
/// <list type="table">
/// <item><c>madi://open?path=…[&amp;line=N][&amp;search=…]</c> — 파일을 열고, N번째 줄로 가거나 그 낱말을 찾는다</item>
/// <item><c>madi://new?text=…[&amp;title=…][&amp;path=…]</c> — 그 글로 새 문서. <c>path</c>가 있으면 그 자리에 새 파일로(있는 파일은 덮지 않는다)</item>
/// <item><c>madi://append?path=…&amp;text=…</c> — 파일 끝에 글을 더한다 — <b>묻고 나서</b></item>
/// </list>
/// 값은 퍼센트 부호로 적는다(공백은 <c>%20</c>). <c>+</c>는 공백이 아니라 <c>+</c> 그대로다. <c>#</c>도 글의 일부다(마디는 조각을 쓰지 않는다).
/// <c>path</c>는 드라이브까지 적은 절대 경로(<c>C:\…</c> · <c>C:/…</c>), <c>~\…</c> · <c>~/…</c>, <c>file:///C:/…</c>만 받고, 마크다운 · 글 ·
/// 로그 파일만 받는다 — 링크는 웹 페이지도 누를 수 있으므로 확장자가 없는 설정 파일 같은 것을 고치는 길을 처음부터 막는다.
///
/// macOS판과 다른 것 하나: <b>네트워크 경로(<c>\\서버\…</c>, <c>file://서버/…</c>)는 받지 않는다</b>. Windows는 그 경로를 여는 순간 그
/// 서버에 로그인 정보(NTLM)를 보낸다 — 웹 페이지의 링크 하나가 사용자의 자격 증명을 남의 서버로 보내게 된다.
/// </summary>
public static class MadiUrl
{
    public const string Scheme = "madi";

    public abstract record Command;
    /// <summary>파일을 연다. <paramref name="Line"/>은 파일의 줄 번호(1부터 — Windows판은 메타데이터도 글 안에 있다).</summary>
    public sealed record Open(string Path, int? Line, string? Search) : Command;
    public sealed record New(string Text, string? Title, string? Path) : Command;
    public sealed record Append(string Path, string Text) : Command;

    public sealed class Failure(string message) : Exception(message);

    public static bool IsMadiUrl(string text) => text.TrimStart().StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase);

    /// <summary>주소를 읽는다. 틀리면 <see cref="Failure"/>(사람이 읽을 문장).</summary>
    public static Command Parse(string url, string home)
    {
        var text = url.Trim();
        if (!IsMadiUrl(text)) throw new Failure("madi:// 주소가 아닙니다.");
        var rest = text[(Scheme.Length + 1)..].TrimStart('/');
        var question = rest.IndexOf('?');
        var action = (question < 0 ? rest : rest[..question]).TrimEnd('/');
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        if (question >= 0)
        {
            foreach (var item in rest[(question + 1)..].Split('&'))
            {
                if (item.Length == 0) continue;
                var equals = item.IndexOf('=');
                var name = Unescape(equals < 0 ? item : item[..equals]);
                var value = equals < 0 ? "" : Unescape(item[(equals + 1)..]);
                values.TryAdd(name, value);
            }
        }
        switch (action.ToLowerInvariant())
        {
            case "open":
            {
                var file = FilePath(values.GetValueOrDefault("path"), home);
                int? line = null;
                if (values.TryGetValue("line", out var raw))
                {
                    if (!int.TryParse(raw, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var number)
                        || number < 1)
                    {
                        throw new Failure($"줄 번호는 1 이상의 정수입니다: {raw}");
                    }
                    line = number;
                }
                var search = values.GetValueOrDefault("search");
                return new Open(file, line, string.IsNullOrEmpty(search) ? null : search);
            }
            case "new":
            {
                var title = values.GetValueOrDefault("title");
                return new New(values.GetValueOrDefault("text") ?? "",
                    string.IsNullOrWhiteSpace(title) ? null : title,
                    values.ContainsKey("path") ? FilePath(values["path"], home) : null);
            }
            case "append":
            {
                var file = FilePath(values.GetValueOrDefault("path"), home);
                if (!values.TryGetValue("text", out var appended) || appended.Length == 0) throw new Failure("'text' 값이 없습니다.");
                return new Append(file, appended);
            }
            case "":
                throw new Failure("명령이 없습니다 — madi://open?path=… 처럼 씁니다.");
            default:
                throw new Failure($"모르는 명령입니다: {action} — open · new · append 중 하나를 씁니다.");
        }
    }

    /// <summary>퍼센트 부호를 푼다(UTF-8). 뒤에 16진 두 자리가 없는 <c>%</c>는 그대로. <c>+</c>는 공백이 아니다.</summary>
    private static string Unescape(string text) => Uri.UnescapeDataString(text);

    /// <summary><c>path</c> 값을 파일 경로로 — <c>..</c>를 푼 뒤에 확장자를 본다(<c>C:\글\..\x</c> 같은 꼴이 검사를 지나치지 않게).</summary>
    internal static string FilePath(string? raw, string home)
    {
        if (string.IsNullOrWhiteSpace(raw)) throw new Failure("'path' 값이 없습니다.");
        var value = raw.Trim();
        string path;
        if (value.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
        {
            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || !uri.IsFile) throw new Failure($"경로는 C:\\처럼 드라이브부터 적습니다: {value}");
            if (uri.IsUnc) throw NetworkPath(value);
            path = uri.LocalPath;
        }
        else if (value == "~" || value.StartsWith("~/", StringComparison.Ordinal) || value.StartsWith("~\\", StringComparison.Ordinal))
        {
            path = Path.Combine(home, value.Length > 2 ? value[2..] : "");
        }
        else
        {
            path = value;
        }
        // `\\서버\…` · `//서버/…` · `\\?\` · `\\.\`(장치) — 드라이브 문자로 시작하는 로컬 경로만.
        if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.StartsWith("//", StringComparison.Ordinal)) throw NetworkPath(value);
        if (!Path.IsPathFullyQualified(path)) throw new Failure($"경로는 C:\\처럼 드라이브부터 적거나 ~\\로 적습니다: {value}");
        string full;
        try
        {
            full = Path.GetFullPath(path);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new Failure($"경로를 읽을 수 없습니다: {value}");
        }
        if (full.StartsWith(@"\\", StringComparison.Ordinal)) throw NetworkPath(value);
        if (!QuickOpenSources.OpenableExtensions.Contains(Path.GetExtension(full)))
        {
            throw new Failure($"마크다운 · 글 파일(.md · .markdown · .txt · .log 등)만 엽니다: {full}");
        }
        return full;
    }

    private static Failure NetworkPath(string value) =>
        new($"네트워크 경로는 링크로 열지 않습니다(그 서버에 Windows 로그인 정보가 갑니다): {value}");

    /// <summary><c>new</c>가 여는 글 — 제목이 있으면 맨 위에 <c># 제목</c>과 빈 줄. 파일로 만들 때는 끝을 줄바꿈으로 맺는다(빈 글은 그대로).</summary>
    public static string NewDocumentText(string text, string? title, bool asFile)
    {
        var composed = title is null ? text : $"# {title}\n\n{text}";
        if (asFile && composed.Length > 0 && !composed.EndsWith('\n')) composed += "\n";
        return composed;
    }
}
