using System.Windows;

namespace Madi;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        var options = LaunchOptions.Parse(args);
        var smoke = options.SmokeDirectory is not null;
        // 확인 실행은 사용자의 설정 · 최근 문서를 건드리지 않는다 — 그 폴더 안에 따로.
        MainWindow.Store = new SettingsStore(options.SmokeDirectory is { } directory
            ? System.IO.Path.Combine(directory, "settings")
            : SettingsStore.DefaultFolder);
        MainWindow.SmokeMode = smoke;

        // 한 번만 켜기 — 이미 켜진 마디가 있으면 받은 것을 넘기고 끝난다. 확인 실행은 이름을 따로 둔다(켜 둔 마디에 넘기지 않게).
        using var instance = new SingleInstance(smoke ? "smoke" : options.Instance);
        if (!instance.IsPrimary && !smoke)
        {
            var items = options.Forwarded.Count > 0 ? options.Forwarded : [SingleInstance.NewWindow];
            if (instance.Forward(items, TimeSpan.FromSeconds(3))) return 0;
            // 켜진 마디가 답하지 않는다 — 따로 켠다(파일을 못 여는 것보다 낫다).
        }

        // 창마다 문서 하나. 마지막 창을 닫으면 끝난다.
        var app = new Application { ShutdownMode = ShutdownMode.OnLastWindowClose };
        var window = new MainWindow(options);
        if (instance.IsPrimary)
        {
            instance.Listen(received => app.Dispatcher.InvokeAsync(() => MainWindow.HandleForwardedAsync(received)));
        }
        app.Run(window);
        return window.ExitCode;
    }
}
