using System.Runtime.InteropServices;
using System.Text;

namespace Madi;

/// <summary>
/// MSIX 꾸러미로 깔린 마디인가(Microsoft Store판, <c>windows/msix</c>). 꾸러미면 Windows가 맡는 일을 마디가 하지 않는다:
/// <list type="bullet">
/// <item>새 판 확인 — Store가 업데이트한다(GitHub에 묻고 받는 페이지를 여는 것은 설치 파일판의 일)</item>
/// <item>기본 앱 설정 — 레지스트리의 이름(<c>registeredAppUser</c>)이 아니라 꾸러미의 앱 ID(<c>registeredAUMID</c>)로 연다</item>
/// </list>
/// 설정 · 최근 문서(<c>%APPDATA%\Madi</c>)와 WebView2 자료는 Windows가 꾸러미 안으로 돌려 둔다 — 꾸러미를 지우면 함께 지워진다.
/// </summary>
public static class PackageIdentity
{
    private const int Success = 0;
    private const int InsufficientBuffer = 122;

    /// <summary>매니페스트의 <c>Application Id</c>(<c>windows/msix/AppxManifest.xml</c>).</summary>
    public const string ApplicationId = "Madi";

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentPackageFamilyName(ref int length, StringBuilder? name);

    /// <summary>꾸러미 계열 이름(<c>이름_게시자해시</c>). 꾸러미가 아니면 null.</summary>
    public static string? FamilyName { get; } = Read();

    public static bool IsPackaged => FamilyName is not null;

    /// <summary>앱 사용자 모델 ID(<c>계열 이름!Madi</c>). 꾸러미가 아니면 null.</summary>
    public static string? AppUserModelId => FamilyName is null ? null : $"{FamilyName}!{ApplicationId}";

    private static string? Read()
    {
        try
        {
            var length = 0;
            // 꾸러미가 아니면 APPMODEL_ERROR_NO_PACKAGE(15700).
            if (GetCurrentPackageFamilyName(ref length, null) != InsufficientBuffer) return null;
            var name = new StringBuilder(length);
            return GetCurrentPackageFamilyName(ref length, name) == Success ? name.ToString() : null;
        }
        catch (EntryPointNotFoundException)
        {
            return null;
        }
    }
}
