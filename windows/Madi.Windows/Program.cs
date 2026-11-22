using System.Windows;

namespace Madi;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        var options = LaunchOptions.Parse(args);
        // 확인 실행은 사용자의 설정 · 최근 문서를 건드리지 않는다 — 그 폴더 안에 따로.
        MainWindow.Store = new SettingsStore(options.SmokeDirectory is { } smoke
            ? System.IO.Path.Combine(smoke, "settings")
            : SettingsStore.DefaultFolder);
        // 창마다 문서 하나. 마지막 창을 닫으면 끝난다.
        var app = new Application { ShutdownMode = ShutdownMode.OnLastWindowClose };
        var window = new MainWindow(options);
        app.Run(window);
        return window.ExitCode;
    }
}
