using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Madi;

/// <summary>
/// LLM 교정에 쓸 바깥 서비스 — macOS판 <c>LLMService</c>와 같은 다섯 · 같은 권장 모델 · 같은 인증 헤더.
///
/// <b>지금은 키를 두고 확인하는 데까지다(macOS판도 그렇다).</b> 문서를 바깥으로 보내는 교정은 없다 — 보낼지는 사람이 정할 일이고(TODO
/// '결정이 필요한 것'), 정해지기 전까지 이 타입은 문서를 싣는 요청을 만들지 않는다. 키 확인은 그 서비스에 <b>모델 목록만</b> 묻는다.
/// </summary>
public enum LlmService
{
    Anthropic,
    OpenAI,
    Gemini,
    Groq,
    Bedrock,
}

public static class LlmServices
{
    public static readonly LlmService[] All = Enum.GetValues<LlmService>();

    public const string DefaultBedrockRegion = "us-east-1";

    public static string DisplayName(this LlmService service) => service switch
    {
        LlmService.Anthropic => "Anthropic Claude",
        LlmService.OpenAI => "OpenAI",
        LlmService.Gemini => "Google Gemini",
        LlmService.Groq => "Groq",
        _ => "Amazon Bedrock",
    };

    /// <summary>키를 받는 곳. 화면에 글로 적는다(링크로 열지 않는다).</summary>
    public static string KeyConsole(this LlmService service) => service switch
    {
        LlmService.Anthropic => "console.anthropic.com",
        LlmService.OpenAI => "platform.openai.com/api-keys",
        LlmService.Gemini => "aistudio.google.com/apikey",
        LlmService.Groq => "console.groq.com/keys",
        _ => "console.aws.amazon.com/bedrock",
    };

    /// <summary>소곤의 기본 모델(macOS판과 같다). 키 확인이 "이 키로 그 모델을 쓸 수 있는가"를 함께 알린다.</summary>
    public static string RecommendedModel(this LlmService service) => service switch
    {
        LlmService.Anthropic => "claude-haiku-5-5",
        LlmService.OpenAI => "gpt-5.5",
        LlmService.Gemini => "gemini-3.5-flash-lite",
        LlmService.Groq => "openai/gpt-oss-120b",
        _ => "amazon.nova-lite-v1:0",
    };

    public static bool NeedsRegion(this LlmService service) => service == LlmService.Bedrock;

    /// <summary>리전 이름으로 받을 글자인가 — 주소의 호스트에 들어가므로 아무 글자나 받지 않는다.</summary>
    public static bool IsValidRegion(string region) =>
        region.Length is > 0 and <= 32 && region.All(c => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-');

    /// <summary>키 확인 요청 — 모델 목록을 묻는 GET. 몸통이 없고 문서의 글자는 하나도 싣지 않는다. 키가 비었거나 리전이 이상하면 null.</summary>
    public static HttpRequestMessage? ModelListRequest(this LlmService service, string key, string? region = null)
    {
        key = key.Trim();
        if (key.Length == 0) return null;
        string url;
        switch (service)
        {
            case LlmService.Anthropic: url = "https://api.anthropic.com/v1/models?limit=1000"; break;
            case LlmService.OpenAI: url = "https://api.openai.com/v1/models"; break;
            case LlmService.Gemini: url = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"; break;
            case LlmService.Groq: url = "https://api.groq.com/openai/v1/models"; break;
            default:
                var name = string.IsNullOrEmpty(region) ? DefaultBedrockRegion : region;
                if (!IsValidRegion(name)) return null;
                // 제어 평면의 ListFoundationModels. 실행 평면(bedrock-runtime)에는 목록이 없다.
                url = $"https://bedrock.{name}.amazonaws.com/foundation-models";
                break;
        }
        var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        switch (service)
        {
            case LlmService.Anthropic:
                request.Headers.Add("x-api-key", key);
                request.Headers.Add("anthropic-version", "2023-06-01"); // 없으면 400
                break;
            case LlmService.Gemini:
                // 질의 문자열 `?key=`로도 되지만 그러면 키가 주소에 실려 로그에 남는다.
                request.Headers.Add("x-goog-api-key", key);
                break;
            default:
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
                break;
        }
        return request;
    }

    /// <summary>모델 목록 응답에서 이름을 꺼낸다. 모양이 다르면 빈 목록.</summary>
    public static List<string> ModelIds(this LlmService service, string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return [];
            var (array, field) = service switch
            {
                LlmService.Gemini => ("models", "name"),
                LlmService.Bedrock => ("modelSummaries", "modelId"),
                _ => ("data", "id"),
            };
            if (!root.TryGetProperty(array, out var items) || items.ValueKind != JsonValueKind.Array) return [];
            return items.EnumerateArray()
                .Select(item => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(field, out var value)
                                && value.ValueKind == JsonValueKind.String ? value.GetString() : null)
                .OfType<string>()
                .Select(id => service == LlmService.Gemini && id.StartsWith("models/", StringComparison.Ordinal) ? id["models/".Length..] : id)
                .ToList();
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// <summary>오류 응답에서 사람이 읽을 문장(<c>{"error":{"message"}}</c> · <c>{"message"}</c>). 없으면 null.</summary>
    public static string? ErrorMessage(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object
                && error.TryGetProperty("message", out var nested) && nested.ValueKind == JsonValueKind.String)
            {
                return nested.GetString();
            }
            foreach (var name in new[] { "message", "Message" })
            {
                if (root.TryGetProperty(name, out var message) && message.ValueKind == JsonValueKind.String) return message.GetString();
            }
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>키 확인 — 모델 목록을 물어 한 줄로. 쿠키 · 캐시를 쓰지 않는다(남길 것은 결과 한 줄뿐).</summary>
    public static async Task<string> CheckAsync(this LlmService service, string key, string? region, HttpMessageHandler? handler = null)
    {
        using var request = service.ModelListRequest(key, region);
        if (request is null) return "확인하지 못했습니다: 키나 리전이 비어 있거나 맞지 않습니다";
        using var client = handler is null
            ? new HttpClient(new SocketsHttpHandler { UseCookies = false }) { Timeout = TimeSpan.FromSeconds(15) }
            : new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(15) };
        HttpResponseMessage response;
        string body;
        try
        {
            response = await client.SendAsync(request);
            body = await response.Content.ReadAsStringAsync();
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            return $"서비스에 닿지 못했습니다: {error.Message}";
        }
        using (response)
        {
            var status = (int)response.StatusCode;
            var message = ErrorMessage(body) ?? body[..Math.Min(body.Length, 200)];
            if (status is >= 200 and < 300)
            {
                var models = service.ModelIds(body);
                if (models.Count == 0) return "확인하지 못했습니다: 모델 목록을 읽지 못했습니다";
                var recommended = service.RecommendedModel();
                // 조사를 보간값 뒤에 붙이지 않는다 — 모델 이름의 끝소리를 알 수 없다(macOS판과 같다).
                return models.Contains(recommended)
                    ? $"키가 맞습니다 — 모델 {models.Count}개, 권장 모델 {recommended} 있음"
                    : $"키가 맞습니다 — 모델 {models.Count}개. 목록에 권장 모델이 없습니다: {recommended}";
            }
            return status is 401 or 403 ? $"키가 거절됐습니다 (HTTP {status}): {message}" : $"확인하지 못했습니다: HTTP {status}: {message}";
        }
    }
}
