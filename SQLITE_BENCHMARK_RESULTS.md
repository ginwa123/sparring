# SQLITE_BENCHMARK_RESULTS.md — kabelweb (ruangsql) vs Fiber vs ASP.NET Core vs Axum, sqlite-backed

Generated from `results/bench_results.json` (`generated_at_utc: 2026-10-07T13:41:40Z`,
108 sqlite runs: 4 fw × 3 workloads × 3 concurrencies × 3 reps).
All numbers measured. Nothing estimated.

## Setup (same equal-spec sandbox as the main harness)

- Podman rootless, cgroup v2. wrk on host, one server under load at a time.
- Per container: `--cpus=2 --memory=512m --memory-swap=512m --pids-limit=512
  --ulimit nofile=4096:4096`, loopback-only (`:29590` kabelweb, `:29591` fiber,
  `:29592` aspnet, `:29593` axum). `GOMAXPROCS=2` (fiber), Tokio workers=2 (axum).
- Workloads: `-c 10, 50, 200` at `-t 4` threads, 10 s runs, 3 reps each,
  alternating framework order between reps, 2 s cooldown.
- Runner: `scripts/run-bench-sqlite.sh` (mirrors `run-bench.sh` methodology);
  raw output in `results/wrk_*_sqlite_*.txt`, combined log `results/wrk_runs_sqlite.log`,
  telemetry `results/telemetry_*_sqlite.jsonl`.

## Scenario contract (identical on all four)

- Seed (on every server start): `DROP TABLE IF EXISTS users`,
  `CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL, email TEXT NOT NULL)`, then one transaction
  inserting 5000 rows `user_{i}` / `user_{i}@bench.local` (i=1..5000).
- DB file: `/tmp/sparring_sqlite.db` per container (each seeds its own copy).
- Tuning (all four): `journal_mode=WAL`, `busy_timeout=5000`,
  `synchronous=NORMAL`, `cache_size=-64000` (64 MB page cache),
  `temp_store=MEMORY`.
- Endpoints (7 total — multiple reads, multiple writes, both):
  `GET /db/health` (`SELECT 1` → `{"ok":true}`),
  `GET /db/user/:id` (point read → `{"id":N,"username":"...","email":"..."}` / 404),
  `GET /db/users?limit=N` (range scan, default 20, clamp 1..100),
  `GET /db/search?q=X&limit=N` (complex read: `WHERE username LIKE %q% OR email LIKE %q% ORDER BY id LIMIT ?` / 400 on empty q),
  `POST /db/user` (insert → 201 / 400), `PUT /db/user/:id` (update → 200 / 404),
  `DELETE /db/user/:id` (→ `{"deleted":N}` / 404).
- Parity: `scripts/smoke-db.sh` prints `ALL_PASS` on all four (byte-identical
  JSON shapes, same status codes including 404-on-bad-id).

## Libraries (each framework's idiomatic sqlite stack)

| Framework | Library | Notes |
|---|---|---|
| kabelweb (Zig 0.16.0 ReleaseFast) | **ruangsql** (`database.Db`, path dep `../../../ruangsql`) | kabelweb @ `bf64f90`, ruangsql @ `b3aed97` — both verified latest (each 1 commit ahead of origin/main, nothing newer upstream). Single connection + internal mutex, `last_insert_rowid()` for POST |
| Fiber (Go, `GOMAXPROCS=2`) | `modernc.org/sqlite v1.60.1` (pure Go, no cgo) | `database/sql`, `MaxOpenConns=8`, hermetic in the bench image |
| ASP.NET Core (.NET 10, self-contained) | `Microsoft.Data.Sqlite 10.0.10` | Per-request connections; native `libe_sqlite3.so` ships in the bench image next to the binary (probed from `/srv/`) |
| Axum (Rust, Tokio workers=2) | `rusqlite 0.31` (bundled) + `r2d2`/`r2d2_sqlite` pool (size 8) | `pool.get()` per request |

Bench image change vs the main harness: `scripts/Containerfile` adds `sqlite`
(system `libsqlite3` for the kabelweb/ruangsql system-link path) and
`libe_sqlite3.so` for ASP.NET.

## Workloads (`scripts/wrk-sqlite-*.lua`)

- `sqlite_read`: 50% point read (random id 1..5000), 25% list, 25% LIKE search. No writes.
- `sqlite_write`: 50% POST insert (unique names), 50% PUT update (ids 1..5000). No deletes.
- `sqlite_mixed`: 50% point read, 15% list, 10% search, 10% POST, 10% PUT, 5% DELETE.

## Results — 3-rep medians (throughput, higher is better)

| cell | kabelweb rps | fiber rps | aspnet rps | axum rps | winner |
|---|---|---:|---:|---:|---|
| sqlite_read_c10 | 29,085 | 51,812 | 16,850 | 90,129 | axum +73.9% over fiber |
| sqlite_read_c50 | 22,878 | 51,834 | 26,323 | 93,806 | axum +81.0% over fiber |
| sqlite_read_c200 | 20,395 | 47,079 | 15,617 | 82,262 | axum +74.7% over fiber |
| sqlite_write_c10 | 27,288 | 11,032 | 12,945 | 16,831 | kabelweb +62.1% over axum |
| sqlite_write_c50 | 27,588 | 12,082 | 16,947 | 14,971 | kabelweb +62.8% over aspnet |
| sqlite_write_c200 | 25,910 | 12,089 | 15,963 | 14,604 | kabelweb +62.3% over aspnet |
| sqlite_mixed_c10 | 34,842 | 31,114 | 16,079 | 46,696 | axum +34.0% over kabelweb |
| sqlite_mixed_c50 | 29,539 | 33,188 | 24,912 | 47,548 | axum +43.3% over fiber |
| sqlite_mixed_c200 | 26,847 | 30,659 | 23,000 | 46,653 | axum +52.2% over fiber |

Reads scale with connection parallelism (axum pool 8 ≫ kabelweb single-mutex
connection); writes favour the single serialized writer (kabelweb/ruangsql
fastest, lowest tail latency). axum takes all read/mixed cells, kabelweb
takes all write cells.

## Tail latency — p99 median (ms, lower is better)

| cell | kabelweb | fiber | aspnet | axum |
|---|---|---:|---:|---:|
| sqlite_read_c10 | 22.62 | 0.48 | 47.61 | 0.16 |
| sqlite_read_c50 | 35.51 | 2.91 | 28.14 | 0.77 |
| sqlite_read_c200 | 52.34 | 10.77 | 47.77 | 4.48 |
| sqlite_write_c10 | 4.25 | 77.18 | 218.07 | 18.44 |
| sqlite_write_c50 | 8.82 | 72.91 | 133.10 | 13.83 |
| sqlite_write_c200 | 17.14 | 82.77 | 232.80 | 81.93 |
| sqlite_mixed_c10 | 15.43 | 17.88 | 288.98 | 3.29 |
| sqlite_mixed_c50 | 25.65 | 23.38 | 361.39 | 3.67 |
| sqlite_mixed_c200 | 37.22 | 28.53 | 377.07 | 22.21 |

kabelweb's read p99 reflects mutex-serialized reads behind writes on one
connection; its write p99 is the best in every cell. ASP.NET's mixed/write
tail (133–377 ms) suggests connection-churn/GC pressure under write
contention — worth profiling, reported as measured.

## Honesty notes (non-2xx, no reseed between runs)

- The DB is seeded once per container start and **not** reseeded between
  runs, so state drifts across the sweep identically on all frameworks
  (deterministic wrk sequences): PUTs/DELETEs against already-deleted ids
  return 404 and count as non-2xx. Totals over 3 reps: mixed 24k–72k,
  write 11k–42k, read 84–552 (reads only 404 on rows deleted by earlier
  mixed/write runs). Zero socket errors in all 108 runs.
- The drift is fair (same seed, same request order, same gate — including a
  gate-time `DELETE /db/user/4998` — on every framework) but it means
  write/mixed rps mixes 2xx + cheap-404 responses. A future run could add a
  reseed endpoint for perfect isolation.

## Resources (sqlite-run telemetry, 1 s samples)

| Framework | RSS peak | RSS median | Note |
|---|---|---:|---|
| kabelweb | 96,036 KiB | 53,332 KiB | 64 MB page cache (`cache_size=-64000`) dominates; cf. 6.8 MB peak in the no-db run |
| fiber | 37,844 KiB | 31,284 KiB | |
| aspnet | 142,848 KiB | 118,876 KiB | highest; correlates with mixed/write tail |
| axum | 16,480 KiB | 16,156 KiB | lowest |

## Reproduce

```sh
scripts/sandbox.sh rebuild all   # binaries + image (with sqlite + libe_sqlite3.so)
scripts/sandbox.sh start all
bash scripts/smoke-db.sh 29590 kabelweb  # ALL_PASS (repeat per port/fw)
bash scripts/run-bench-sqlite.sh         # ~20 min, 108 runs
python3 scripts/collect_results.py results
```

---

# ruangsql optimization round (2026-10-07) — kabelweb re-measured

After the sweep above, `ruangsql` was optimized (all changes **transparent**:
same `exec` / `query` / `queryRow` / `init` signatures, no new methods, so
existing callers speed up untouched), the kabelweb bench server was sized to
the sandbox quota, and both were re-measured at `c50` (2 reps, medians).

## What changed in ruangsql (each one measured)

| # | Change | Evidence |
|---|---|---|
| 1 | **Prepared-statement cache** — `exec` and `queryRow` used to `sqlite3_prepare_v2` + `finalize` on every call; they now reuse a per-connection statement keyed by SQL text. `query` uses it too, with a per-connection guard so a second live iterator falls back to a one-shot statement instead of resetting the first. | host, list endpoint: **156,909 → 120,358 instructions/request (-23%)**, p99 1.23 ms → 0.73 ms |
| 2 | **Transparent read pooling** — `init` opens `Config.read_conns` (default 7) extra read-only connections; reads round-robin across them, writes stay on the primary connection (SQLite allows exactly one writer). Works because WAL permits many concurrent readers. | host read mix **50 k → 185 k rps (+270%)**; sandbox read mix 29 k → 62 k |
| 3 | **Packed rows** — a row is now 2 allocations (values slice + one shared column buffer) instead of 1 + one per column; a 20-row list drops from ~80 allocator calls to ~40. `Row.values` / `Row.deinit` unchanged. | contributes to #1's p99; per-row cost measured at 0.06 µs |
| 4 | **Best-by-default pragmas** — `cache_size_kb` 8 MiB (SQLite ships 2 MiB), `mmap_size_bytes` 256 MiB window; both configurable, 0 restores SQLite's own default. | cheap read win, file-backed mmap does not count against `memory.max` |
| 5 | **Connection-state SQL stays on the writer** — `last_insert_rowid()` / `changes()` / `total_changes()` are per-connection, so they are routed to the connection that wrote. Without this a pooled `SELECT last_insert_rowid()` silently returns 0. | POST returns the real id (smoke: `{"id":5001,…}`) |
| 6 | `query` keeps its statement but **does not hold the connection lock** for the iteration — a leaked iterator must not deadlock a connection (the lock-holding variant deadlocked the suite and was reverted). | 124/124 tests, suite green |

## kabelweb bench sizing (equal-spec fix, same class as `GOMAXPROCS=2`)

cgroup CPU quota is **not** pinning: `std.Thread.getCpuCount()` inside the
container still reports the host's 16 CPUs. The bench server therefore ran
2 event loops + a worker pool sized from 16 CPUs on a 2-CPU budget.

| config | point read | list | search |
|---|---:|---:|---:|
| `loop_count=4`, pool = 16 (original) | 85.0 k | 53.0 k | 32.3 k |
| `loop_count=2`, `worker_threads=2` | 85.0 k | 53.0 k | 32.3 k |
| **`loop_count=1`, `worker_threads=2`** | **92.0 k** | **75.2 k** | **55.1 k** |
| `loop_count=1`, `worker_threads=3` | — | 72.3 k | — (oversubscribed) |

The second event loop busy-polls and steals half the 2-CPU budget; one loop
plus two workers is the right shape here. Also note the DB path is now
**free**: `/db/user/42` (92.1 k) sits at 99.7 % of kabelweb's own
no-DB ceiling (`/health`, 92.3 k).

## Result vs axum (sandbox, `c50`, medians of 2 reps)

| workload | kabelweb | axum | kabelweb vs axum |
|---|---:|---:|---|
| `sqlite_read` | 83,183 | 90,993 | **0.91× (91 %)** |
| `sqlite_write` | 36,921 | 13,814 | **2.67× — kabelweb wins** |
| `sqlite_mixed` | 59,273 | 44,841 | **1.32× — kabelweb wins** |

Before this round kabelweb was at read ≈ 29 k / write ≈ 27 k / mixed ≈ 29 k
against the same axum build, i.e. **reads +187 %, writes +37 %, mixed +104 %**,
and it now wins two of the three workloads.

Two independent measurements put the remaining read gap in kabelweb's HTTP
layer, not in the database:

- kabelweb `/health` (no DB) = 94,671 vs axum 94,550 — the HTTP layers match.
- kabelweb's point read is 99.7 % of its own no-DB ceiling, so ruangsql adds
  ≈ 0 to a point read. The residual read deficit is the 20-row
  `GET /db/users` handler (77.2 k vs a 94.7 k ceiling) and the `LIKE` scan
  endpoint (56.5 k).

### Engines compared (vendored vs system SQLite)

`bench/kabelweb` now takes `-Dsqlite-vendor=true` to compile ruangsql's
vendored amalgamation at `ReleaseFast` instead of linking the distro's
`libsqlite3`. Measured (sandbox, `c50`): point read 92,068 → **93,795**,
list 77,242 → **78,934**, search 55,142 → **56,518** — consistently ~1–2 %
faster and hermetic (no dependency on the distro's SQLite build).
