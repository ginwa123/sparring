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
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Router,
};
use serde::Deserialize;

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

async fn hello(axum::extract::Path(name): axum::extract::Path<String>) -> Response {
    text(
        StatusCode::OK,
        format!("Hello, {name}! (greeting: hello, mood: neutral)"),
    )
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
    let mut subtotal = 0.0f64;
    let mut count = 0i64;
    for it in &cart.items {
        subtotal += it.qty as f64 * it.price;
        count += it.qty;
    }
    if count == 0 {
        return text(StatusCode::BAD_REQUEST, "invalid JSON");
    }
    let discount = if cart.coupon == "SAVE10" {
        subtotal * 0.10
    } else {
        0.0
    };
    let total = subtotal - discount;
    json(
        StatusCode::OK,
        format!(
            "{{\"order_id\":\"ord-{}\",\"status\":\"confirmed\",\"items\":{count},\"total\":{total:.2},\"currency\":\"USD\",\"eta\":\"2026-09-25\"}}",
            cart.user_id,
        ),
    )
}

fn app() -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/hello/{name}", get(hello))
        .route("/users", post(users))
        .route("/api/v1/echo", post(echo))
        .route("/api/v1/product/{id}", get(product))
        .route("/api/v1/checkout", post(checkout))
}

fn main() {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("build tokio runtime")
        .block_on(async {
            let listener = tokio::net::TcpListener::bind("0.0.0.0:29590")
                .await
                .expect("bind 0.0.0.0:29590");
            println!("axum bench server listening on 0.0.0.0:29590");
            axum::serve(listener, app()).await.expect("serve");
        });
}
