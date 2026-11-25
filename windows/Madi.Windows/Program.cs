using System.Windows;

namespace Madi;

public static class Program
{
    private static bool? darkMenus;

    /// <summary>메뉴(…) · 대화상자의 밝기를 편집기의 테마에 맞춘다. 창마다 부르지만 바뀔 때만 한다(자원 사전을 다시 싣는다).</summary>
    public static void UseDarkMenus(bool dark)
    {
        if (darkMenus == dark || Application.Current is not { } app) return;
        darkMenus = dark;
#pragma warning disable WPF0001
        app.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
#pragma warning restore WPF0001
    }

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

        // 창마다 문서 하나. 마지막 창을 닫으면 끝난다. 메뉴 · 단추 · 대화상자는 Windows 11의 모양(Fluent)으로 — 밝기는 편집기의 테마를
        // 따른다(`UseDarkMenus`).
        var app = new Application { ShutdownMode = ShutdownMode.OnLastWindowClose };
#pragma warning disable WPF0001 // ThemeMode는 아직 '실험' 표시다(.NET 9부터).
        app.ThemeMode = ThemeMode.Light;
#pragma warning restore WPF0001
        var window = new MainWindow(options);
        if (instance.IsPrimary)
        {
            instance.Listen(received => app.Dispatcher.InvokeAsync(() => MainWindow.HandleForwardedAsync(received)));
        }
        app.Run(window);
        return window.ExitCode;
    }
}
