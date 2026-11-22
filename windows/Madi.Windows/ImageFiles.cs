using System.IO;

namespace Madi;

/// <summary>
/// 문서의 로컬 그림 — 편집기가 고른 경로(<c>windows/editor/src/core/image.ts</c>, 퍼센트 인코딩은 풀었다)를 파일로 풀고 읽어
/// <c>data:</c> 주소로 준다. macOS판 <c>ImageReference.localURL</c>과 같은 규칙: 상대 경로는 문서 폴더가 기준(저장하지 않은 문서는
/// 풀 수 없다), 절대 경로 · <c>file:</c> 주소 · <c>~</c>도 받는다.
///
/// 문서는 남이 쓴 것일 수 있다 — 그림 확장자의 파일만, 크기 한도 안에서 읽는다(아무 파일이나 편집기로 끌어오지 않게).
/// </summary>
public static class ImageFiles
{
    public const long SizeLimit = 25 * 1024 * 1024;

    private static readonly Dictionary<string, string> MimeTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        [".png"] = "image/png",
        [".jpg"] = "image/jpeg",
        [".jpeg"] = "image/jpeg",
        [".gif"] = "image/gif",
        [".webp"] = "image/webp",
        [".bmp"] = "image/bmp",
        [".svg"] = "image/svg+xml",
        [".avif"] = "image/avif",
        [".ico"] = "image/x-icon",
    };

    /// <summary>파일 경로로 푼다. 풀 수 없으면 null.</summary>
    public static string? Resolve(string raw, string? documentPath, string home)
    {
        var path = raw.Trim();
        if (path.Length == 0) return null;
        try
        {
            if (path.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
            {
                return Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile ? Path.GetFullPath(uri.LocalPath) : null;
            }
            if (path == "~" || path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal))
            {
                return Path.GetFullPath(Path.Combine(home, path.Length > 2 ? path[2..] : ""));
            }
            // `C:\…` · `C:/…` · `\\서버\…` — 드라이브까지 적힌 것만 절대 경로다. `\a.png`(드라이브 없는 뿌리)는 문서의 드라이브에서.
            if (Path.IsPathFullyQualified(path)) return Path.GetFullPath(path);
            if (documentPath is null) return null;
            var folder = Path.GetDirectoryName(documentPath);
            return folder is null ? null : Path.GetFullPath(Path.Combine(folder, path));
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException or UriFormatException)
        {
            return null;
        }
    }

    public static string? MimeType(string path) => MimeTypes.GetValueOrDefault(Path.GetExtension(path));

    /// <summary>읽어 <c>data:</c> 주소로. 실패하면 사람이 읽을 까닭과 함께 예외.</summary>
    public static string Load(string raw, string? documentPath, string home)
    {
        var path = Resolve(raw, documentPath, home)
                   ?? throw new InvalidOperationException(documentPath is null
                       ? "저장하지 않은 문서는 상대 경로의 그림을 찾을 수 없습니다"
                       : $"그림 경로를 풀 수 없습니다: {raw}");
        var mime = MimeType(path) ?? throw new InvalidOperationException($"그림 파일이 아닙니다: {Path.GetFileName(path)}");
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException($"그림이 없습니다: {path}");
        if (info.Length > SizeLimit) throw new InvalidOperationException($"그림이 너무 큽니다({info.Length / 1024 / 1024}MB): {path}");
        var bytes = DiskBaseline.ReadAll(path);
        return $"data:{mime};base64,{Convert.ToBase64String(bytes)}";
    }
}
