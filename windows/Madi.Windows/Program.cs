using System.Windows;

namespace Madi;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        var options = LaunchOptions.Parse(args);
        // 창마다 문서 하나. 마지막 창을 닫으면 끝난다.
        var app = new Application { ShutdownMode = ShutdownMode.OnLastWindowClose };
        var window = new MainWindow(options);
        app.Run(window);
        return window.ExitCode;
    }
}
