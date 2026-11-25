using System.IO;
using System.Windows.Threading;

namespace Madi;

/// <summary>
/// 열어 둔 파일을 지켜본다 — 그 파일이 든 폴더를 <see cref="FileSystemWatcher"/>로 보고, 처음 신호에서 0.3초 뒤에 한 번 알린다
/// (macOS판과 같다: 신호마다 미루면 쉬지 않고 쓰는 로그에서 한 번도 알리지 못한다). 다른 편집기가 새 파일로 바꿔 넣으며 저장해도
/// (이름 바꾸기 · 새로 만들기) 같은 이름이면 알린다. 알림은 창의 스레드에서 온다.
/// </summary>
public sealed class FileWatcher : IDisposable
{
    private readonly FileSystemWatcher watcher;
    private readonly DispatcherTimer timer;
    private readonly string name;

    public FileWatcher(string path, Dispatcher dispatcher, Action changed)
    {
        name = Path.GetFileName(path);
        timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(300) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            changed();
        };
        watcher = new FileSystemWatcher(Path.GetDirectoryName(path)!)
        {
            Filter = name,
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.CreationTime,
            IncludeSubdirectories = false,
        };
        watcher.Changed += OnSignal;
        watcher.Created += OnSignal;
        watcher.Renamed += OnSignal;
        watcher.Error += (_, _) => dispatcher.InvokeAsync(changed);
        watcher.EnableRaisingEvents = true;
        void OnSignal(object sender, FileSystemEventArgs e)
        {
            if (!string.Equals(e.Name, name, StringComparison.OrdinalIgnoreCase)) return;
            dispatcher.InvokeAsync(() =>
            {
                if (!timer.IsEnabled) timer.Start();
            });
        }
    }

    public void Dispose()
    {
        timer.Stop();
        watcher.Dispose();
    }
}
