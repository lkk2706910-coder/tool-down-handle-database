<%@ Page Language="C#" %>
<%@ Import Namespace="System" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Text" %>
<script runat="server">

// 表格資料儲存 — 依分頁 key 讀/寫各自的 JSON 檔。
//   GET  ?key=xxx : 回傳該分頁資料 (檔案不存在回 204, 前端就用內建預設)
//   POST ?key=xxx : 把 request body (JSON) 覆寫進該分頁的檔
//   key 省略或 = "tooldown" -> data.json; 其他 -> data_<key>.json
//
// 佈署需求: IIS 應用程式集區身分 (例: IIS AppPool\<站台>) 需對「本資料夾」
//           有「修改/寫入」權限, 否則 POST 會 500。
// 注意: 此為簡易 last-write-wins 儲存, 多人同時編輯會互相覆蓋, 適合 PoC。

string ResolveDataPath()
{
    string key = (Request.QueryString["key"] ?? "").Trim();
    // 只允許英數/底線/連字號, 防止路徑穿越
    if (key.Length > 0 && !System.Text.RegularExpressions.Regex.IsMatch(key, "^[A-Za-z0-9_-]+$"))
        throw new Exception("非法的 key");
    string file = (key.Length == 0 || key == "tooldown") ? "data.json" : ("data_" + key + ".json");
    return Server.MapPath(file);
}

void Page_Load(object sender, EventArgs e)
{
    Response.Clear();
    try
    {
        string DataPath = ResolveDataPath();
        string method = Request.HttpMethod.ToUpperInvariant();
        if (method == "GET")
        {
            Response.ContentType = "application/json; charset=utf-8";
            if (File.Exists(DataPath))
                Response.Write(File.ReadAllText(DataPath, Encoding.UTF8));
            else
                Response.StatusCode = 204; // No Content — 尚未有資料
        }
        else if (method == "POST" || method == "PUT")
        {
            string body;
            using (StreamReader sr = new StreamReader(Request.InputStream, Encoding.UTF8))
                body = sr.ReadToEnd();

            if (body == null || body.Trim().Length == 0 || body.Trim()[0] != '{')
                throw new Exception("request body 不是 JSON 物件");

            // 原子寫入: 先寫暫存檔再 replace, 避免寫一半損毀
            string tmp = DataPath + ".tmp";
            File.WriteAllText(tmp, body, new UTF8Encoding(false));
            if (File.Exists(DataPath)) File.Delete(DataPath);
            File.Move(tmp, DataPath);

            Response.ContentType = "application/json; charset=utf-8";
            Response.Write("{\"ok\":true}");
        }
        else
        {
            Response.StatusCode = 405;
            Response.ContentType = "application/json; charset=utf-8";
            Response.Write("{\"error\":\"method not allowed\"}");
        }
    }
    catch (Exception ex)
    {
        Response.StatusCode = 500;
        Response.ContentType = "application/json; charset=utf-8";
        string safe = ex.Message.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", " ").Replace("\r", " ");
        Response.Write("{\"error\":\"" + safe + "\"}");
    }
    Response.End();
}

</script>
