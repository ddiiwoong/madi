using System.IO;

namespace Madi;

/// <summary>켤 때 받은 것 — 열 파일, 또는 확인 실행(<c>--smoke &lt;폴더&gt;</c>).</summary>
public sealed record LaunchOptions(string? FilePath, string? SmokeDirectory)
{
    public static LaunchOptions Parse(string[] args)
    {
        string? file = null;
        string? smoke = null;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--smoke" && i + 1 < args.Length)
            {
                smoke = Path.GetFullPath(args[++i]);
            }
            else if (!args[i].StartsWith("--", StringComparison.Ordinal) && file is null)
            {
                file = Path.GetFullPath(args[i]);
            }
        }
        return new LaunchOptions(file, smoke);
    }
}
