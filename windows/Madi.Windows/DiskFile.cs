using System.IO;
using System.Security.Cryptography;

namespace Madi;

/// <summary>무엇이 바뀌었나 — 그대로 · 끝에 붙음(붙은 바이트) · 다르게 바뀜(파일 전체) · 없음(지워짐 · 바꿔 넣는 중).</summary>
public enum DiskChangeKind { Unchanged, Appended, Replaced, Missing }

public readonly record struct DiskChange(DiskChangeKind Kind, byte[] Bytes);

/// <summary>
/// 디스크에서 마지막으로 맞춰 본 파일 — 읽은 것, 저장이 쓴 것, 바깥에서 들인 것(macOS판 <c>DiskBaseline</c>와 같은 규칙).
/// 길어졌고 끝 4KB가 그대로면 끝에 붙은 것으로 보고 붙은 바이트만 읽는다(로그). 길이가 같으면 전체의 SHA-256으로 견준다 —
/// 수정 시각만 바뀐 것(touch)은 바뀐 것이 아니다. 그 밖에는 통째로 읽는다.
/// </summary>
public sealed class DiskBaseline : IDisposable
{
    public const int TailLength = 4096;

    private IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private byte[] tail = [];

    public long Length { get; private set; }

    public static DiskBaseline From(ReadOnlySpan<byte> bytes)
    {
        var baseline = new DiskBaseline();
        baseline.Reset(bytes);
        return baseline;
    }

    /// <summary>쓰는 프로그램이 열어 둔 파일도 읽는다(로그). 지우기 · 이름 바꾸기도 막지 않는다.</summary>
    public static FileStream OpenShared(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);

    public static byte[] ReadAll(string path)
    {
        using var stream = OpenShared(path);
        return Read(stream, stream.Length);
    }

    /// <summary>파일과 견주고, 기준을 지금 파일로 옮긴다.</summary>
    public DiskChange Detect(string path)
    {
        FileStream stream;
        try
        {
            stream = OpenShared(path);
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return new DiskChange(DiskChangeKind.Missing, []);
        }
        using (stream)
        {
            var length = stream.Length;
            if (length > Length)
            {
                stream.Position = Length - tail.Length;
                var current = Read(stream, tail.Length);
                if (current.AsSpan().SequenceEqual(tail))
                {
                    var added = Read(stream, length - Length);
                    Append(added);
                    return new DiskChange(DiskChangeKind.Appended, added);
                }
            }
            stream.Position = 0;
            var all = Read(stream, length);
            if (all.Length == Length && SHA256.HashData(all).AsSpan().SequenceEqual(hash.GetCurrentHash()))
            {
                return new DiskChange(DiskChangeKind.Unchanged, []);
            }
            Reset(all);
            return new DiskChange(DiskChangeKind.Replaced, all);
        }
    }

    private static byte[] Read(Stream stream, long count)
    {
        if (count > int.MaxValue) throw new IOException("2GB보다 큰 파일은 아직 열지 않습니다");
        var buffer = new byte[count];
        var read = stream.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
        return read == buffer.Length ? buffer : buffer[..read];
    }

    private void Append(ReadOnlySpan<byte> added)
    {
        hash.AppendData(added);
        Length += added.Length;
        var joined = new byte[tail.Length + added.Length];
        tail.CopyTo(joined, 0);
        added.CopyTo(joined.AsSpan(tail.Length));
        tail = joined.Length <= TailLength ? joined : joined[^TailLength..];
    }

    private void Reset(ReadOnlySpan<byte> bytes)
    {
        hash.Dispose();
        hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(bytes);
        Length = bytes.Length;
        tail = bytes.Length <= TailLength ? bytes.ToArray() : bytes[^TailLength..].ToArray();
    }

    public void Dispose() => hash.Dispose();
}

public static class AtomicFile
{
    /// <summary>
    /// 같은 폴더의 임시 파일에 다 쓴 뒤 바꿔 넣는다 — 쓰다 멈춰도 원래 파일이 반쯤 쓴 채로 남지 않는다. 바꿔 넣을 수 없으면
    /// (다른 프로그램이 지우기를 막고 열어 둠) 그 자리에 쓴다.
    /// </summary>
    public static void Write(string path, ReadOnlySpan<byte> bytes)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        var temp = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.madi-tmp");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            if (!File.Exists(path))
            {
                File.Move(temp, path);
                return;
            }
            try
            {
                File.Replace(temp, path, destinationBackupFileName: null, ignoreMetadataErrors: true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
    }
}
