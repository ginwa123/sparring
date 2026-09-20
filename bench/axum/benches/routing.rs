use criterion::{black_box, criterion_group, criterion_main, Criterion};

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

fn hello_body(name: &str) -> String {
    format!("Hello, {name}! (greeting: hello, mood: neutral)")
}

// Fixed 5-item cart matching the bench contract:
// subtotal = 183.62, discount = 18.362, total = 165.26, items = 9.
fn fixed_cart() -> Vec<(i64, f64)> {
    vec![(2, 29.99), (1, 31.99), (3, 9.99), (2, 19.99), (1, 21.70)]
}

fn checkout_totals(items: &[(i64, f64)], coupon: &str) -> (f64, f64, f64, i64) {
    let mut subtotal = 0.0f64;
    let mut count = 0i64;
    for (qty, price) in items {
        subtotal += *qty as f64 * *price;
        count += *qty;
    }
    let discount = if coupon == "SAVE10" {
        subtotal * 0.10
    } else {
        0.0
    };
    (subtotal, discount, subtotal - discount, count)
}

fn bench_product_json(c: &mut Criterion) {
    c.bench_function("product_json", |b| {
        b.iter(|| product_json(black_box(42)))
    });
}

fn bench_checkout_total(c: &mut Criterion) {
    let cart = fixed_cart();
    c.bench_function("checkout_total", |b| {
        b.iter(|| checkout_totals(black_box(&cart), black_box("SAVE10")))
    });
}

fn bench_hello_format(c: &mut Criterion) {
    c.bench_function("hello_format", |b| {
        b.iter(|| hello_body(black_box("World")))
    });
}

criterion_group!(benches, bench_product_json, bench_checkout_total, bench_hello_format);
criterion_main!(benches);
