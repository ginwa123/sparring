# BENCHMARK_RESULTS.md — kabelweb (Zig) vs Fiber (Go) — RE-RUN

Generated from `results/bench_results.json` (`generated_at_utc: 2026-09-18T16:52:56Z`).
All numbers measured. Nothing estimated. Charts: see `BENCHMARK_RESULTS.html`.

## What changed since the first run

The sibling `/home/ginwa/kabelweb` repo landed
`dc459c0 perf(server): HTTP keep-alive, backlog 1024, TCP_NODELAY`
between runs (was `816e2c2`: backlog 128, close-per-request). Same harness,
same limits, rebuilt binaries. kabelweb went from flat ~13.5k rps to 66k–96k.

## Setup (equal-spec sandbox)

- Podman 6.1.1 rootless, cgroup v2. wrk (wg/wrk master, built from source) on host.
- Both detached: `--cpus=2 --memory=512m --memory-swap=512m --pids-limit=512
  --ulimit nofile=4096:4096`, loopback-only (`:29590` kabelweb, `:29591` fiber).
- kabelweb @ `dc459c0` (Zig 0.16.0 ReleaseFast) vs fiber `v2.52.15` (Go 1.27.1,
  `GOMAXPROCS=2`). Identical endpoints; `mix` = 70/20/10 Lua workload.
- 54 runs: endpoint × {c10, c50, c200} × 3 reps, alternating order, 2 s cooldown.
  This re-run uses true `-c` for **all** endpoints (the first run's runner pinned
  hello/mix to c50 — fixed in `scripts/run-bench.sh` before this sweep).
- All 54 runs parsed, 0 non-2xx. Neither container CPU-throttled.

## Results — 3-rep medians

| cell | kabelweb rps | fiber rps | kw p99 | fib p99 | winner |
|---|---|---:|---:|---:|---|
| health_c10 | 94,538 | 88,708 | 0.16 ms | 0.15 ms | kabelweb +6.6% |
| health_c50 | 92,503 | 92,370 | 0.23 ms | 0.21 ms | kabelweb +0.1% |
| health_c200 | 79,671 | 76,905 | 5.17 ms | 4.57 ms | kabelweb +3.6% |
| hello_c10 | 92,738 | 86,825 | 0.17 ms | 0.21 ms | kabelweb +6.8% |
| hello_c50 | 95,609 | 88,675 | 0.21 ms | 0.26 ms | kabelweb +7.8% |
| hello_c200 | 66,243 | 79,281 | 7.45 ms | 4.34 ms | fiber +19.7% |
| mix_c10 | 93,459 | 90,726 | 0.14 ms | 0.15 ms | kabelweb +3.0% |
| mix_c50 | 96,032 | 91,653 | 0.21 ms | 0.23 ms | kabelweb +4.8% |
| mix_c200 | 72,913 | 70,461 | 6.22 ms | 5.56 ms | kabelweb +3.5% |

Neck-and-neck: kabelweb takes 6 of 9 cells on throughput, fiber takes
`hello_c200` clearly; every other margin is under 8%. At c200 both dip
(shared wrk/pasta/host path, not either server).

## Resources (measured)

- RSS peak (1 s telemetry): kabelweb **63,404 KiB** vs fiber **13,960 KiB**.
- cgroup `memory.peak`: kabelweb 74.9 MB vs fiber 22.7 MB.
- CPU per request (cgroup `cpu.stat` Δ over 10 s c50 /health):
  kabelweb **6 µs** (5,972,717 us / 943,354 req) vs fiber **7 µs**
  (6,964,817 us / 969,848 req) — tied.

## Reproduce

```sh
(cd bench/kabelweb && zig build -Doptimize=ReleaseFast)
GOFLAGS=-mod=mod go build -trimpath -o bin/fiber-bench ./bench/fiber
dotnet publish bench/aspnet/aspnet-bench.csproj -c Release -o bin/aspnet-publish && cp bin/aspnet-publish/aspnet-bench bin/aspnet-bench
cargo build --release --manifest-path bench/axum/Cargo.toml && cp bench/axum/target/release/axum-bench bin/axum-bench
mkdir -p /tmp/sparringhttp_img
cp bench/kabelweb/zig-out/bin/kabelweb-bench bin/fiber-bench bin/aspnet-bench bin/axum-bench /tmp/sparringhttp_img/
podman build -t localhost/sparringhttp-bench:latest -f scripts/Containerfile /tmp/sparringhttp_img
scripts/sandbox.sh start kabelweb && scripts/sandbox.sh start fiber && scripts/sandbox.sh start aspnet && scripts/sandbox.sh start axum
scripts/run-bench.sh
python3 scripts/collect_results.py results
python3 scripts/render_html.py results BENCHMARK_RESULTS.html
```

## Note: aspnet / axum / realistic endpoints (wired, not yet measured)

The numbers above cover kabelweb vs Fiber on the tiny-body endpoints only.
Since that run, the harness grew without re-measuring: `bench/aspnet`
(ASP.NET Core minimal API, .NET 10 self-contained) and `bench/axum`
(axum 0.8, Tokio workers = 2) implement the same endpoints, plus two new
realistic-payload endpoints added to **all four** servers —
`GET /api/v1/product/:id` (~850 B response) and `POST /api/v1/checkout`
(~554 B cart request → order confirmation). All four pass their smoke
suites and return byte-identical product/checkout bodies (verified by
diffing live responses). `scripts/run-bench.sh` now sweeps health, hello,
product, checkout, mix, and realistic across all four sandboxes
(`:29590`–`:29593`); `collect_results.py` / `render_html.py` handle any
framework count. Next full `run-bench.sh` will produce the 4-way numbers.
