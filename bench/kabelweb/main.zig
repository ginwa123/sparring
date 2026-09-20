// bench/kabelweb/main.zig — sparringhttp kabelweb bench server.
//
// Endpoints are identical to the Fiber bench server (bench/fiber/main.go) so
// both frameworks are measured on the same workload. Listens on 0.0.0.0:29590
// inside the container namespace (the sandbox publishes 127.0.0.1:<port> ->
// 8080 on the host side, keeping exposure loopback-only). When run directly on
// the host (smoke tests), the same bind on all interfaces is equivalent to
// loopback for testing purposes — the harness never exposes ports beyond
// 127.0.0.1. Minimal: no SSE/WS/template/landing page (those would inflate RSS
// and skew comparison).
const std = @import("std");
const kw = @import("kabelweb");
const gserverz = kw.server;

fn healthHandler(_: gserverz.HttpContext, _: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return res.withBody("OK");
}

fn helloHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const name = req.params.get("name") orelse "HTTP";
    const text = std.fmt.allocPrint(ctx.allocator, "Hello, {s}! (greeting: hello, mood: neutral)", .{name}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.withBody(text);
}

const User = struct {
    username: []const u8 = "",
    email: []const u8 = "",
};

fn usersHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const user = std.json.parseFromSliceLeaky(User, ctx.allocator, req.body, .{}) catch {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    };
    const json_text = std.fmt.allocPrint(ctx.allocator, "{{\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ user.username, user.email }) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 201, .data = json_text });
}

fn echoHandler(_: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    if (req.body.len > 32 * 1024) {
        var too_big = res;
        too_big.status_code = 413;
        too_big.body = "body too large";
        return too_big;
    }
    return res.withBody(req.body);
}

// Realistic-payload contract (shared by all four bench servers,
// byte-identical bodies): ~1KB product document + cart checkout.
// Fixed cart subtotal = 183.62, discount = 18.362, total = 165.26, items = 9.
fn productHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const id_text = req.params.get("id") orelse "0";
    const id = std.fmt.parseInt(i64, id_text, 10) catch 0;
    const json_text = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d},\"sku\":\"SKU-0042-WIDGET\",\"name\":\"Ergonomic Wireless Mouse\",\"description\":\"A comfortable wireless mouse with adjustable DPI up to 3200, silent clicks and up to 18 months of battery life. Ideal for office work and travel.\",\"price\":29.99,\"currency\":\"USD\",\"category\":\"electronics\",\"tags\":[\"wireless\",\"mouse\",\"office\",\"ergonomic\",\"usb-c\"],\"variants\":[{{\"sku\":\"SKU-0042-BLK\",\"color\":\"black\",\"price\":29.99,\"stock\":134}},{{\"sku\":\"SKU-0042-WHT\",\"color\":\"white\",\"price\":31.99,\"stock\":58}}],\"inventory\":{{\"warehouse\":\"eu-central-1\",\"quantity\":192,\"reserved\":17,\"restock_eta\":\"2026-10-02\"}},\"rating\":4.6,\"reviews\":1284,\"dimensions\":{{\"length_cm\":10.2,\"width_cm\":6.1,\"height_cm\":3.8,\"weight_g\":89}},\"shipping\":{{\"free_over\":50.0,\"methods\":[\"standard\",\"express\",\"pickup\"],\"dispatch_hours\":24}},\"created_at\":\"2024-03-15T09:30:00Z\",\"updated_at\":\"2026-09-01T14:22:10Z\"}}", .{id}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 200, .data = json_text });
}

const CheckoutItem = struct {
    qty: i64 = 0,
    price: f64 = 0,
};

const Checkout = struct {
    user_id: []const u8 = "",
    items: []CheckoutItem = &.{},
    coupon: []const u8 = "",
};

fn checkoutHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    if (req.body.len > 32 * 1024) {
        var too_big = res;
        too_big.status_code = 413;
        too_big.body = "body too large";
        return too_big;
    }
    const cart = std.json.parseFromSliceLeaky(Checkout, ctx.allocator, req.body, .{ .ignore_unknown_fields = true }) catch {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    };
    if (cart.items.len == 0 or cart.user_id.len == 0) {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    }
    var subtotal: f64 = 0;
    var count: i64 = 0;
    for (cart.items) |it| {
        subtotal += @as(f64, @floatFromInt(it.qty)) * it.price;
        count += it.qty;
    }
    if (count == 0) {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    }
    const discount: f64 = if (std.mem.eql(u8, cart.coupon, "SAVE10")) subtotal * 0.10 else 0;
    const total: f64 = subtotal - discount;
    const json_text = std.fmt.allocPrint(ctx.allocator, "{{\"order_id\":\"ord-{s}\",\"status\":\"confirmed\",\"items\":{d},\"total\":{d:.2},\"currency\":\"USD\",\"eta\":\"2026-09-25\"}}", .{ cart.user_id, count, total }) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 200, .data = json_text });
}

const ws_frames = gserverz.ws_frames;

fn wsEchoHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    server_ptr: *anyopaque,
    client_fd: i32,
    client_id: *[16]u8,
) !void {
    const server: *gserverz.GinwaServer = @ptrCast(@alignCast(server_ptr));
    _ = req;
    _ = client_id;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = server.recvFromClient(client_fd, &buf) catch return;
        if (n == 0) return; // peer closed
        var frame = ws_frames.parseFrame(ctx.allocator, buf[0..n]) catch |err| switch (err) {
            error.IncompleteFrame => continue,
            else => return,
        };
        defer frame.deinit(ctx.allocator);
        switch (frame.opcode) {
            .text => {
                const echo = ws_frames.encodeFrame(ctx.allocator, .{ .opcode = .text, .payload = frame.payload }) catch continue;
                defer ctx.allocator.free(echo);
                _ = server.sendToClient(client_fd, echo) catch return;
            },
            .ping => {
                const pong = ws_frames.encodeFrame(ctx.allocator, .{ .opcode = .pong, .payload = frame.payload }) catch continue;
                defer ctx.allocator.free(pong);
                _ = server.sendToClient(client_fd, pong) catch return;
            },
            .close => return,
            else => {},
        }
    }
}

// Finite 5-event SSE-shaped stream served as a plain GET handler.
// The framework `sse` route shape is built for long-lived streams
// (client registered with SseManager, handler returns WouldBlock and the
// connection stays open with heartbeats) — wrong fit for a bounded
// 5-event body, so we return the full event stream with SSE headers.
fn eventsHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);
    for (1..6) |i| {
        const chunk = std.fmt.allocPrint(ctx.allocator, "id: {d}\nevent: tick\ndata: {{\"seq\":{d}}}\n\n", .{ i, i }) catch {
            return gserverz.response.internalError("alloc failed", ctx.allocator);
        };
        defer ctx.allocator.free(chunk);
        out.appendSlice(ctx.allocator, chunk) catch {
            return gserverz.response.internalError("alloc failed", ctx.allocator);
        };
    }
    const body = ctx.allocator.dupe(u8, out.items) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.withBody(body)
        .setContentType("text/event-stream")
        .withHeader("Cache-Control", "no-cache");
}

fn escapeHtml(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (s) |c| {
        const ent: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (ent) |e| {
            try out.appendSlice(allocator, e);
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

const PAGE_HTML_TEMPLATE =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8" /><title>Hello</title></head>
    \\<body><h1>Hello, {s}!</h1></body></html>
;

fn pageHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const raw_q = req.query.get("name") orelse "HTTP";
    const raw = if (raw_q.len == 0) "HTTP" else raw_q;
    const escaped = escapeHtml(ctx.allocator, raw) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(escaped);
    const body = std.fmt.allocPrint(ctx.allocator, PAGE_HTML_TEMPLATE, .{escaped}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.withBody(body).setContentType("text/html; charset=utf-8");
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Server error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Port fixed at 29590 (container CMD remaps via publish). Listening on
    // 0.0.0.0 keeps the wire protocol identical whether run in-container
    // (published to 127.0.0.1) or directly on the host for smoke tests.
    const address = try gserverz.Address.init("0.0.0.0", 29590);
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();

    try gs.router.get("/health", healthHandler);
    try gs.router.get("/hello/:name", helloHandler);
    try gs.router.post("/users", usersHandler);
    try gs.router.post("/api/v1/echo", echoHandler);
    try gs.router.get("/api/v1/product/:id", productHandler);
    try gs.router.post("/api/v1/checkout", checkoutHandler);
    try gs.router.ws("/ws", wsEchoHandler);
    try gs.router.get("/events", eventsHandler);
    try gs.router.get("/page", pageHandler);

    std.debug.print("kabelweb bench server listening on 0.0.0.0:29590\n", .{});
    try gs.listenEventLoop(.{.loop_count = 4});
}
