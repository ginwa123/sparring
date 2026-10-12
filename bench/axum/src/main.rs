// bench/axum/src/main.rs — sparringhttp Axum bench server.
//
// Endpoints are identical to the kabelweb / Fiber / ASP.NET Core bench servers
// so all frameworks are measured on the same workload. Listens on
// 0.0.0.0:29590 inside the container namespace (the sandbox publishes
// 127.0.0.1:<port> -> 29590 on the host side, keeping exposure loopback-only).
//
// Fairness: the Tokio worker pool is pinned to 2 threads to match the sandbox
// quota (--cpus=2), mirroring GOMAXPROCS=2 for the Fiber server. Without this,
// Tokio would size the pool from the host CPU count visible inside the
// container (cgroup quota is not pinning).
//
// Realistic-payload contract (shared by all four servers, byte-identical):
//   GET  /api/v1/product/:id -> ~1KB static product JSON with :id substituted
//   POST /api/v1/checkout     -> parses a ~0.6KB cart JSON, 10% off for
//                                coupon SAVE10, returns order confirmation.
//   Fixed cart subtotal = 183.62, discount = 18.362, total = 165.26, items = 9.
use axum::{
    body::Bytes,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Router,
};
use r2d2_sqlite::SqliteConnectionManager;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

const MAX_BODY: usize = 32 * 1024;

fn text(status: StatusCode, body: impl Into<String>) -> Response {
    (
        status,
        [(header::CONTENT_TYPE, "text/plain")],
        body.into(),
    )
        .into_response()
}

fn json(status: StatusCode, body: impl Into<String>) -> Response {
    (
        status,
        [(header::CONTENT_TYPE, "application/json")],
        body.into(),
    )
        .into_response()
}

async fn health() -> Response {
    text(StatusCode::OK, "OK")
}

fn hello_body(name: &str) -> String {
    format!("Hello, {name}! (greeting: hello, mood: neutral)")
}

async fn hello(axum::extract::Path(name): axum::extract::Path<String>) -> Response {
    text(StatusCode::OK, hello_body(&name))
}

async fn echo(body: Bytes) -> Response {
    if body.len() > MAX_BODY {
        return text(StatusCode::PAYLOAD_TOO_LARGE, "body too large");
    }
    // Echo raw bytes; assume UTF-8 like the other bench servers' test bodies.
    text(
        StatusCode::OK,
        String::from_utf8_lossy(&body).into_owned(),
    )
}

#[derive(Deserialize)]
struct User {
    #[serde(default)]
    username: String,
    #[serde(default)]
    email: String,
}

async fn users(body: Bytes) -> Response {
    let user: User = match serde_json::from_slice(&body) {
        Ok(u) => u,
        Err(_) => return text(StatusCode::BAD_REQUEST, "invalid JSON"),
    };
    // Manual compact JSON, same shape as the other bench servers.
    json(
        StatusCode::CREATED,
        format!(
            "{{\"username\":\"{}\",\"email\":\"{}\"}}",
            user.username, user.email
        ),
    )
}

fn product_json(id: i64) -> String {
    format!(
        "{{\"id\":{id},\"sku\":\"SKU-0042-WIDGET\",\"name\":\"Ergonomic Wireless Mouse\",\
        \"description\":\"A comfortable wireless mouse with adjustable DPI up to 3200, silent clicks and up to 18 months of battery life. Ideal for office work and travel.\",\
        \"price\":29.99,\"currency\":\"USD\",\"category\":\"electronics\",\
        \"tags\":[\"wireless\",\"mouse\",\"office\",\"ergonomic\",\"usb-c\"],\
        \"variants\":[{{\"sku\":\"SKU-0042-BLK\",\"color\":\"black\",\"price\":29.99,\"stock\":134}},\
        {{\"sku\":\"SKU-0042-WHT\",\"color\":\"white\",\"price\":31.99,\"stock\":58}}],\
        \"inventory\":{{\"warehouse\":\"eu-central-1\",\"quantity\":192,\"reserved\":17,\"restock_eta\":\"2026-10-02\"}},\
        \"rating\":4.6,\"reviews\":1284,\
        \"dimensions\":{{\"length_cm\":10.2,\"width_cm\":6.1,\"height_cm\":3.8,\"weight_g\":89}},\
        \"shipping\":{{\"free_over\":50.0,\"methods\":[\"standard\",\"express\",\"pickup\"],\"dispatch_hours\":24}},\
        \"created_at\":\"2024-03-15T09:30:00Z\",\"updated_at\":\"2026-09-01T14:22:10Z\"}}"
    )
}

async fn product(axum::extract::Path(id): axum::extract::Path<String>) -> Response {
    let num: i64 = id.parse().unwrap_or(0);
    json(StatusCode::OK, product_json(num))
}

#[derive(Deserialize)]
struct Item {
    qty: i64,
    price: f64,
}

#[derive(Deserialize)]
struct Checkout {
    user_id: String,
    items: Vec<Item>,
    #[serde(default)]
    coupon: String,
}

fn checkout_totals(items: &[Item], coupon: &str) -> (f64, f64, f64, i64) {
    let mut subtotal = 0.0f64;
    let mut count = 0i64;
    for it in items {
        subtotal += it.qty as f64 * it.price;
        count += it.qty;
    }
    let discount = if coupon == "SAVE10" {
        subtotal * 0.10
    } else {
        0.0
    };
    let total = subtotal - discount;
    (subtotal, discount, total, count)
}

async fn checkout(body: Bytes) -> Response {
    if body.len() > MAX_BODY {
        return text(StatusCode::PAYLOAD_TOO_LARGE, "body too large");
    }
    let cart: Checkout = match serde_json::from_slice(&body) {
        Ok(c) => c,
        Err(_) => return text(StatusCode::BAD_REQUEST, "invalid JSON"),
    };
    if cart.items.is_empty() {
        return text(StatusCode::BAD_REQUEST, "invalid JSON");
    }
    let (_subtotal, _discount, total, count) =
        checkout_totals(&cart.items, &cart.coupon);
    if count == 0 {
        return text(StatusCode::BAD_REQUEST, "invalid JSON");
    }
    json(
        StatusCode::OK,
        format!(
            "{{\"order_id\":\"ord-{}\",\"status\":\"confirmed\",\"items\":{count},\"total\":{total:.2},\"currency\":\"USD\",\"eta\":\"2026-09-25\"}}",
            cart.user_id,
        ),
    )
}

async fn ws_handler(ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(handle_ws).into_response()
}

async fn handle_ws(mut socket: WebSocket) {
    loop {
        match socket.recv().await {
            Some(Ok(Message::Text(t))) => {
                if socket.send(Message::Text(t)).await.is_err() {
                    break;
                }
            }
            Some(Ok(Message::Binary(b))) => {
                if socket.send(Message::Binary(b)).await.is_err() {
                    break;
                }
            }
            Some(Ok(Message::Ping(p))) => {
                if socket.send(Message::Pong(p)).await.is_err() {
                    break;
                }
            }
            Some(Ok(Message::Close(_))) | None => break,
            _ => {}
        }
    }
}

async fn events() -> Response {
    let mut body = String::new();
    for i in 1..=5 {
        body.push_str(&format!("id: {i}\nevent: tick\ndata: {{\"seq\":{i}}}\n\n"));
    }
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "text/event-stream"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        body,
    )
        .into_response()
}

fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#x27;"),
            _ => out.push(c),
        }
    }
    out
}

async fn page(Query(params): Query<HashMap<String, String>>) -> Response {
    let name = params.get("name").map(|s| s.as_str()).filter(|s| !s.is_empty()).unwrap_or("HTTP");
    let escaped = html_escape(name);
    let body = format!(
        "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>Hello</title></head>\
<body><h1>Hello, {escaped}!</h1></body></html>"
    );
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        body,
    )
        .into_response()
}

// ---------------------------------------------------------------------------
// SQLite scenario (shared contract, byte-identical across all four servers).
//
// rusqlite connections are !Sync, so each request checks out one pooled
// connection and queries inline, blocking the Tokio worker briefly. At
// worker_threads=2 with a pool of 8 this is fine for the bench workload and
// keeps the code simple (no spawn_blocking hops). Pool via r2d2 +
// r2d2-sqlite; rusqlite "bundled" builds its own SQLite so the bench image
// needs no system sqlite package.
// ---------------------------------------------------------------------------

const DB_PATH: &str = "/tmp/sparring_sqlite.db";
const DB_POOL_SIZE: u32 = 8;

type DbPool = r2d2::Pool<SqliteConnectionManager>;
type SharedPool = Arc<DbPool>;

/// Tuning PRAGMAs from the shared contract. Applied to every new pooled
/// connection via the manager's init hook, and to the seed connection.
fn apply_pragmas(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.busy_timeout(Duration::from_millis(5000))?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "cache_size", -64000)?;
    conn.pragma_update(None, "temp_store", "MEMORY")?;
    Ok(())
}

fn build_pool() -> SharedPool {
    let manager = SqliteConnectionManager::file(DB_PATH).with_init(|c| {
        apply_pragmas(c).map_err(rusqlite::Error::into)
    });
    Arc::new(
        r2d2::Pool::builder()
            .max_size(DB_POOL_SIZE)
            .build(manager)
            .expect("build sqlite pool"),
    )
}

/// Seed: DROP + CREATE + one transaction inserting 5000 rows
/// (user_{i} / user_{i}@bench.local for i=1..5000). Runs once at startup.
fn seed_db(pool: &SharedPool) {
    let mut conn = pool.get().expect("sqlite connection for seed");
    conn.execute_batch("DROP TABLE IF EXISTS users;")
        .expect("drop users");
    conn.execute_batch(
        "CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL, email TEXT NOT NULL);",
    )
    .expect("create users");
    let tx = conn.transaction().expect("begin seed tx");
    {
        let mut stmt = tx
            .prepare("INSERT INTO users(username, email) VALUES(?, ?)")
            .expect("prepare seed insert");
        for i in 1..=5000 {
            let username = format!("user_{i}");
            let email = format!("user_{i}@bench.local");
            stmt.execute(rusqlite::params![username, email])
                .expect("seed row");
        }
    }
    tx.commit().expect("commit seed tx");
}

/// Row shape; serde field order (id, username, email) is the wire order.
#[derive(Serialize)]
struct DbUser {
    id: i64,
    username: String,
    email: String,
}

fn db_row_to_user(row: &rusqlite::Row) -> rusqlite::Result<DbUser> {
    Ok(DbUser {
        id: row.get(0)?,
        username: row.get(1)?,
        email: row.get(2)?,
    })
}

fn db_500() -> Response {
    text(StatusCode::INTERNAL_SERVER_ERROR, "internal error")
}

async fn db_health(State(pool): State<SharedPool>) -> Response {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(_) => return db_500(),
    };
    match conn.query_row("SELECT 1", [], |_| Ok(())) {
        Ok(()) => json(StatusCode::OK, "{\"ok\":true}"),
        Err(_) => db_500(),
    }
}

async fn db_get_user(State(pool): State<SharedPool>, Path(id): Path<String>) -> Response {
    let id: i64 = match id.parse() {
        Ok(n) => n,
        Err(_) => return text(StatusCode::NOT_FOUND, "not found"),
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(_) => return db_500(),
    };
    match conn.query_row(
        "SELECT id, username, email FROM users WHERE id = ?",
        rusqlite::params![id],
        db_row_to_user,
    ) {
        Ok(u) => match serde_json::to_string(&u) {
            Ok(s) => json(StatusCode::OK, s),
            Err(_) => db_500(),
        },
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            text(StatusCode::NOT_FOUND, "not found")
        }
        Err(_) => db_500(),
    }
}

async fn db_list_users(
    State(pool): State<SharedPool>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let limit: i64 = params
        .get("limit")
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(20)
        .clamp(1, 100);
    let conn = match pool.get() {
        Ok(c) => c,
        Err(_) => return db_500(),
    };
    let rows = (|| -> rusqlite::Result<Vec<DbUser>> {
        let mut stmt =
            conn.prepare("SELECT id, username, email FROM users ORDER BY id LIMIT ?")?;
        let users = stmt
            .query_map(rusqlite::params![limit], db_row_to_user)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(users)
    })();
    match rows {
        Ok(users) => match serde_json::to_string(&users) {
            Ok(s) => json(StatusCode::OK, s),
            Err(_) => db_500(),
        },
        Err(_) => db_500(),
    }
}

fn parse_new_user(body: &Bytes) -> Option<(String, String)> {
    if body.len() > MAX_BODY {
        return None;
    }
    let u: User = serde_json::from_slice(body).ok()?;
    if u.username.is_empty() || u.email.is_empty() {
        return None;
    }
    Some((u.username, u.email))
}

async fn db_create_user(State(pool): State<SharedPool>, body: Bytes) -> Response {
    let (username, email) = match parse_new_user(&body) {
        Some(v) => v,
        None => return text(StatusCode::BAD_REQUEST, "invalid JSON"),
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(_) => return db_500(),
    };
    match conn.execute(
        "INSERT INTO users(username, email) VALUES(?, ?)",
        rusqlite::params![username, email],
    ) {
        Ok(_) => {
            let id = conn.last_insert_rowid();
            match serde_json::to_string(&DbUser {
                id,
                username,
                email,
            }) {
                Ok(s) => json(StatusCode::CREATED, s),
                Err(_) => db_500(),
            }
        }
        Err(_) => db_500(),
    }
}

async fn db_update_user(
    State(pool): State<SharedPool>,
    Path(id): Path<String>,
    body: Bytes,
) -> Response {
    if body.len() > MAX_BODY {
        return text(StatusCode::BAD_REQUEST, "invalid JSON");
    }
    let id: i64 = match id.parse() {
        Ok(n) => n,
        Err(_) => return text(StatusCode::NOT_FOUND, "not found"),
    };
    let u: User = match serde_json::from_slice(&body) {
        Ok(u) => u,
        Err(_) => return text(StatusCode::BAD_REQUEST, "invalid JSON"),
    };
    if u.username.is_empty() || u.email.is_empty() {
        return text(StatusCode::BAD_REQUEST, "invalid JSON");
    }
    let conn = match pool.get() {
        Ok(c) => c,
        Err(_) => return db_500(),
    };
    let updated = match conn.execute(
        "UPDATE users SET username = ?, email = ? WHERE id = ?",
        rusqlite::params![u.username, u.email, id],
    ) {
        Ok(n) => n,
        Err(_) => return db_500(),
    };
    if updated == 0 {
        return text(StatusCode::NOT_FOUND, "not found");
    }
    match conn.query_row(
        "SELECT id, username, email FROM users WHERE id = ?",
        rusqlite::params![id],
        db_row_to_user,
    ) {
        Ok(user) => match serde_json::to_string(&user) {
            Ok(s) => json(StatusCode::OK, s),
            Err(_) => db_500(),
        },
        Err(_) => db_500(),
    }
}

async fn db_delete_user(
    State(pool): State<SharedPool>,
    Path(id): Path<String>,
) -> Response {
    let id: i64 = match id.parse() {
        Ok(n) => n,
        Err(_) => return text(StatusCode::NOT_FOUND, "not found"),
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(_) => return db_500(),
    };
    match conn.execute(
        "DELETE FROM users WHERE id = ?",
        rusqlite::params![id],
    ) {
        Ok(n) => {
            if n == 0 {
                return text(StatusCode::NOT_FOUND, "not found");
            }
            json(StatusCode::OK, format!("{{\"deleted\":{id}}}"))
        }
        Err(_) => db_500(),
    }
}

async fn db_search_users(
    State(pool): State<SharedPool>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let q = params.get("q").map(|s| s.as_str()).unwrap_or("");
    if q.is_empty() {
        return text(StatusCode::BAD_REQUEST, "invalid query");
    }
    let limit: i64 = params
        .get("limit")
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(20)
        .clamp(1, 100);
    let pattern = format!("%{q}%");
    let conn = match pool.get() {
        Ok(c) => c,
        Err(_) => return db_500(),
    };
    let rows = (|| -> rusqlite::Result<Vec<DbUser>> {
        let mut stmt = conn.prepare(
            "SELECT id, username, email FROM users WHERE username LIKE ? OR email LIKE ? ORDER BY id LIMIT ?",
        )?;
        let users = stmt
            .query_map(rusqlite::params![pattern, pattern, limit], db_row_to_user)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(users)
    })();
    match rows {
        Ok(users) => match serde_json::to_string(&users) {
            Ok(s) => json(StatusCode::OK, s),
            Err(_) => db_500(),
        },
        Err(_) => db_500(),
    }
}

fn app(pool: SharedPool) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/hello/{name}", get(hello))
        .route("/users", post(users))
        .route("/api/v1/echo", post(echo))
        .route("/api/v1/product/{id}", get(product))
        .route("/api/v1/checkout", post(checkout))
        .route("/ws", get(ws_handler))
        .route("/events", get(events))
        .route("/page", get(page))
        .route("/db/health", get(db_health))
        .route("/db/user/{id}", get(db_get_user).put(db_update_user).delete(db_delete_user))
        .route("/db/users", get(db_list_users))
        .route("/db/search", get(db_search_users))
        .route("/db/user", post(db_create_user))
        .with_state(pool)
}

fn main() {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("build tokio runtime")
        .block_on(async {
            let pool = build_pool();
            seed_db(&pool);
            let listener = tokio::net::TcpListener::bind("0.0.0.0:29590")
                .await
                .expect("bind 0.0.0.0:29590");
            println!("axum bench server listening on 0.0.0.0:29590");
            axum::serve(listener, app(pool)).await.expect("serve");
        });
}
