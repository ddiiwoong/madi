using System.Globalization;
using System.Text.Json;

namespace Madi;

/// <summary><c>0.1.4</c> 같은 판 번호 — macOS판 <c>ReleaseVersion</c>. 앞의 <c>v</c>는 떼고, 숫자 마디만(<c>0.2.0-beta</c>는 판이 아니다).</summary>
public sealed class ReleaseVersion : IComparable<ReleaseVersion>, IEquatable<ReleaseVersion>
{
    public IReadOnlyList<int> Components { get; }

    private ReleaseVersion(List<int> components) => Components = components;

    public static ReleaseVersion? Parse(string? text)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.StartsWith('v') || trimmed.StartsWith('V')) trimmed = trimmed[1..];
        var parts = trimmed.Split('.');
        if (parts.Length is < 1 or > 4) return null;
        var numbers = new List<int>();
        foreach (var part in parts)
        {
            if (part.Length is 0 or > 6 || !part.All(char.IsAsciiDigit)) return null;
            numbers.Add(int.Parse(part, CultureInfo.InvariantCulture));
        }
        return new ReleaseVersion(numbers);
    }

    /// <summary>모자란 마디는 0 — <c>0.1</c>과 <c>0.1.0</c>은 같은 판이다.</summary>
    public int CompareTo(ReleaseVersion? other)
    {
        if (other is null) return 1;
        var count = Math.Max(Components.Count, other.Components.Count);
        for (var i = 0; i < count; i++)
        {
            var a = i < Components.Count ? Components[i] : 0;
            var b = i < other.Components.Count ? other.Components[i] : 0;
            if (a != b) return a.CompareTo(b);
        }
        return 0;
    }

    public bool Equals(ReleaseVersion? other) => CompareTo(other) == 0;
    public override bool Equals(object? obj) => obj is ReleaseVersion other && Equals(other);
    public override int GetHashCode() => string.Join(".", Components.Reverse().SkipWhile(part => part == 0).Reverse()).GetHashCode(StringComparison.Ordinal);
    public override string ToString() => string.Join(".", Components);
    public static bool operator >(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) > 0;
    public static bool operator <(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) < 0;
}

/// <summary>GitHub Releases의 판 하나 — Windows판이 쓰는 것만. <see cref="Installer"/>가 없으면 그 판에 Windows판이 없다.</summary>
public sealed record AvailableRelease(ReleaseVersion Version, string Tag, Uri Page, Uri? Installer, string? InstallerSha256);

/// <summary>
/// 새 판 확인의 순수 로직 — macOS판 <c>ReleaseFeed</c>와 같은 저장소 · 같은 규칙(주소는 모두 https · github.com, 초안 · 미리 보기 판은
/// 받지 않는다, 하루 한 번). Windows판의 파일은 <c>Madi-&lt;판&gt;-windows-x64-setup.exe</c>(설치 파일, <c>installer/Madi.iss</c>)다 —
/// macOS판만 낸 판에는 없으므로, 없으면 Windows판의 새 판이 아니다.
///
/// 바꿔 넣기는 하지 않는다: macOS판은 받은 앱이 같은 개발자 팀의 서명인지로 진짜를 가리는데, Windows판은 아직 서명하지 않았다
/// (Authenticode 인증서가 없다). macOS판도 서명하지 않은 빌드는 바꿔 넣지 않고 받는 페이지만 연다 — 같은 규칙이다.
/// </summary>
public static class ReleaseFeed
{
    public const string Repository = "ddiiwoong/madi";
    public static readonly Uri LatestUrl = new($"https://api.github.com/repos/{Repository}/releases/latest");
    public static readonly TimeSpan CheckInterval = TimeSpan.FromDays(1);

    public sealed class ParseError(string message) : Exception(message);

    public static string InstallerName(string tag) => $"Madi-{Bare(tag)}-windows-x64-setup.exe";

    private static string Bare(string tag) => tag.StartsWith('v') || tag.StartsWith('V') ? tag[1..] : tag;

    public static AvailableRelease Parse(string json)
    {
        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(json);
            root = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            throw new ParseError("JSON이 아닙니다");
        }
        if (root.ValueKind != JsonValueKind.Object) throw new ParseError("JSON 객체가 아닙니다");
        var tag = Text(root, "tag_name") ?? throw new ParseError("tag_name이 없습니다");
        var version = ReleaseVersion.Parse(tag) ?? throw new ParseError($"판 번호가 아닙니다: {tag}");
        if (Flag(root, "draft") || Flag(root, "prerelease")) throw new ParseError("정식 판이 아닙니다");
        var pageText = Text(root, "html_url") ?? throw new ParseError("html_url이 없습니다");
        if (!Uri.TryCreate(pageText, UriKind.Absolute, out var page) || !IsGitHub(page, "github.com", $"/{Repository}/releases"))
        {
            throw new ParseError($"뜻밖의 주소입니다: {pageText}");
        }
        Uri? installer = null;
        string? digest = null;
        var wanted = InstallerName(tag);
        if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
        {
            foreach (var asset in assets.EnumerateArray())
            {
                if (asset.ValueKind != JsonValueKind.Object || Text(asset, "name") != wanted) continue;
                var download = Text(asset, "browser_download_url") ?? "";
                if (!Uri.TryCreate(download, UriKind.Absolute, out var url) || !IsGitHub(url, "github.com", $"/{Repository}/releases/download/"))
                {
                    throw new ParseError($"뜻밖의 주소입니다: {download}");
                }
                installer = url;
                digest = Sha256(Text(asset, "digest"));
            }
        }
        return new AvailableRelease(version, tag, page, installer, digest);
    }

    /// <summary>Windows판의 새 판인가 — 판이 더 높고, 그 판에 Windows판 파일이 있다.</summary>
    public static bool IsNewer(AvailableRelease release, ReleaseVersion current) => release.Installer is not null && release.Version > current;

    /// <summary>켤 때 확인할 차례인가. 시계를 되돌려 지난번이 앞날이 되면 다시 잰다.</summary>
    public static bool IsCheckDue(DateTimeOffset? lastCheck, DateTimeOffset now)
    {
        if (lastCheck is null) return true;
        var elapsed = now - lastCheck.Value;
        return elapsed >= CheckInterval || elapsed < TimeSpan.Zero;
    }

    internal static string? Sha256(string? digest)
    {
        if (digest is null || !digest.StartsWith("sha256:", StringComparison.Ordinal)) return null;
        var hex = digest["sha256:".Length..].ToLowerInvariant();
        return hex.Length == 64 && hex.All(char.IsAsciiHexDigit) ? hex : null;
    }

    internal static bool IsGitHub(Uri url, string host, string pathPrefix) =>
        url.Scheme == Uri.UriSchemeHttps && url.Host == host && url.IsDefaultPort && url.UserInfo.Length == 0
        && url.AbsolutePath.StartsWith(pathPrefix, StringComparison.Ordinal);

    private static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool Flag(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;
}
