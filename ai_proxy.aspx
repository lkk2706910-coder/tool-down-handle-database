<%@ Page Language="C#" %>
<%@ Import Namespace="System" %>
<%@ Import Namespace="System.Configuration" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Net" %>
<script runat="server">

// AI 聊天 proxy — same-origin .aspx 借既有 IIS auth 設定避開 CORS 與 Windows Auth 質疑。
//
// 部署:
//   1) 把本檔丟到跟 index.html 同一資料夾
//   2) 在該資料夾的 web.config 裡加上 AiGatewayUrl / AiApiKey / AiUserId 三個 appSettings
//      (參考 repo 內 web.config.sample)
// 前端: const AI_API_URL = "ai_proxy.aspx";

void Page_Load(object sender, EventArgs e)
{
    Response.Clear();
    try
    {
        string upstreamUrl = GetSetting("AiGatewayUrl", null);
        string apiKey      = GetSetting("AiApiKey",     null);
        string userId      = GetSetting("AiUserId",     null);
        if (string.IsNullOrEmpty(upstreamUrl)) throw new ConfigurationErrorsException("AiGatewayUrl appSetting 未設定 (web.config)");
        if (string.IsNullOrEmpty(apiKey))      throw new ConfigurationErrorsException("AiApiKey appSetting 未設定 (web.config)");
        if (string.IsNullOrEmpty(userId))      throw new ConfigurationErrorsException("AiUserId appSetting 未設定 (web.config)");

        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(upstreamUrl);
        req.Method      = Request.HttpMethod;
        req.ContentType = "application/json";
        req.Accept      = "*/*";
        req.Headers["api-key"] = apiKey;
        req.Headers["user-id"] = userId;
        req.Timeout = 120000; // 2 min — AI 可能要想久

        if (req.Method == "POST" || req.Method == "PUT")
        {
            Stream reqStream = req.GetRequestStream();
            try { CopyStream(Request.InputStream, reqStream); }
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
        // 上游 4xx/5xx 也轉回 browser, 否則前端只看到一個沒資訊的 5xx
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
    Response.ContentType = "application/json";
    string safe = msg.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", " ").Replace("\r", " ");
    Response.Write("{\"error\":\"" + safe + "\"}");
}

</script>
