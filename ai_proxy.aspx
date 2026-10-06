<%@ Page Language="C#" %>
<%@ Import Namespace="System" %>
<%@ Import Namespace="System.Configuration" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Net" %>
<%@ Import Namespace="System.Text" %>
<script runat="server">

// AI 聊天 proxy — same-origin .aspx 借既有 IIS auth 設定避開 CORS 與 Windows Auth 質疑。
//
// 流程: 瀏覽器 POST {messages:[...]} -> 本 proxy -> 內網 AI Gateway
//        (OpenAI chat-completions 相容介面, LiteLLM)
//
// 設定全部放伺服器 web.config appSettings, 瀏覽器永遠拿不到:
//   AiGatewayUrl : 例 https://f12asddllmlog.umc.com/chat/completions
//   AiApiKey     : 驗證用 api-key header
//   AiUserId     : 驗證用 user-id header (工號)
//   AiModel      : body 必帶的 model 名 (由本 proxy 注入到 request body)
//
// 行為:
//   - 先驗登入: 沒登入回 HTTP 200 + {"ok":false,"error":"needLogin"}
//   - 把 AiModel 注入進 request body 的 JSON (瀏覽器不需要也不知道 model)
//   - 上游 4xx/5xx 原文轉回; 連不上回 502
//
// 前端: const AI_API_URL = "ai_proxy.aspx";

void Page_Load(object sender, EventArgs e)
{
    Response.Clear();

    // --- 先驗登入 ---
    if (!Request.IsAuthenticated)
    {
        Response.StatusCode  = 200;
        Response.ContentType = "application/json; charset=utf-8";
        Response.Write("{\"ok\":false,\"error\":\"needLogin\"}");
        Response.End();
        return;
    }

    try
    {
        string upstreamUrl = GetSetting("AiGatewayUrl", null);
        string apiKey      = GetSetting("AiApiKey",     null);
        string userId      = GetSetting("AiUserId",     null);
        string model       = GetSetting("AiModel",      null);
        if (string.IsNullOrEmpty(upstreamUrl)) throw new ConfigurationErrorsException("AiGatewayUrl appSetting 未設定 (web.config)");
        if (string.IsNullOrEmpty(apiKey))      throw new ConfigurationErrorsException("AiApiKey appSetting 未設定 (web.config)");
        if (string.IsNullOrEmpty(userId))      throw new ConfigurationErrorsException("AiUserId appSetting 未設定 (web.config)");
        if (string.IsNullOrEmpty(model))       throw new ConfigurationErrorsException("AiModel appSetting 未設定 (web.config)");

        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(upstreamUrl);
        req.Method      = Request.HttpMethod;
        req.ContentType = "application/json";
        req.Accept      = "*/*";
        req.Headers["api-key"] = apiKey;
        req.Headers["user-id"] = userId;
        req.Timeout = 120000; // 2 min — AI 可能要想久

        if (req.Method == "POST" || req.Method == "PUT")
        {
            // 讀出瀏覽器送來的 body, 注入 model, 再轉送
            string body;
            using (StreamReader sr = new StreamReader(Request.InputStream, Encoding.UTF8))
                body = sr.ReadToEnd();

            body = InjectModel(body, model);

            byte[] bytes = Encoding.UTF8.GetBytes(body);
            req.ContentLength = bytes.Length;
            Stream reqStream = req.GetRequestStream();
            try { reqStream.Write(bytes, 0, bytes.Length); }
            finally { reqStream.Close(); }
        }

        HttpWebResponse res = (HttpWebResponse)req.GetResponse();
        try
        {
            Response.StatusCode  = (int)res.StatusCode;
            Response.ContentType = res.ContentType != null ? res.ContentType : "application/json";
            Stream resStream = res.GetResponseStream();
            try { CopyStream(resStream, Response.OutputStream); }
            finally { resStream.Close(); }
        }
        finally { res.Close(); }
    }
    catch (WebException wex)
    {
        // 上游 4xx/5xx 也原文轉回 browser, 否則前端只看到一個沒資訊的 5xx
        HttpWebResponse res = wex.Response as HttpWebResponse;
        if (res != null)
        {
            Response.StatusCode  = (int)res.StatusCode;
            Response.ContentType = res.ContentType != null ? res.ContentType : "application/json";
            Stream s = res.GetResponseStream();
            try { CopyStream(s, Response.OutputStream); }
            finally { s.Close(); res.Close(); }
        }
        else
        {
            WriteJsonError(502, "upstream unreachable: " + wex.Message);
        }
    }
    catch (Exception ex)
    {
        WriteJsonError(500, ex.GetType().Name + ": " + ex.Message);
    }
    Response.End();
}

// 把 "model":"..." 注入進 JSON body 的最外層物件 (插在第一個 '{' 之後)。
// body 若已含 model 就不重複加。
static string InjectModel(string body, string model)
{
    if (body == null) body = "";
    string trimmed = body.TrimStart();
    int brace = body.IndexOf('{');
    if (brace < 0) return body;                       // 不是 JSON 物件, 原樣送出
    if (HasTopLevelModel(trimmed)) return body;       // 已帶 model, 不覆蓋

    string rest = body.Substring(brace + 1);
    string sep  = rest.TrimStart().StartsWith("}") ? "" : ",";
    string field = "\"model\":\"" + JsonEsc(model) + "\"" + sep;
    return body.Substring(0, brace + 1) + field + rest;
}

static bool HasTopLevelModel(string trimmed)
{
    // 粗略判斷: body 一開頭就是 {"model": 或 { "model":
    string s = trimmed.Length > 0 && trimmed[0] == '{' ? trimmed.Substring(1).TrimStart() : trimmed;
    return s.StartsWith("\"model\"");
}

static string JsonEsc(string s)
{
    if (s == null) return "";
    return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
}

static string GetSetting(string key, string fallback)
{
    string v = ConfigurationManager.AppSettings[key];
    return string.IsNullOrEmpty(v) ? fallback : v;
}

// 手動 copy stream — 相容 .NET 2.0 (Stream.CopyTo 4.0 才有)
static void CopyStream(Stream src, Stream dst)
{
    byte[] buf = new byte[8192];
    int n;
    while ((n = src.Read(buf, 0, buf.Length)) > 0)
    {
        dst.Write(buf, 0, n);
    }
}

void WriteJsonError(int status, string msg)
{
    Response.StatusCode  = status;
    Response.ContentType = "application/json; charset=utf-8";
    string safe = msg.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", " ").Replace("\r", " ");
    Response.Write("{\"ok\":false,\"error\":\"" + safe + "\"}");
}

</script>
