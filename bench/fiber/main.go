// bench/fiber/main.go — sparringhttp Fiber bench server.
//
// Endpoints are identical to the kabelweb bench server (bench/kabelweb/main.zig)
// so both frameworks are measured on the same workload. Runs on :29590 (same
// port the kabelweb demo uses) — the harness never runs both at once.
package main

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"fmt"
	"html"
	"html/template"
	"log"
	"strconv"

	"github.com/gofiber/contrib/websocket"
	"github.com/gofiber/fiber/v2"
	_ "modernc.org/sqlite"
)

// maxBody caps the JSON echo body; matches the kabelweb parser cap (32 KiB).
const maxBody = 32 * 1024

// user mirrors the kabelweb bench server's /users payload.
type user struct {
	Username string `json:"username"`
	Email    string `json:"email"`
}

// dbUser is the /db/* row shape; field order id,username,email is part of
// the shared contract (json.Marshal emits struct fields in order, compact).
type dbUser struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
}

const sqliteDSN = "file:/tmp/sparring_sqlite.db?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)"

// initDB opens the file-backed DB, applies tuning PRAGMAs, and seeds 5000
// rows in one transaction. Each container seeds its own copy on startup.
func initDB() *sql.DB {
	db, err := sql.Open("sqlite", sqliteDSN)
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(8)
	for _, p := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA busy_timeout=5000",
		"PRAGMA synchronous=NORMAL",
		"PRAGMA cache_size=-64000",
		"PRAGMA temp_store=MEMORY",
	} {
		if _, err := db.Exec(p); err != nil {
			log.Fatal(err)
		}
	}
	for _, s := range []string{
		"DROP TABLE IF EXISTS users",
		"CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL, email TEXT NOT NULL)",
	} {
		if _, err := db.Exec(s); err != nil {
			log.Fatal(err)
		}
	}
	tx, err := db.Begin()
	if err != nil {
		log.Fatal(err)
	}
	stmt, err := tx.Prepare("INSERT INTO users(username, email) VALUES(?, ?)")
	if err != nil {
		log.Fatal(err)
	}
	for i := 1; i <= 5000; i++ {
		u := fmt.Sprintf("user_%d", i)
		if _, err := stmt.Exec(u, u+"@bench.local"); err != nil {
			stmt.Close()
			tx.Rollback()
			log.Fatal(err)
		}
	}
	stmt.Close()
	if err := tx.Commit(); err != nil {
		log.Fatal(err)
	}
	return db
}

// dbRowJSON marshals a row with compact field order id,username,email.
func dbRowJSON(id int64, username, email string) string {
	b, _ := json.Marshal(dbUser{ID: id, Username: username, Email: email})
	return string(b)
}

func validDBUser(u *user) bool {
	return u.Username != "" && u.Email != ""
}

// checkout mirrors the shared realistic-payload contract: a cart with items,
// an optional coupon, and customer/shipping/payment detail (~0.6KB).
type checkoutItem struct {
	Qty   int64   `json:"qty"`
	Price float64 `json:"price"`
}

type checkout struct {
	UserID string         `json:"user_id"`
	Items  []checkoutItem `json:"items"`
	Coupon string         `json:"coupon"`
}

// productJSON is the static ~1KB product document; only the id varies.
func productJSON(id int) string {
	return fmt.Sprintf(`{"id":%d,`+
		`"sku":"SKU-0042-WIDGET","name":"Ergonomic Wireless Mouse",`+
		`"description":"A comfortable wireless mouse with adjustable DPI up to 3200, silent clicks and up to 18 months of battery life. Ideal for office work and travel.",`+
		`"price":29.99,"currency":"USD","category":"electronics",`+
		`"tags":["wireless","mouse","office","ergonomic","usb-c"],`+
		`"variants":[{"sku":"SKU-0042-BLK","color":"black","price":29.99,"stock":134},`+
		`{"sku":"SKU-0042-WHT","color":"white","price":31.99,"stock":58}],`+
		`"inventory":{"warehouse":"eu-central-1","quantity":192,"reserved":17,"restock_eta":"2026-10-02"},`+
		`"rating":4.6,"reviews":1284,`+
		`"dimensions":{"length_cm":10.2,"width_cm":6.1,"height_cm":3.8,"weight_g":89},`+
		`"shipping":{"free_over":50.0,"methods":["standard","express","pickup"],"dispatch_hours":24},`+
		`"created_at":"2024-03-15T09:30:00Z","updated_at":"2026-09-01T14:22:10Z"}`,
		id)
}

// pageTmpl renders GET /page via stdlib html/template (inline, no files).
var pageTmpl = template.Must(template.New("page").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>Hello</title></head><body><h1>Hello, {{.Name}}!</h1></body></html>`))

func main() {
	db := initDB()
	defer db.Close()

	app := fiber.New(fiber.Config{
		AppName:               "fiber-bench",
		DisableStartupMessage: true,
		// No explicit worker/pool tuning: both servers run with runtime
		// defaults under identical container quotas (2 CPUs). GOMAXPROCS
		// is pinned to 2 by the harness (sandbox.sh) because cgroup CPU
		// quota is not pinning — without it the Go runtime would size its
		// pools from the 16 host CPUs visible inside the container.
	})

	app.Get("/health", func(c *fiber.Ctx) error {
		return c.SendString("OK")
	})

	app.Get("/hello/:name", func(c *fiber.Ctx) error {
		name := c.Params("name")
		if name == "" {
			name = "HTTP"
		}
		return c.SendString("Hello, " + name + "! (greeting: hello, mood: neutral)")
	})

	app.Post("/api/v1/echo", func(c *fiber.Ctx) error {
		if len(c.Body()) > maxBody {
			return c.Status(413).SendString("body too large")
		}
		return c.Send(c.Body())
	})

	app.Post("/users", func(c *fiber.Ctx) error {
		var u user
		if err := json.Unmarshal(c.Body(), &u); err != nil {
			return c.Status(400).SendString("invalid JSON")
		}
		return c.Status(201).JSON(u)
	})

	// Realistic-payload contract (shared by all four bench servers,
	// byte-identical bodies): ~1KB product document + cart checkout.
	app.Get("/api/v1/product/:id", func(c *fiber.Ctx) error {
		id, err := strconv.Atoi(c.Params("id"))
		if err != nil {
			id = 0
		}
		c.Set("Content-Type", "application/json")
		return c.SendString(productJSON(id))
	})

	app.Post("/api/v1/checkout", func(c *fiber.Ctx) error {
		if len(c.Body()) > maxBody {
			return c.Status(413).SendString("body too large")
		}
		var cart checkout
		if err := json.Unmarshal(c.Body(), &cart); err != nil {
			return c.Status(400).SendString("invalid JSON")
		}
		if len(cart.Items) == 0 {
			return c.Status(400).SendString("invalid JSON")
		}
		var subtotal float64
		var count int64
		for _, it := range cart.Items {
			subtotal += float64(it.Qty) * it.Price
			count += it.Qty
		}
		if count == 0 {
			return c.Status(400).SendString("invalid JSON")
		}
		var discount float64
		if cart.Coupon == "SAVE10" {
			discount = subtotal * 0.10
		}
		total := subtotal - discount
		c.Set("Content-Type", "application/json")
		return c.SendString(fmt.Sprintf(
			`{"order_id":"ord-%s","status":"confirmed","items":%d,"total":%s,"currency":"USD","eta":"2026-09-25"}`,
			cart.UserID, count, strconv.FormatFloat(total, 'f', 2, 64)))
	})

	app.Get("/ws", func(c *fiber.Ctx) error {
		if !websocket.IsWebSocketUpgrade(c) {
			return c.SendStatus(426)
		}
		return websocket.New(func(conn *websocket.Conn) {
			for {
				mt, msg, err := conn.ReadMessage()
				if err != nil {
					return
				}
				if mt != websocket.TextMessage && mt != websocket.BinaryMessage {
					continue
				}
				if err := conn.WriteMessage(mt, msg); err != nil {
					return
				}
			}
		})(c)
	})

	app.Get("/events", func(c *fiber.Ctx) error {
		c.Set("Content-Type", "text/event-stream")
		c.Set("Cache-Control", "no-cache")
		c.Set("Connection", "keep-alive")
		c.Set("X-Accel-Buffering", "no")
		c.Status(200)
		c.Context().SetBodyStreamWriter(func(w *bufio.Writer) {
			for i := 1; i <= 5; i++ {
				fmt.Fprintf(w, "id: %d\nevent: tick\ndata: {\"seq\":%d}\n\n", i, i)
				w.Flush()
			}
		})
		return nil
	})

	app.Get("/page", func(c *fiber.Ctx) error {
		name := c.Query("name")
		if name == "" {
			name = "HTTP"
		}
		c.Set("Content-Type", "text/html; charset=utf-8")
		return pageTmpl.Execute(c.Response().BodyWriter(), map[string]any{
			"Name": template.HTML(html.EscapeString(name)),
		})
	})

	// Shared sqlite contract (byte-identical across all four bench servers).
	app.Get("/db/health", func(c *fiber.Ctx) error {
		var one int
		if err := db.QueryRow("SELECT 1").Scan(&one); err != nil {
			return c.Status(500).SendString("unhealthy")
		}
		c.Set("Content-Type", "application/json")
		return c.SendString(`{"ok":true}`)
	})

	app.Get("/db/user/:id", func(c *fiber.Ctx) error {
		id, err := strconv.ParseInt(c.Params("id"), 10, 64)
		if err != nil || id <= 0 {
			return c.Status(404).SendString("not found")
		}
		var u dbUser
		err = db.QueryRow("SELECT id, username, email FROM users WHERE id = ?", id).Scan(&u.ID, &u.Username, &u.Email)
		if err != nil {
			return c.Status(404).SendString("not found")
		}
		c.Set("Content-Type", "application/json")
		return c.SendString(dbRowJSON(u.ID, u.Username, u.Email))
	})

	app.Get("/db/users", func(c *fiber.Ctx) error {
		limit := 20
		if s := c.Query("limit"); s != "" {
			n, err := strconv.Atoi(s)
			if err != nil {
				n = 20
			}
			limit = n
		}
		if limit < 1 {
			limit = 1
		}
		if limit > 100 {
			limit = 100
		}
		rows, err := db.Query("SELECT id, username, email FROM users ORDER BY id LIMIT ?", limit)
		if err != nil {
			return c.Status(500).SendString("query failed")
		}
		defer rows.Close()
		out := make([]dbUser, 0, limit)
		for rows.Next() {
			var u dbUser
			if err := rows.Scan(&u.ID, &u.Username, &u.Email); err != nil {
				return c.Status(500).SendString("query failed")
			}
			out = append(out, u)
		}
		b, _ := json.Marshal(out)
		c.Set("Content-Type", "application/json")
		return c.Send(b)
	})

	app.Post("/db/user", func(c *fiber.Ctx) error {
		if len(c.Body()) > maxBody {
			return c.Status(400).SendString("invalid JSON")
		}
		var u user
		if err := json.Unmarshal(c.Body(), &u); err != nil || !validDBUser(&u) {
			return c.Status(400).SendString("invalid JSON")
		}
		res, err := db.Exec("INSERT INTO users(username, email) VALUES(?, ?)", u.Username, u.Email)
		if err != nil {
			return c.Status(500).SendString("insert failed")
		}
		lid, err := res.LastInsertId()
		if err != nil {
			return c.Status(500).SendString("insert failed")
		}
		c.Set("Content-Type", "application/json")
		return c.Status(201).SendString(dbRowJSON(lid, u.Username, u.Email))
	})

	app.Put("/db/user/:id", func(c *fiber.Ctx) error {
		id, err := strconv.ParseInt(c.Params("id"), 10, 64)
		if err != nil || id <= 0 {
			return c.Status(404).SendString("not found")
		}
		if len(c.Body()) > maxBody {
			return c.Status(400).SendString("invalid JSON")
		}
		var u user
		if err := json.Unmarshal(c.Body(), &u); err != nil || !validDBUser(&u) {
			return c.Status(400).SendString("invalid JSON")
		}
		res, err := db.Exec("UPDATE users SET username = ?, email = ? WHERE id = ?", u.Username, u.Email, id)
		if err != nil {
			return c.Status(500).SendString("update failed")
		}
		n, err := res.RowsAffected()
		if err != nil || n == 0 {
			return c.Status(404).SendString("not found")
		}
		var out dbUser
		err = db.QueryRow("SELECT id, username, email FROM users WHERE id = ?", id).Scan(&out.ID, &out.Username, &out.Email)
		if err != nil {
			return c.Status(404).SendString("not found")
		}
		c.Set("Content-Type", "application/json")
		return c.SendString(dbRowJSON(out.ID, out.Username, out.Email))
	})

	app.Delete("/db/user/:id", func(c *fiber.Ctx) error {
		id, err := strconv.ParseInt(c.Params("id"), 10, 64)
		if err != nil || id <= 0 {
			return c.Status(404).SendString("not found")
		}
		res, err := db.Exec("DELETE FROM users WHERE id = ?", id)
		if err != nil {
			return c.Status(500).SendString("delete failed")
		}
		n, err := res.RowsAffected()
		if err != nil || n == 0 {
			return c.Status(404).SendString("not found")
		}
		c.Set("Content-Type", "application/json")
		return c.SendString(fmt.Sprintf(`{"deleted":%d}`, id))
	})

	app.Get("/db/search", func(c *fiber.Ctx) error {
		q := c.Query("q")
		if q == "" {
			return c.Status(400).SendString("invalid query")
		}
		limit := 20
		if s := c.Query("limit"); s != "" {
			n, err := strconv.Atoi(s)
			if err != nil {
				n = 20
			}
			limit = n
		}
		if limit < 1 {
			limit = 1
		}
		if limit > 100 {
			limit = 100
		}
		like := "%" + q + "%"
		rows, err := db.Query("SELECT id, username, email FROM users WHERE username LIKE ? OR email LIKE ? ORDER BY id LIMIT ?", like, like, limit)
		if err != nil {
			return c.Status(500).SendString("query failed")
		}
		defer rows.Close()
		out := make([]dbUser, 0, limit)
		for rows.Next() {
			var u dbUser
			if err := rows.Scan(&u.ID, &u.Username, &u.Email); err != nil {
				return c.Status(500).SendString("query failed")
			}
			out = append(out, u)
		}
		b, _ := json.Marshal(out)
		c.Set("Content-Type", "application/json")
		return c.Send(b)
	})

	// Listen on all interfaces inside the container namespace; the sandbox
	// publishes 127.0.0.1:<port> -> 8080 so exposure stays loopback-only on
	// the host side.
	log.Fatal(app.Listen(":29590"))
}
