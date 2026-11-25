using System.IO;

namespace Madi;

/// <summary>
/// 켤 때 받은 것 — 열 파일들, <c>madi://</c> 링크, 확인 실행(<c>--smoke &lt;폴더&gt;</c>), 한 번만 켜기의 이름(<c>--instance &lt;이름&gt;</c>,
/// 확인 실행이 따로 쓴다).
/// </summary>
public sealed record LaunchOptions(string? FilePath, string? SmokeDirectory)
{
    /// <summary>열 파일 모두(탐색기에서 여럿을 골라 열면 여럿이 온다). <see cref="FilePath"/>는 그 첫째.</summary>
    public IReadOnlyList<string> Files { get; init; } = [];

    public IReadOnlyList<string> Urls { get; init; } = [];

    public string Instance { get; init; } = "";

    public static LaunchOptions Parse(string[] args)
    {
        var files = new List<string>();
        var urls = new List<string>();
        string? smoke = null;
        var instance = "";
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--smoke" && i + 1 < args.Length)
            {
                smoke = Path.GetFullPath(args[++i]);
            }
            else if (args[i] == "--instance" && i + 1 < args.Length)
            {
                instance = args[++i];
            }
            else if (MadiUrl.IsMadiUrl(args[i]))
            {
                urls.Add(args[i]);
            }
            else if (!args[i].StartsWith("--", StringComparison.Ordinal))
            {
                try
                {
                    files.Add(Path.GetFullPath(args[i]));
                }
                catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
                {
                    // 경로가 아니다 — 버린다.
                }
            }
        }
        return new LaunchOptions(files.FirstOrDefault(), smoke) { Files = files, Urls = urls, Instance = instance };
    }

    /// <summary>켜진 마디에 넘길 것 — 경로는 이 프로세스의 폴더에서 이미 풀었다(넘겨받는 쪽의 폴더는 다르다).</summary>
    public IReadOnlyList<string> Forwarded => [.. Files, .. Urls];
}
