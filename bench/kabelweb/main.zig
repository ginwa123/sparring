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
const databases = @import("databases");
const database = databases.database;

var gdb: database.Db = .{};

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

fn pageHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {    const raw_q = req.query.get("name") orelse "HTTP";
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

// ─── SQLite bench endpoints (shared contract, additive only) ───

fn dbNotFound(res: gserverz.HttpResponse) gserverz.HttpResponse {
    var r = res;
    r.status_code = 404;
    r.body = "not found";
    return r;
}

fn dbHealthHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    var row = gdb.queryRow(ctx.allocator, "SELECT 1", &.{}) catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    };
    row.deinit(ctx.allocator);
    return res.jsonResponse(.{ .status_code = 200, .data = "{\"ok\":true}" });
}

fn dbGetUserHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const id_text = req.params.get("id") orelse "0";
    const id_val = std.fmt.parseInt(i64, id_text, 10) catch {
        return dbNotFound(res);
    };
    if (id_val == 0) return dbNotFound(res);
    const id_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{id_val}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(id_str);
    var row = gdb.queryRow(ctx.allocator, "SELECT id,username,email FROM users WHERE id=?", &.{id_str}) catch |err| switch (err) {
        error.RowNotFound => return dbNotFound(res),
        else => return gserverz.response.internalError("db error", ctx.allocator),
    };
    defer row.deinit(ctx.allocator);
    // `row.values` are valid until `row.deinit`, so format straight out of
    // them — copying each column into the arena first only added work.
    const json_text = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s},\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ row.values[0], row.values[1], row.values[2] }) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 200, .data = json_text });
}

fn dbListUsersHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    var limit: i64 = 20;
    if (req.query.get("limit")) |ls| {
        limit = std.fmt.parseInt(i64, ls, 10) catch 20;
    }
    if (limit < 1) limit = 1;
    if (limit > 100) limit = 100;
    const lim_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{limit}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(lim_str);
    var rows = gdb.query(ctx.allocator, "SELECT id,username,email FROM users ORDER BY id LIMIT ?", &.{lim_str}) catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    };
    defer rows.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);
    out.append(ctx.allocator, '[') catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    // Each row is appended with plain slice writes. No `allocPrint` and no
    // intermediate item: formatting a 20-row list through `{s}` and copying
    // the result cost more than the row read itself, and every one of those
    // allocations had to be freed again.
    // One stack buffer per row, appended in a single call. Formatting
    // straight into `out` meant ~7 capacity-checked appends per row; a row
    // that fits `ROW_BUF` (the normal case — the seeds are ~75 bytes) now
    // costs one append. Anything longer falls back to the same slice
    // appends, so long usernames still work.
    var first = true;
    while (rows.next() catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    }) |row| {
        defer row.deinit(ctx.allocator);
        var row_buf: [256]u8 = undefined;
        const row_json = std.fmt.bufPrint(&row_buf, "{{\"id\":{s},\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ row.values[0], row.values[1], row.values[2] }) catch null;
        if (!first) out.append(ctx.allocator, ',') catch {
            return gserverz.response.internalError("alloc failed", ctx.allocator);
        };
        first = false;
        if (row_json) |item| {
            out.appendSlice(ctx.allocator, item) catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
        } else {
            _ = out.appendSlice(ctx.allocator, "{\"id\":") catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
            _ = out.appendSlice(ctx.allocator, row.values[0]) catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
            _ = out.appendSlice(ctx.allocator, ",\"username\":\"") catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
            _ = out.appendSlice(ctx.allocator, row.values[1]) catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
            _ = out.appendSlice(ctx.allocator, "\",\"email\":\"") catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
            _ = out.appendSlice(ctx.allocator, row.values[2]) catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
            _ = out.appendSlice(ctx.allocator, "\"}") catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
        }
    }
    out.append(ctx.allocator, ']') catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    const json_text = ctx.allocator.dupe(u8, out.items) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 200, .data = json_text });
}

const DbUserBody = struct {
    username: []const u8 = "",
    email: []const u8 = "",
};

fn dbCreateUserHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    if (req.body.len > 32 * 1024) {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    }
    const input = std.json.parseFromSliceLeaky(DbUserBody, ctx.allocator, req.body, .{}) catch {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    };
    if (input.username.len == 0 or input.email.len == 0) {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    }
    gdb.exec(ctx.allocator, "INSERT INTO users(username,email) VALUES(?,?)", &.{ input.username, input.email }) catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    };
    var idrow = gdb.queryRow(ctx.allocator, "SELECT last_insert_rowid()", &.{}) catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    };
    defer idrow.deinit(ctx.allocator);
    const new_id = ctx.allocator.dupe(u8, idrow.values[0]) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(new_id);
    const json_text = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s},\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ new_id, input.username, input.email }) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 201, .data = json_text });
}

fn dbUpdateUserHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const id_text = req.params.get("id") orelse "0";
    const id_val = std.fmt.parseInt(i64, id_text, 10) catch {
        return dbNotFound(res);
    };
    if (id_val == 0) return dbNotFound(res);
    if (req.body.len > 32 * 1024) {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    }
    const input = std.json.parseFromSliceLeaky(DbUserBody, ctx.allocator, req.body, .{}) catch {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    };
    if (input.username.len == 0 or input.email.len == 0) {
        return gserverz.response.badRequest("invalid JSON", ctx.allocator);
    }
    const id_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{id_val}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(id_str);
    gdb.exec(ctx.allocator, "UPDATE users SET username=?,email=? WHERE id=?", &.{ input.username, input.email, id_str }) catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    };
    if (gdb.changes() == 0) return dbNotFound(res);
    var row = gdb.queryRow(ctx.allocator, "SELECT id,username,email FROM users WHERE id=?", &.{id_str}) catch |err| switch (err) {
        error.RowNotFound => return dbNotFound(res),
        else => return gserverz.response.internalError("db error", ctx.allocator),
    };
    defer row.deinit(ctx.allocator);
    const id_out = ctx.allocator.dupe(u8, row.values[0]) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(id_out);
    const username = ctx.allocator.dupe(u8, row.values[1]) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(username);
    const email = ctx.allocator.dupe(u8, row.values[2]) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(email);
    const json_text = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s},\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ id_out, username, email }) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 200, .data = json_text });
}

fn dbDeleteUserHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const id_text = req.params.get("id") orelse "0";
    const id_val = std.fmt.parseInt(i64, id_text, 10) catch {
        return dbNotFound(res);
    };
    if (id_val <= 0) return dbNotFound(res);
    const id_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{id_val}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(id_str);
    gdb.exec(ctx.allocator, "DELETE FROM users WHERE id=?", &.{id_str}) catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    };
    if (gdb.changes() == 0) return dbNotFound(res);
    const json_text = std.fmt.allocPrint(ctx.allocator, "{{\"deleted\":{d}}}", .{id_val}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 200, .data = json_text });
}

fn dbSearchUsersHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const raw_q = req.query.get("q") orelse "";
    const q = std.mem.trim(u8, raw_q, " \t\r\n");
    if (q.len == 0) {
        return gserverz.response.badRequest("invalid query", ctx.allocator);
    }
    var limit: i64 = 20;
    if (req.query.get("limit")) |ls| {
        limit = std.fmt.parseInt(i64, ls, 10) catch 20;
    }
    if (limit < 1) limit = 1;
    if (limit > 100) limit = 100;
    const like = std.fmt.allocPrint(ctx.allocator, "%{s}%", .{q}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(like);
    const lim_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{limit}) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    defer ctx.allocator.free(lim_str);
    var rows = gdb.query(ctx.allocator, "SELECT id,username,email FROM users WHERE username LIKE ? OR email LIKE ? ORDER BY id LIMIT ?", &.{ like, like, lim_str }) catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    };
    defer rows.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);
    out.append(ctx.allocator, '[') catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    var first = true;
    while (rows.next() catch {
        return gserverz.response.internalError("db error", ctx.allocator);
    }) |row| {
        defer row.deinit(ctx.allocator);
        const id_out = ctx.allocator.dupe(u8, row.values[0]) catch {
            return gserverz.response.internalError("alloc failed", ctx.allocator);
        };
        defer ctx.allocator.free(id_out);
        const username = ctx.allocator.dupe(u8, row.values[1]) catch {
            return gserverz.response.internalError("alloc failed", ctx.allocator);
        };
        defer ctx.allocator.free(username);
        const email = ctx.allocator.dupe(u8, row.values[2]) catch {
            return gserverz.response.internalError("alloc failed", ctx.allocator);
        };
        defer ctx.allocator.free(email);
        if (!first) {
            out.append(ctx.allocator, ',') catch {
                return gserverz.response.internalError("alloc failed", ctx.allocator);
            };
        }
        first = false;
        const item = std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s},\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ id_out, username, email }) catch {
            return gserverz.response.internalError("alloc failed", ctx.allocator);
        };
        defer ctx.allocator.free(item);
        out.appendSlice(ctx.allocator, item) catch {
            return gserverz.response.internalError("alloc failed", ctx.allocator);
        };
    }
    out.append(ctx.allocator, ']') catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    const json_text = ctx.allocator.dupe(u8, out.items) catch {
        return gserverz.response.internalError("alloc failed", ctx.allocator);
    };
    return res.jsonResponse(.{ .status_code = 200, .data = json_text });
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Server error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

/// Connection policy for the bench server.
///
/// Stated here rather than left to the package default because `cache_size`
/// must be the SAME on the write connection and on every pooled reader,
/// otherwise the benchmark measures two different configurations.
/// `seedDb` used to set `-64000` with a bare `PRAGMA` AFTER opening, which
/// only ever touched the primary — the readers kept the package default.
/// That is a Config field now, applied per connection at open time.
///
/// `cache_size` is a CEILING, not a reservation: SQLite fills it lazily as
/// pages are read, and the bench table is a few hundred KiB, so a large
/// value costs address space, not RSS.
///
/// `read_conns` is the warm floor and `max_read_conns = 0` leaves the pool
/// elastic — a read never waits behind another read, which is exactly the
/// gap the axum r2d2 pool of 8 was exploiting. Writes still take the
/// single WAL writer slot.
const db_config: databases.database.SqliteConfig = .{
    // FULL: fsync the WAL on every commit, so a write that reports success
    // survives a power cut. Same choice as PABRIK's
    // `src/boot/db_config.zig` — durability over throughput.
    //
    // CAVEAT FOR THE RESULTS: fiber / aspnet / axum all run NORMAL here,
    // so this cell becomes FULL-vs-NORMAL. Expect the write and mixed
    // numbers for kabelweb to fall, by roughly the cost of one fsync per
    // commit. That is the honest consequence of the setting, not a
    // regression in the stack — do not read it as one, and do not change
    // it back without changing the other three too.
    .synchronous = .full,
    .busy_timeout_ms = 15_000,
    .read_conns = 8,
    .max_read_conns = 0,
    .cache_size_kb = 64_000, // matches the documented -64000 contract
    .mmap_size_bytes = 256 * 1024 * 1024,
    .journal_size_limit_bytes = 64 * 1024 * 1024,
    .wal_autocheckpoint_pages = 1_000,
};

fn seedDb(allocator: std.mem.Allocator) !void {
    // `temp_store` is not a Config field, and it is a no-op on the pooled
    // readers (they only run SELECTs), so it stays a bare PRAGMA.
    gdb.exec(allocator, "PRAGMA temp_store=MEMORY;", &.{}) catch {};
    try gdb.exec(allocator, "DROP TABLE IF EXISTS users", &.{});
    try gdb.exec(allocator, "CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL, email TEXT NOT NULL)", &.{});
    var tx = try gdb.begin();
    defer tx.rollback() catch |err| switch (err) {
        error.TransactionClosed => {},
        else => {},
    };
    var i: i64 = 1;
    while (i <= 5000) : (i += 1) {
        const username = try std.fmt.allocPrint(allocator, "user_{d}", .{i});
        defer allocator.free(username);
        const email = try std.fmt.allocPrint(allocator, "user_{d}@bench.local", .{i});
        defer allocator.free(email);
        try tx.exec(allocator, "INSERT INTO users(username,email) VALUES(?,?)", &.{ username, email });
    }
    try tx.commit();
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    database.openWithConfig(&gdb, io, .{ .sqlite_path = "/tmp/sparring_sqlite.db" }, db_config) catch |err| {
        std.debug.print("db open failed: {s}\n", .{@errorName(err)});
        return err;
    };
    seedDb(allocator) catch |err| {
        std.debug.print("db seed failed: {s}\n", .{@errorName(err)});
        return err;
    };

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
    try gs.router.get("/db/health", dbHealthHandler);
    try gs.router.get("/db/user/:id", dbGetUserHandler);
    try gs.router.get("/db/users", dbListUsersHandler);
    try gs.router.post("/db/user", dbCreateUserHandler);
    try gs.router.put("/db/user/:id", dbUpdateUserHandler);
    try gs.router.delete("/db/user/:id", dbDeleteUserHandler);
    try gs.router.get("/db/search", dbSearchUsersHandler);

    std.debug.print("kabelweb bench server listening on 0.0.0.0:29590\n", .{});
    // Threads are pinned to the sandbox quota, exactly like `GOMAXPROCS=2`
    // for fiber and 2 Tokio workers for axum. cgroup CPU quota is NOT
    // pinning: `std.Thread.getCpuCount()` inside the container still reports
    // the host's 16 CPUs, so the defaults (4 accept loops, a worker pool of
    // one thread per CPU) put ~20 runnable threads on a 2-CPU budget and
    // spend their time being descheduled. The other three servers are all
    // sized to 2, so sizing kabelweb is what makes the comparison equal.
    try gs.listenEventLoop(.{ .loop_count = 1, .worker_threads = 2 });
}
