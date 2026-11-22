using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Unicode;

namespace Madi;

/// <summary>
/// 설정과 최근 파일 — 모든 창이 함께 쓴다. <c>%APPDATA%\Madi\settings.json</c> · <c>recent.json</c>(확인 실행은 그 폴더 안에).
///
/// 설정의 내용(테마 · 글꼴 · 크기 …)은 편집기가 정하고 고친다(<c>windows/editor/src/core/settings.ts</c> — 모르는 값은 기본으로).
/// 여기는 받은 것을 그대로 저장하고 열린 창 모두에 돌려줄 뿐이다. 메뉴의 ✓를 달려고 몇 값만 읽는다.
/// 손으로 고쳐 깨진 파일은 없는 것으로 친다(빈 설정 — 편집기가 기본으로 채운다).
/// </summary>
public sealed class SettingsStore(string folder)
{
    /// <summary>최근 파일은 이만큼 — 오래된 것부터 버린다.</summary>
    public const int RecentLimit = 20;

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.Create(UnicodeRanges.All),
    };

    private JsonObject? settings;
    private List<string>? recent;

    public string Folder => folder;

    private string SettingsPath => Path.Combine(folder, "settings.json");
    private string RecentPath => Path.Combine(folder, "recent.json");

    public static string DefaultFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Madi");

    /// <summary>지금 설정(JSON 객체). 파일이 없거나 깨졌으면 빈 객체.</summary>
    public JsonObject Settings => settings ??= Read(SettingsPath) as JsonObject ?? new JsonObject();

    /// <summary>편집기가 준 설정을 저장한다. 객체가 아니면 받지 않는다.</summary>
    public bool Save(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) return false;
        settings = JsonNode.Parse(value.GetRawText()) as JsonObject ?? new JsonObject();
        Write(SettingsPath, settings.ToJsonString(Options));
        return true;
    }

    public string? Text(string name) =>
        Settings.TryGetPropertyValue(name, out var node) && node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    public bool Flag(string name) =>
        Settings.TryGetPropertyValue(name, out var node) && node is JsonValue value && value.TryGetValue<bool>(out var flag) && flag;

    /// <summary>최근 파일 — 새것이 앞. 지금 없는 파일도 남긴다(USB · 네트워크 위치는 다시 붙는다). 빠른 열기가 거른다.</summary>
    public IReadOnlyList<string> Recent => recent ??= ReadRecent();

    public void AddRecent(string path)
    {
        var list = Recent.Where(item => !string.Equals(item, path, StringComparison.OrdinalIgnoreCase)).Prepend(path).Take(RecentLimit).ToList();
        recent = list;
        Write(RecentPath, JsonSerializer.Serialize(list, Options));
    }

    public void ClearRecent()
    {
        recent = [];
        Write(RecentPath, "[]");
    }

    private List<string> ReadRecent() =>
        Read(RecentPath) is JsonArray array
            ? array.Select(node => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null)
                .OfType<string>().Where(Path.IsPathFullyQualified).Take(RecentLimit).ToList()
            : [];

    private static JsonNode? Read(string path)
    {
        try
        {
            return File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path, Encoding.UTF8)) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    private void Write(string path, string text)
    {
        try
        {
            Directory.CreateDirectory(folder);
            AtomicFile.Write(path, new UTF8Encoding(false).GetBytes(text));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // 설정을 쓰지 못해도 창은 그대로 쓴다 — 다음에 켤 때 기본으로 돌아갈 뿐이다.
        }
    }
}
