using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace Madi;

/// <summary>
/// 한 번만 켜기 — 두 번째로 켠 마디(탐색기에서 파일을 두 번 누름, <c>madi://</c> 링크)는 받은 것(파일 경로 · 링크)을 이미 켜진 마디에
/// 넘기고 곧 끝난다. 켜진 마디가 그 창을 앞으로 가져온다(macOS판은 시스템이 해 준다).
///
/// 사용자마다 따로다(이름에 SID). 파이프는 같은 사용자만 열 수 있다(<see cref="PipeOptions.CurrentUserOnly"/>) — 다른 계정의 프로그램이
/// 마디에 파일 · 링크를 밀어 넣지 못하게. 넘기지 못하면(켜진 마디가 답하지 않음) 따로 켠다 — 파일을 못 여는 것보다 낫다.
/// </summary>
public sealed class SingleInstance : IDisposable
{
    /// <summary>받을 것 없이 다시 켰다 — 켜진 마디가 새 창을 연다(Windows의 약속: 앱을 다시 켜면 새 창).</summary>
    public const string NewWindow = "--new-window";

    /// <summary>켜진 마디가 창을 앞으로 가져올 수 있게 — Windows는 앞에 있지 않은 프로세스가 창을 앞으로 올리지 못하게 막는다.</summary>
    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int processId);

    private readonly Mutex mutex;
    private readonly string pipeName;
    private readonly CancellationTokenSource stop = new();

    public bool IsPrimary { get; }

    /// <param name="instance">이름 덧붙이기 — 확인 실행은 <c>smoke</c>로 따로 둔다(사용자가 켜 둔 마디에 넘기지 않게).</param>
    public SingleInstance(string instance = "")
    {
        var user = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        var name = $"Madi-{user}{(instance.Length > 0 ? "-" + instance : "")}";
        pipeName = name;
        mutex = new Mutex(initiallyOwned: true, $@"Local\{name}", out var created);
        IsPrimary = created;
    }

    /// <summary>두 번째 마디 — 켜진 마디에 넘긴다. 받았으면 true.</summary>
    public bool Forward(IReadOnlyList<string> items, TimeSpan timeout)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            client.Connect((int)timeout.TotalMilliseconds);
            AllowSetForegroundWindow(-1); // ASFW_ANY
            var bytes = JsonSerializer.SerializeToUtf8Bytes(items);
            client.Write(bytes);
            client.Flush();
            return true;
        }
        catch (Exception error) when (error is TimeoutException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>켜진 마디 — 넘겨받을 때마다 <paramref name="received"/>(UI 스레드가 아닌 곳에서 부른다).</summary>
    public void Listen(Action<IReadOnlyList<string>> received)
    {
        _ = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(pipeName, PipeDirection.In, NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await server.WaitForConnectionAsync(stop.Token);
                    using var buffer = new MemoryStream();
                    await server.CopyToAsync(buffer, stop.Token);
                    var items = Decode(buffer.ToArray());
                    if (items.Count > 0) received(items);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
                {
                    // 덜 보낸 것 · 깨진 것 — 버리고 다음을 기다린다.
                }
            }
        });
    }

    /// <summary>받은 바이트 — 글 배열(JSON)만. 모양이 다르면 빈 목록.</summary>
    public static List<string> Decode(byte[] bytes)
    {
        try
        {
            return JsonSerializer.Deserialize<List<string?>>(Encoding.UTF8.GetString(bytes))?.OfType<string>().ToList() ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        if (IsPrimary)
        {
            try
            {
                mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // 다른 스레드에서 끝냈다 — 프로세스가 끝나면 풀린다.
            }
        }
        mutex.Dispose();
    }
}
