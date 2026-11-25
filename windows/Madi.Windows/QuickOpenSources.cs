using System.IO;

namespace Madi;

/// <summary>
/// 빠른 열기(Ctrl+P)가 보일 문서 — 열린 문서, 최근 문서, 지금 문서의 폴더에 든 파일. macOS판 <c>QuickPickSources</c>와 같은 규칙:
/// 숨은 것 · <c>node_modules</c> · <c>DerivedData</c> · <c>Pods</c> · <c>vendor</c> · <c>*.assets</c>는 건너뛰고, 상한이 둘이다(찾은 파일
/// 2000개, 들여다본 항목 20,000개) — 홈 폴더 같은 큰 곳에서 열어도 끝없이 훑지 않는다.
/// </summary>
public static class QuickOpenSources
{
    public sealed record Candidate(string Path, string Name, string Detail);

    public static readonly IReadOnlySet<string> SkippedFolders =
        new HashSet<string>(["node_modules", "DerivedData", "Pods", "vendor"], StringComparer.OrdinalIgnoreCase);

    /// <summary>편집기가 여는 파일(<c>windows/editor/src/core/kind.ts</c>의 <c>openableExtensions</c>와 같다).</summary>
    public static readonly IReadOnlySet<string> OpenableExtensions =
        new HashSet<string>([".md", ".markdown", ".mdown", ".mkd", ".mkdn", ".mdx", ".txt", ".text", ".log"], StringComparer.OrdinalIgnoreCase);

    private static bool Hidden(FileSystemInfo entry) =>
        entry.Name.StartsWith('.') || (entry.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0;

    /// <summary><paramref name="root"/> 아래의 열 수 있는 파일 — 너비 우선, 경로 순.</summary>
    public static List<string> FolderFiles(string root, int limit = 2000, int visitLimit = 20_000)
    {
        var found = new List<string>();
        var visited = 0;
        var queue = new Queue<DirectoryInfo>();
        queue.Enqueue(new DirectoryInfo(root));
        while (queue.Count > 0 && found.Count < limit && visited < visitLimit)
        {
            var directory = queue.Dequeue();
            IEnumerable<FileSystemInfo> entries;
            try
            {
                entries = directory.EnumerateFileSystemInfos().OrderBy(entry => entry.Name, StringComparer.OrdinalIgnoreCase).ToList();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                continue;
            }
            foreach (var entry in entries)
            {
                if (++visited > visitLimit || found.Count >= limit) break;
                if (Hidden(entry)) continue;
                if (entry is DirectoryInfo folder)
                {
                    // 바로 가기 폴더(정션 · 심볼릭 링크)는 따라가지 않는다 — 돌고 돌 수 있다.
                    if ((folder.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                    if (SkippedFolders.Contains(folder.Name) || folder.Name.EndsWith(".assets", StringComparison.OrdinalIgnoreCase)) continue;
                    queue.Enqueue(folder);
                }
                else if (OpenableExtensions.Contains(entry.Extension))
                {
                    found.Add(entry.FullName);
                }
            }
        }
        found.Sort(StringComparer.OrdinalIgnoreCase);
        return found;
    }

    /// <summary>한 목록으로 — 열린 문서, 최근 문서, 폴더의 파일 순. 같은 파일은 한 번만(대소문자 무시 — Windows의 경로).</summary>
    public static List<Candidate> Candidates(IEnumerable<string> open, IEnumerable<string> recent, IEnumerable<string> folderFiles,
        string? root, string home)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<Candidate>();
        foreach (var path in open.Concat(recent).Concat(folderFiles))
        {
            string full;
            try
            {
                full = System.IO.Path.GetFullPath(path);
            }
            catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
            {
                continue;
            }
            if (!seen.Add(full)) continue;
            result.Add(new Candidate(full, System.IO.Path.GetFileName(full), Detail(full, root, home)));
        }
        return result;
    }

    /// <summary>흐린 둘째 줄 — 폴더 안이면 <c>폴더\하위</c>, 밖이면 사용자 폴더를 <c>~</c>로 줄인 위치.</summary>
    public static string Detail(string path, string? root, string home)
    {
        var folder = System.IO.Path.GetDirectoryName(path) ?? path;
        if (root is not null)
        {
            var baseFolder = System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(root));
            var name = System.IO.Path.GetFileName(baseFolder);
            if (string.Equals(folder, baseFolder, StringComparison.OrdinalIgnoreCase)) return name;
            if (folder.StartsWith(baseFolder + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                return name + folder[baseFolder.Length..];
            }
        }
        var profile = System.IO.Path.TrimEndingDirectorySeparator(home);
        if (string.Equals(folder, profile, StringComparison.OrdinalIgnoreCase)) return "~";
        if (folder.StartsWith(profile + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            return "~" + folder[profile.Length..];
        }
        return folder;
    }
}
