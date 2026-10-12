// bench/aspnet/Program.cs — sparringhttp ASP.NET Core bench server (minimal API).
//
// Endpoints are identical to the kabelweb / Fiber / Axum bench servers so all
// frameworks are measured on the same workload. Listens on 0.0.0.0:29590
// inside the container namespace (the sandbox publishes 127.0.0.1:<port> ->
// 29590 on the host side, keeping exposure loopback-only).
//
// Realistic-payload contract (shared by all four servers, byte-identical):
//   GET  /api/v1/product/:id -> ~1KB static product JSON with :id substituted
//   POST /api/v1/checkout     -> parses a ~0.6KB cart JSON, 10% off for
//                                coupon SAVE10, returns order confirmation.
//   Fixed cart subtotal = 183.62, discount = 18.362, total = 165.26, items = 9.
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

const int MaxBody = 32 * 1024;
const string DbConnStr = "Data Source=/tmp/sparring_sqlite.db;Cache=Shared";

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.WebHost.UseUrls("http://0.0.0.0:29590");
builder.WebHost.ConfigureKestrel(o => o.AddServerHeader = false);
var app = builder.Build();

app.UseWebSockets();

app.MapGet("/ws", async (HttpContext ctx) =>
{
    if (!ctx.WebSockets.IsWebSocketRequest)
    {
        ctx.Response.StatusCode = 400;
        return;
    }
    using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
    var buffer = new byte[4096];
    while (true)
    {
        var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None);
        if (result.MessageType == System.Net.WebSockets.WebSocketMessageType.Close)
        {
            await ws.CloseAsync(result.CloseStatus ?? System.Net.WebSockets.WebSocketCloseStatus.NormalClosure, result.CloseStatusDescription, CancellationToken.None);
            break;
        }
        await ws.SendAsync(new ArraySegment<byte>(buffer, 0, result.Count), result.MessageType, true, CancellationToken.None);
    }
});

app.MapGet("/events", async (HttpContext ctx) =>
{
    ctx.Response.Headers.ContentType = "text/event-stream";
    ctx.Response.Headers.CacheControl = "no-cache";
    ctx.Response.Headers.Connection = "keep-alive";
    for (int i = 1; i <= 5; i++)
    {
        await ctx.Response.WriteAsync($"id: {i}\nevent: tick\ndata: {{\"seq\":{i}}}\n\n");
        await ctx.Response.Body.FlushAsync();
    }
});

app.MapGet("/page", (HttpRequest req) =>
{
    string? name = req.Query["name"];
    if (string.IsNullOrEmpty(name))
        name = "HTTP";
    string encoded = System.Net.WebUtility.HtmlEncode(name);
    string html = $"<!doctype html><html><head><meta charset=\"utf-8\"><title>Hello</title></head><body><h1>Hello, {encoded}!</h1></body></html>";
    return Results.Content(html, "text/html; charset=utf-8");
});

app.MapGet("/health", () => Results.Text("OK", "text/plain"));

app.MapGet("/hello/{name}", (string name) =>
    Results.Text($"Hello, {name}! (greeting: hello, mood: neutral)", "text/plain"));

app.MapPost("/api/v1/echo", async (HttpRequest req) =>
{
    using var ms = new MemoryStream();
    await req.Body.CopyToAsync(ms);
    if (ms.Length > MaxBody)
        return Results.Text("body too large", "text/plain", statusCode: 413);
    return Results.Bytes(ms.ToArray());
});

app.MapPost("/users", async (HttpRequest req) =>
{
    string body;
    using (var sr = new StreamReader(req.Body)) body = await sr.ReadToEndAsync();
    string username = "", email = "";
    try
    {
        using var doc = JsonDocument.Parse(body);
        if (doc.RootElement.TryGetProperty("username", out var u) && u.ValueKind == JsonValueKind.String)
            username = u.GetString() ?? "";
        if (doc.RootElement.TryGetProperty("email", out var e) && e.ValueKind == JsonValueKind.String)
            email = e.GetString() ?? "";
    }
    catch (JsonException)
    {
        return Results.Text("invalid JSON", "text/plain", statusCode: 400);
    }
    // Manual compact JSON, same shape as the other bench servers.
    return Results.Content(
        "{\"username\":\"" + username + "\",\"email\":\"" + email + "\"}",
        "application/json", statusCode: 201);
});

app.MapGet("/api/v1/product/{id}", (string id) =>
{
    if (!int.TryParse(id, NumberStyles.Integer, CultureInfo.InvariantCulture, out var num))
        num = 0;
    return Results.Content(ProductJson(num), "application/json");
});

app.MapPost("/api/v1/checkout", async (HttpRequest req) =>
{
    string body;
    using (var sr = new StreamReader(req.Body)) body = await sr.ReadToEndAsync();
    if (body.Length > MaxBody)
        return Results.Text("body too large", "text/plain", statusCode: 413);
    string userId;
    double subtotal = 0;
    int count = 0;
    string coupon = "";
    try
    {
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;
        if (!root.TryGetProperty("user_id", out var uid) || uid.ValueKind != JsonValueKind.String)
            return Results.Text("invalid JSON", "text/plain", statusCode: 400);
        userId = uid.GetString() ?? "";
        if (!root.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Array)
            return Results.Text("invalid JSON", "text/plain", statusCode: 400);
        foreach (var it in items.EnumerateArray())
        {
            if (!it.TryGetProperty("qty", out var q) || !it.TryGetProperty("price", out var p))
                return Results.Text("invalid JSON", "text/plain", statusCode: 400);
            int qty = q.GetInt32();
            double price = p.GetDouble();
            subtotal += qty * price;
            count += qty;
        }
        if (count == 0)
            return Results.Text("invalid JSON", "text/plain", statusCode: 400);
        if (root.TryGetProperty("coupon", out var c) && c.ValueKind == JsonValueKind.String)
            coupon = c.GetString() ?? "";
    }
    catch (JsonException)
    {
        return Results.Text("invalid JSON", "text/plain", statusCode: 400);
    }
    double discount = coupon == "SAVE10" ? subtotal * 0.10 : 0;
    double total = subtotal - discount;
    string totalStr = total.ToString("F2", CultureInfo.InvariantCulture);
    return Results.Content(
        "{\"order_id\":\"ord-" + userId + "\",\"status\":\"confirmed\",\"items\":" +
        count.ToString(CultureInfo.InvariantCulture) + ",\"total\":" + totalStr +
        ",\"currency\":\"USD\",\"eta\":\"2026-09-25\"}",
        "application/json");
});

// ---- SQLite scenario (shared contract, byte-identical across all 4 servers) ----
SeedDb();

app.MapGet("/db/health", () =>
{
    using var conn = OpenDb();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT 1;";
    cmd.ExecuteScalar();
    return Results.Content("{\"ok\":true}", "application/json");
});

app.MapGet("/db/user/{id}", (string id) =>
{
    if (!long.TryParse(id, NumberStyles.Integer, CultureInfo.InvariantCulture, out var num))
        return Results.Text("not found", "text/plain", statusCode: 404);
    using var conn = OpenDb();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT id, username, email FROM users WHERE id=$1;";
    cmd.Parameters.AddWithValue("$1", num);
    using var r = cmd.ExecuteReader();
    if (!r.Read())
        return Results.Text("not found", "text/plain", statusCode: 404);
    return Results.Content(DbRowJson(r.GetInt64(0), r.GetString(1), r.GetString(2)), "application/json");
});

app.MapGet("/db/users", (HttpRequest req) =>
{
    int limit = 20;
    string ls = req.Query["limit"].ToString();
    if (!string.IsNullOrEmpty(ls) && int.TryParse(ls, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n))
        limit = n;
    limit = Math.Clamp(limit, 1, 100);
    using var conn = OpenDb();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT id, username, email FROM users ORDER BY id LIMIT $1;";
    cmd.Parameters.AddWithValue("$1", limit);
    using var r = cmd.ExecuteReader();
    var sb = new StringBuilder("[");
    bool first = true;
    while (r.Read())
    {
        if (!first) sb.Append(',');
        first = false;
        sb.Append(DbRowJson(r.GetInt64(0), r.GetString(1), r.GetString(2)));
    }
    sb.Append(']');
    return Results.Content(sb.ToString(), "application/json");
});

app.MapPost("/db/user", async (HttpRequest req) =>
{
    string body;
    using (var ms = new MemoryStream())
    {
        await req.Body.CopyToAsync(ms);
        if (ms.Length > MaxBody)
            return Results.Text("invalid JSON", "text/plain", statusCode: 400);
        body = Encoding.UTF8.GetString(ms.ToArray());
    }
    if (!TryParseDbUser(body, out string username, out string email))
        return Results.Text("invalid JSON", "text/plain", statusCode: 400);
    using var conn = OpenDb();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "INSERT INTO users(username, email) VALUES($u, $e); SELECT last_insert_rowid();";
    cmd.Parameters.AddWithValue("$u", username);
    cmd.Parameters.AddWithValue("$e", email);
    long newId = (long)cmd.ExecuteScalar()!;
    return Results.Content(DbRowJson(newId, username, email), "application/json", statusCode: 201);
});

app.MapPut("/db/user/{id}", async (string id, HttpRequest req) =>
{
    if (!long.TryParse(id, NumberStyles.Integer, CultureInfo.InvariantCulture, out var num))
        return Results.Text("not found", "text/plain", statusCode: 404);
    string body;
    using (var ms = new MemoryStream())
    {
        await req.Body.CopyToAsync(ms);
        if (ms.Length > MaxBody)
            return Results.Text("invalid JSON", "text/plain", statusCode: 400);
        body = Encoding.UTF8.GetString(ms.ToArray());
    }
    if (!TryParseDbUser(body, out string username, out string email))
        return Results.Text("invalid JSON", "text/plain", statusCode: 400);
    using var conn = OpenDb();
    using (var cmd = conn.CreateCommand())
    {
        cmd.CommandText = "UPDATE users SET username=$u, email=$e WHERE id=$id;";
        cmd.Parameters.AddWithValue("$u", username);
        cmd.Parameters.AddWithValue("$e", email);
        cmd.Parameters.AddWithValue("$id", num);
        if (cmd.ExecuteNonQuery() == 0)
            return Results.Text("not found", "text/plain", statusCode: 404);
    }
    using (var cmd = conn.CreateCommand())
    {
        cmd.CommandText = "SELECT id, username, email FROM users WHERE id=$1;";
        cmd.Parameters.AddWithValue("$1", num);
        using var r = cmd.ExecuteReader();
        r.Read();
        return Results.Content(DbRowJson(r.GetInt64(0), r.GetString(1), r.GetString(2)), "application/json");
    }
});

app.MapDelete("/db/user/{id}", (string id) =>
{
    if (!long.TryParse(id, NumberStyles.Integer, CultureInfo.InvariantCulture, out var num))
        return Results.Text("not found", "text/plain", statusCode: 404);
    using var conn = OpenDb();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "DELETE FROM users WHERE id=$1;";
    cmd.Parameters.AddWithValue("$1", num);
    if (cmd.ExecuteNonQuery() == 0)
        return Results.Text("not found", "text/plain", statusCode: 404);
    return Results.Content("{\"deleted\":" + num.ToString(CultureInfo.InvariantCulture) + "}", "application/json");
});

app.MapGet("/db/search", (HttpRequest req) =>
{
    string q = req.Query["q"].ToString();
    if (string.IsNullOrEmpty(q))
        return Results.Text("invalid query", "text/plain", statusCode: 400);
    int limit = 20;
    string ls = req.Query["limit"].ToString();
    if (!string.IsNullOrEmpty(ls) && int.TryParse(ls, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n))
        limit = n;
    limit = Math.Clamp(limit, 1, 100);
    string pattern = "%" + q + "%";
    using var conn = OpenDb();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT id, username, email FROM users WHERE username LIKE $1 OR email LIKE $1 ORDER BY id LIMIT $2;";
    cmd.Parameters.AddWithValue("$1", pattern);
    cmd.Parameters.AddWithValue("$2", limit);
    using var r = cmd.ExecuteReader();
    var sb = new StringBuilder("[");
    bool first = true;
    while (r.Read())
    {
        if (!first) sb.Append(',');
        first = false;
        sb.Append(DbRowJson(r.GetInt64(0), r.GetString(1), r.GetString(2)));
    }
    sb.Append(']');
    return Results.Content(sb.ToString(), "application/json");
});

app.Run();

static SqliteConnection OpenDb()
{
    var conn = new SqliteConnection(DbConnStr);
    conn.Open();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-64000; PRAGMA temp_store=MEMORY;";
    cmd.ExecuteNonQuery();
    return conn;
}

static void SeedDb()
{
    using var conn = OpenDb();
    using (var cmd = conn.CreateCommand())
    {
        cmd.CommandText = "DROP TABLE IF EXISTS users; CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL, email TEXT NOT NULL);";
        cmd.ExecuteNonQuery();
    }
    using (var tx = conn.BeginTransaction())
    using (var cmd = conn.CreateCommand())
    {
        cmd.Transaction = (SqliteTransaction)tx;
        cmd.CommandText = "INSERT INTO users(username, email) VALUES($u, $e);";
        var pu = cmd.CreateParameter();
        pu.ParameterName = "$u";
        cmd.Parameters.Add(pu);
        var pe = cmd.CreateParameter();
        pe.ParameterName = "$e";
        cmd.Parameters.Add(pe);
        for (int i = 1; i <= 5000; i++)
        {
            pu.Value = "user_" + i.ToString(CultureInfo.InvariantCulture);
            pe.Value = "user_" + i.ToString(CultureInfo.InvariantCulture) + "@bench.local";
            cmd.ExecuteNonQuery();
        }
        tx.Commit();
    }
}

// Compact JSON, field order id,username,email — mirrors existing raw style.
static string DbRowJson(long id, string username, string email) =>
    "{\"id\":" + id.ToString(CultureInfo.InvariantCulture) +
    ",\"username\":\"" + username + "\",\"email\":\"" + email + "\"}";

static bool TryParseDbUser(string body, out string username, out string email)
{
    username = "";
    email = "";
    try
    {
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;
        if (!root.TryGetProperty("username", out var u) || u.ValueKind != JsonValueKind.String)
            return false;
        if (!root.TryGetProperty("email", out var e) || e.ValueKind != JsonValueKind.String)
            return false;
        username = u.GetString() ?? "";
        email = e.GetString() ?? "";
    }
    catch (JsonException)
    {
        return false;
    }
    return !string.IsNullOrEmpty(username) && !string.IsNullOrEmpty(email);
}

// Static ~1KB product document; only the id varies per request.
static string ProductJson(int id) =>
    "{\"id\":" + id.ToString(CultureInfo.InvariantCulture) +
    ",\"sku\":\"SKU-0042-WIDGET\",\"name\":\"Ergonomic Wireless Mouse\"," +
    "\"description\":\"A comfortable wireless mouse with adjustable DPI up to 3200, silent clicks and up to 18 months of battery life. Ideal for office work and travel.\"," +
    "\"price\":29.99,\"currency\":\"USD\",\"category\":\"electronics\"," +
    "\"tags\":[\"wireless\",\"mouse\",\"office\",\"ergonomic\",\"usb-c\"]," +
    "\"variants\":[{\"sku\":\"SKU-0042-BLK\",\"color\":\"black\",\"price\":29.99,\"stock\":134}," +
    "{\"sku\":\"SKU-0042-WHT\",\"color\":\"white\",\"price\":31.99,\"stock\":58}]," +
    "\"inventory\":{\"warehouse\":\"eu-central-1\",\"quantity\":192,\"reserved\":17,\"restock_eta\":\"2026-10-02\"}," +
    "\"rating\":4.6,\"reviews\":1284," +
    "\"dimensions\":{\"length_cm\":10.2,\"width_cm\":6.1,\"height_cm\":3.8,\"weight_g\":89}," +
    "\"shipping\":{\"free_over\":50.0,\"methods\":[\"standard\",\"express\",\"pickup\"],\"dispatch_hours\":24}," +
    "\"created_at\":\"2024-03-15T09:30:00Z\",\"updated_at\":\"2026-09-01T14:22:10Z\"}";
