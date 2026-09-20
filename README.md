# SparringHTTP — Benchmark README

4-way HTTP benchmark: **kabelweb (Zig) vs Fiber (Go) vs ASP.NET Core (C#) vs Axum (Rust)**
in equal-spec Podman sandboxes, loaded with `wrk` from the host.

## 1. One-command flows

```sh
# fast restart only (no rebuild) — use when code didn't change
scripts/sandbox.sh start all

# rebuild binaries + image only (no restart)
scripts/sandbox.sh build all

# full refresh: stop + rebuild + start (use after changing bench code)
scripts/sandbox.sh rebuild all
```

Single framework variants: replace `all` with `kabelweb|fiber|aspnet|axum`
(e.g. `scripts/sandbox.sh rebuild fiber`).

## 2. Full benchmark run (copy-paste)

```sh
# 0. (only if bench code changed)
scripts/sandbox.sh rebuild all

# 1. start sandboxes (:29590 kabelweb, :29591 fiber, :29592 aspnet, :29593 axum)
scripts/sandbox.sh start all
scripts/sandbox.sh status

# 2. smoke-verify (all must print ALL_PASS)
scripts/smoke-kabelweb.sh && scripts/smoke-fiber.sh && scripts/smoke-aspnet.sh && scripts/smoke-axum.sh

# 3. run (~40-45 min: 4 fw x 6 endpoints x 3 concurrencies x 3 reps x ~12s)
scripts/run-bench.sh

# 4. report
python3 scripts/collect_results.py results
python3 scripts/render_html.py results BENCHMARK_RESULTS.html
# -> results/bench_results.{json,csv}, BENCHMARK_RESULTS.md/.html
```

`run-bench.sh` auto-starts any missing sandbox and aborts if the
correctness gate fails. One server under load at a time by design —
never run two `run-bench.sh` at once.

## 3. Check progress (while `run-bench.sh` runs)

```sh
# one-command progress + ETA (best)
scripts/bench-progress.sh

# live log
tail -f results/wrk_runs.log

# current wrk test
ps aux | grep "wrk " | grep -v grep
ls -lt results/wrk_*.txt | head -n 3

# how many runs started so far (total = 216)
grep -c "^== " results/wrk_runs.log
```

Current test = last `== fw endpoint_cX_rY` line in the log.
Each run is ~10s + 2s cooldown.

## 4. Sandbox control

```sh
scripts/sandbox.sh start kabelweb   # one framework
scripts/sandbox.sh stop all         # stop all (keeps image)
scripts/sandbox.sh status           # list harness containers only
scripts/sandbox.sh clean            # stop+rm all sparringhttp_* containers
```

Safety: only touches containers named `sparringhttp_*`.
Never load-tests anything but `127.0.0.1` published ports.

Equal spec per container: `--cpus=2 --memory=512m --memory-swap=512m
--pids-limit=512 --ulimit nofile=4096:4096`, loopback-only publish.
`GOMAXPROCS=2` (fiber) and Tokio workers=2 (axum) are pinned to the quota.

## 5. What `build` does

- kabelweb: `(cd bench/kabelweb && zig build -Doptimize=ReleaseFast)`
- fiber: `GOFLAGS=-mod=mod go build -trimpath -o bin/fiber-bench ./bench/fiber`
- aspnet: `dotnet publish bench/aspnet/aspnet-bench.csproj -c Release -o bin/aspnet-publish && cp bin/aspnet-publish/aspnet-bench bin/aspnet-bench`
- axum: `cargo build --release --manifest-path bench/axum/Cargo.toml && cp bench/axum/target/release/axum-bench bin/axum-bench`
- image: copies all 4 binaries to `/tmp/sparringhttp_img/` and
  `podman build -t localhost/sparringhttp-bench:latest -f scripts/Containerfile`

`start all` does **not** rebuild — it just `podman run -d` from the
existing image. Use `rebuild all` after code changes.

## 6. Results

- Raw wrk: `results/wrk_*.txt`, combined log: `results/wrk_runs.log`
- Telemetry: `results/telemetry_*.jsonl`
- Parsed: `results/bench_results.json`, `results/bench_results.csv`
- Report: `BENCHMARK_RESULTS.md`, `BENCHMARK_RESULTS.html`
- Method details: `IMPLEMENTATION_PLAN.md`
