using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Windows;
using System.Windows.Threading;

namespace Madi;

/// <summary>
/// 새 판 확인 — 켤 때와 켜 둔 동안 하루 한 번(설정 <c>checksForUpdates</c>, 기본 켜짐), 그리고 도움말 ▸ 업데이트 확인…(묻는다 — 최신일
/// 때와 실패했을 때도 알린다). 보내는 것은 판을 묻는 GET 하나다(로그인 없는 GitHub API, IP마다 시간에 60번).
///
/// 새 판을 찾으면 받는 페이지를 열지 묻는다. <b>바꿔 넣지는 않는다</b> — 서명하지 않은 판이라 받은 파일이 진짜인지 가릴 길이 없다
/// (<see cref="ReleaseFeed"/>). 저절로 한 확인은 새 판이 있을 때만 알리고, 실패는 알리지 않는다(다음 날 다시 한다).
/// </summary>
public static class Updates
{
    public static ReleaseVersion Current { get; } =
        ReleaseVersion.Parse(typeof(Updates).Assembly.GetName().Version?.ToString(3)) ?? ReleaseVersion.Parse("0.0.0")!;

    private static DispatcherTimer? timer;
    private static bool checking;

    public static void CheckAtLaunch(Window owner)
    {
        if (Due()) _ = CheckAsync(owner, interactive: false);
        // 며칠씩 켜 두는 사람에게도 — 시간마다 차례인지 본다(확인은 하루 한 번).
        timer ??= new DispatcherTimer(TimeSpan.FromHours(1), DispatcherPriority.Background, (_, _) =>
        {
            if (Due() && MainWindow.OpenWindows.LastOrDefault() is { } window) _ = CheckAsync(window, interactive: false);
        }, owner.Dispatcher);
    }

    private static bool Due()
    {
        if (!MainWindow.Store.FlagOr("checksForUpdates", true)) return false;
        var last = DateTimeOffset.TryParse(MainWindow.Store.HostText("lastUpdateCheck"), CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind, out var parsed) ? parsed : (DateTimeOffset?)null;
        return ReleaseFeed.IsCheckDue(last, DateTimeOffset.UtcNow);
    }

    public static async Task CheckAsync(Window owner, bool interactive)
    {
        if (checking) return;
        checking = true;
        try
        {
            var release = await FetchAsync();
            MainWindow.Store.SetHostText("lastUpdateCheck", DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture));
            if (release is not null && ReleaseFeed.IsNewer(release, Current))
            {
                var answer = MessageBox.Show(owner,
                    $"마디 Windows판 {release.Version}이(가) 나왔습니다(지금 {Current}).\n\n" +
                    "이 판은 서명하지 않아 저절로 바꿔 넣지 않습니다. 받는 페이지를 열까요?",
                    "마디 업데이트", MessageBoxButton.YesNo, MessageBoxImage.Information);
                if (answer == MessageBoxResult.Yes) Process.Start(new ProcessStartInfo(release.Page.AbsoluteUri) { UseShellExecute = true });
            }
            else if (interactive)
            {
                var latest = release is null ? "아직 낸 판이 없습니다"
                    : release.Installer is null ? $"마지막 판 {release.Version}에는 Windows판이 없습니다"
                    : $"마지막 판 {release.Version}";
                MessageBox.Show(owner, $"최신입니다 — 지금 {Current}. {latest}.", "마디 업데이트", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or ReleaseFeed.ParseError)
        {
            if (interactive)
            {
                MessageBox.Show(owner, $"새 판을 확인하지 못했습니다: {error.Message}", "마디 업데이트", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
        finally
        {
            checking = false;
        }
    }

    /// <summary>맨 마지막 판. 낸 판이 아직 없으면(404) null.</summary>
    private static async Task<AvailableRelease?> FetchAsync()
    {
        using var client = new HttpClient(new SocketsHttpHandler { UseCookies = false }) { Timeout = TimeSpan.FromSeconds(15) };
        using var request = new HttpRequestMessage(HttpMethod.Get, ReleaseFeed.LatestUrl);
        // GitHub API는 User-Agent가 없으면 받지 않는다.
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("Madi-Windows", Current.ToString()));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        using var response = await client.SendAsync(request);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        return ReleaseFeed.Parse(await response.Content.ReadAsStringAsync());
    }
}
