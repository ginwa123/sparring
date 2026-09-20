# SparringHTTP — kabelweb (Zig) vs Fiber (Go) vs ASP.NET Core (C#) vs Axum (Rust)
benchmark in equal-spec Podman sandboxes

**Status: PLAN — harness wired for 4 frameworks; latest measured run covers
kabelweb vs Fiber only (see BENCHMARK_RESULTS.md).** This document is the
implementation plan agreed for this workspace.

## Goal

Run **kabelweb** (pure-Zig HTTP server, built from the sibling repo at
`/home/ginwa/kabelweb`), **gofiber/fiber** (Go), **ASP.NET Core minimal API**
(C#, .NET 10 self-contained), and **Axum** (Rust, Tokio) as **detached
background processes inside Podman containers with identical, enforced
resource limits**, load-test all with wrk from the host, and write an honest,
data-backed results report.

## Equal-spec sandbox (defaults, overridable)

| Resource | Value | Enforcement |
|---|---|---|
| CPU | 2.0 CPUs | cgroup v2 `cpu.max` (quota, not pinning — documented caveat) |
| Memory | 512 MiB | `memory.max` |
| Swap | none extra | `memory-swap == memory` ⇒ `memory.swap.max = 0` |
| Tasks | 512 | `pids.max` |
| nofile | 4096:4096 | `--ulimit nofile=4096:4096` |
| Ports | loopback only | `-p 127.0.0.1:<port>:8080` |

Host ports: `:29590` kabelweb, `:29591` fiber, `:29592` aspnet, `:29593`
axum. Every server listens on `0.0.0.0:29590` inside its container namespace.

Runtime sizing is pinned to the quota on every framework: `GOMAXPROCS=2`
(fiber, via sandbox.sh — cgroup CPU quota is not pinning), Tokio worker
threads = 2 (axum, in code). ASP.NET Core is cgroup-aware since .NET 7
(ThreadPool/GC read `cpu.max`), so no pinning env is needed; the binary is
published self-contained single-file with invariant globalization (no ICU
needed in the bench image).

Verified on this host (podman 6.1.1 + crun 1.29.1, rootless, cgroup v2 via
systemd): all five limits land inside the container; memory limit provably
OOM-kills at 64 MiB. `--cpus` is quota — the container still sees all host
CPUs in `nproc`, so runtimes that size their thread pools from CPU count
(Go's `GOMAXPROCS`) must be pinned explicitly (we set `GOMAXPROCS=2` in the
Fiber container).

## Methodology

- One server under test at a time; wrk runs **on the host**, so load and
  server resources never compete inside the sandbox.
- Endpoints identical on all servers: `GET /health`, `GET /hello/:name`,
  `POST /users` (JSON parse + echo), `POST /api/v1/echo`,
  `GET /api/v1/product/:id` (realistic ~850 B product document, id
  substituted — byte-identical on all four), `POST /api/v1/checkout`
  (realistic ~554 B cart JSON parsed + totaled; fixed cart yields
  `{"order_id":"ord-u-7f3a9c","status":"confirmed","items":9,"total":165.26,...}`
  — byte-identical on all four).
- Workload: per-endpoint wrk runs + a tiny-body mixed run
  (`scripts/wrk-mix.lua`: 70% /health, 20% /hello, 10% echo) + a realistic
  mixed run (`scripts/wrk-realistic.lua`: 50% product GET, 50% checkout
  POST with the fixed cart body; single-endpoint checkout sweep uses
  `scripts/wrk-checkout.lua`).
- Concurrency sweep: `-c 10, 50, 200` at `-t 4` threads, 10 s runs,
  3 repetitions each, alternating framework order between reps
  (A,B / B,A / A,B) and a 2 s cooldown between runs.
- Telemetry: RSS + CPU from `podman inspect`/`/proc/<pid>` of the container's
  init PID, sampled at start/mid/end of each run; cgroup
  `cpu.stat`/`memory.peak` for sandbox-side truth.
- Correctness gate before every measurement: the smoke suite
  (`scripts/smoke-*.sh`) must pass on the container-published port, else the
  run aborts.
- Raw wrk output, per-run JSON, and CSV land in `results/`;
  `BENCHMARK_RESULTS.md` is generated from the actual numbers only.

## Build & run

```sh
# build all four bench servers
(cd bench/kabelweb && zig build -Doptimize=ReleaseFast)
GOFLAGS=-mod=mod go build -trimpath -o bin/fiber-bench ./bench/fiber
dotnet publish bench/aspnet/aspnet-bench.csproj -c Release -o bin/aspnet-publish && cp bin/aspnet-publish/aspnet-bench bin/aspnet-bench
cargo build --release --manifest-path bench/axum/Cargo.toml && cp bench/axum/target/release/axum-bench bin/axum-bench

# smoke-verify each server (all must print ALL_PASS; product/checkout bodies
# are byte-identical across frameworks — see /tmp/parity.sh pattern)
scripts/smoke-kabelweb.sh && scripts/smoke-fiber.sh && scripts/smoke-aspnet.sh && scripts/smoke-axum.sh

# sandbox control (start/stop/status, detached)
scripts/sandbox.sh start kabelweb   # :29590
scripts/sandbox.sh start fiber      # :29591
scripts/sandbox.sh start aspnet     # :29592
scripts/sandbox.sh start axum       # :29593
scripts/sandbox.sh status
scripts/sandbox.sh stop kabelweb

# full benchmark + report
scripts/run-bench.sh            # writes results/*.json, results/*.csv
# results report: BENCHMARK_RESULTS.md (generated)
```

## Non-goals / safety

- Never load-test anything but `127.0.0.1` published ports.
- The harness only ever creates/stops containers named `sparringhttp_*`
  (the user's pre-existing `keen_banzai` container is off-limits).
- No numbers in the report are estimated; anything not measured is labelled
  "not measured".
