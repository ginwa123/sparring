#!/usr/bin/env bash
# scripts/run-bench.sh — full benchmark: wrk sweeps on both containers + telemetry.
# Writes raw wrk output, per-run JSON, and results/bench_results.{json,csv}.
#
# Protocol (bounded, honest):
#   - one server measured at a time (never two under load simultaneously)
#   - endpoints: health, hello, product, checkout (single-URL runs)
#     + mix (wrk-mix.lua: tiny bodies) + realistic (wrk-realistic.lua:
#     50% ~1KB product GET, 50% ~0.6KB checkout POST)
#   - concurrency -c 10 50 200, threads 4, duration 10s, 3 repetitions
#   - alternating order: rep1 A,B rep2 B,A rep3 A,B (fairness against drift)
#   - 2s cooldown between runs
set -euo pipefail
cd /home/ginwa/sparringhttp

WRK=./tools/wrk/wrk
RESULTS=results
mkdir -p "$RESULTS"
for _fw in kabelweb fiber aspnet axum; do
  : >"$RESULTS/telemetry_${_fw}.jsonl"
done

# Frameworks and host ports
declare -A PORT=( [kabelweb]=29590 [fiber]=29591 [aspnet]=29592 [axum]=29593 )
FWLIST=(kabelweb fiber aspnet axum)

ready() { # fw -> exit 0 when /health answers
  curl -s -m 2 "http://127.0.0.1:${PORT[$1]}/health" | grep -q OK
}

# Ensure both sandboxes are up
for fw in "${FWLIST[@]}"; do
  if ! podman container exists "sparringhttp_$fw"; then
    echo "[harness] starting sandbox $fw"
    scripts/sandbox.sh start "$fw" >/dev/null
  fi
  ready "$fw" || { echo "[harness] $fw not ready"; exit 1; }
  echo "[harness] $fw ready on :${PORT[$fw]}"
done

# Start telemetry samplers (one per framework)
TEL_PIDS=()
for _fw in "${FWLIST[@]}"; do
  scripts/telemetry.sh "sparringhttp_${_fw}" "$RESULTS/telemetry_${_fw}.jsonl" 1 &
  TEL_PIDS+=($!)
done
cleanup() {
  kill "${TEL_PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

run_wrk() { # fw label url extra-args...
  local fw="$1" label="$2" url="$3"; shift 3
  local out="$RESULTS/wrk_${fw}_${label}.txt"
  echo "== $fw $label $(date -Is) $*" >>"$RESULTS/wrk_runs.log"
  timeout 40 "$WRK" -t4 "$@" --latency "$url" >"$out" 2>&1 || true
  cat "$out" >>"$RESULTS/wrk_runs.log"
  echo >>"$RESULTS/wrk_runs.log"
}

# Correctness gate: mixed-workload smoke on all frameworks before measuring
for fw in "${FWLIST[@]}"; do
  curl -s -m 2 "http://127.0.0.1:${PORT[$fw]}/hello/Gate" | grep -q "Hello, Gate!" || { echo "gate fail $fw"; exit 1; }
  curl -s -m 2 -X POST -d 'gate' "http://127.0.0.1:${PORT[$fw]}/api/v1/echo" | grep -q 'gate' || { echo "gate fail echo $fw"; exit 1; }
  curl -s -m 2 "http://127.0.0.1:${PORT[$fw]}/api/v1/product/42" | grep -q '"id":42' || { echo "gate fail product $fw"; exit 1; }
  curl -s -m 2 -X POST -H 'Content-Type: application/json' -d '{"user_id":"u-7f3a9c","items":[{"sku":"SKU-0042-BLK","qty":2,"price":29.99}],"coupon":""}' \
    "http://127.0.0.1:${PORT[$fw]}/api/v1/checkout" | grep -q '"status":"confirmed"' || { echo "gate fail checkout $fw"; exit 1; }
done
echo "[harness] correctness gates passed"

# Warm-up: 3s each
for fw in "${FWLIST[@]}"; do
  timeout 10 "$WRK" -t4 -c10 -d3s "http://127.0.0.1:${PORT[$fw]}/health" >/dev/null 2>&1 || true
done

# Sweep: endpoint x concurrency x repetition, alternating framework order
for rep in 1 2 3; do
  if (( rep % 2 == 1 )); then ORDER=(kabelweb fiber aspnet axum); else ORDER=(axum aspnet fiber kabelweb); fi
  for fw in "${ORDER[@]}"; do
    p="${PORT[$fw]}"
    for c in 10 50 200; do
      run_wrk "$fw" "health_c${c}_r${rep}" "http://127.0.0.1:$p/health" -c"$c" -d10s
      sleep 2
      run_wrk "$fw" "hello_c${c}_r${rep}"  "http://127.0.0.1:$p/hello/Bench" -c"$c" -d10s
      sleep 2
      run_wrk "$fw" "product_c${c}_r${rep}" "http://127.0.0.1:$p/api/v1/product/1234" -c"$c" -d10s
      sleep 2
      run_wrk "$fw" "checkout_c${c}_r${rep}" "http://127.0.0.1:$p/" -c"$c" -d10s -s scripts/wrk-checkout.lua
      sleep 2
      run_wrk "$fw" "mix_c${c}_r${rep}"    "http://127.0.0.1:$p/" -c"$c" -d10s -s scripts/wrk-mix.lua
      sleep 2
      run_wrk "$fw" "realistic_c${c}_r${rep}" "http://127.0.0.1:$p/" -c"$c" -d10s -s scripts/wrk-realistic.lua
      sleep 2
    done
  done
done

# Collect RSS peak per framework from telemetry jsonl
python3 scripts/collect_results.py "$RESULTS"
echo "[harness] done — see $RESULTS/bench_results.json and BENCHMARK_RESULTS.md"
