#!/usr/bin/env bash
# scripts/run-bench-sqlite.sh — sqlite-backed benchmark across all 4 frameworks.
# Workloads: sqlite_read (wrk-sqlite-read.lua), sqlite_write (wrk-sqlite-write.lua),
# sqlite_mixed (wrk-sqlite-mixed.lua). Same equal-spec sandbox + methodology as
# run-bench.sh: one server under load at a time, -c 10/50/200, -t 4, 10s, 3 reps,
# alternating order, 2s cooldown. Writes results/wrk_<fw>_sqlite_* + telemetry.
set -euo pipefail
cd /home/ginwa/sparringhttp

WRK=./tools/wrk/wrk
RESULTS=results
mkdir -p "$RESULTS"
for _fw in kabelweb fiber aspnet axum; do
  : >"$RESULTS/telemetry_${_fw}_sqlite.jsonl"
done

declare -A PORT=( [kabelweb]=29590 [fiber]=29591 [aspnet]=29592 [axum]=29593 )
FWLIST=(kabelweb fiber aspnet axum)

# Poll until the server answers, instead of checking once. aspnet is
# self-contained .NET and needs a few seconds to come up after `start`;
# a single immediate probe failed the whole run on a healthy container.
# Budget is generous because the first probe can also lose to the seed
# (5 000 inserts) on a cold page cache.
READY_TIMEOUT_S=${READY_TIMEOUT_S:-90}
ready() {
  local _fw=$1 _deadline=$((SECONDS + READY_TIMEOUT_S))
  while ((SECONDS < _deadline)); do
    if curl -s -m 2 "http://127.0.0.1:${PORT[$_fw]}/db/health" | grep -q '"ok":true'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

for fw in "${FWLIST[@]}"; do
  # ALWAYS restart, never just start-if-missing. Every server re-seeds its
  # database on startup, and the correctness gate below asserts against
  # that PRISTINE seed (`/db/user/42` must still be `user_42`).
  #
  # This is load-bearing, not defensive tidiness. `smoke-db.sh` is
  # destructive: it PUTs `smoke2` onto user 42 and DELETEs a row. The
  # documented order is smoke-then-bench, so reusing a live sandbox fails
  # the gate on a perfectly good build. Reusing one also measures a
  # database that has grown by every previous run's inserts, which is not
  # comparable with the medians in SQLITE_BENCHMARK_RESULTS.md.
  echo "[sqlite-harness] restarting sandbox $fw (re-seeds the database)"
  scripts/sandbox.sh stop "$fw" >/dev/null 2>&1 || true
  scripts/sandbox.sh start "$fw" >/dev/null
  ready "$fw" || { echo "[sqlite-harness] $fw /db/health not ready"; exit 1; }
  echo "[sqlite-harness] $fw ready on :${PORT[$fw]}"
done

TEL_PIDS=()
for _fw in "${FWLIST[@]}"; do
  scripts/telemetry.sh "sparringhttp_${_fw}" "$RESULTS/telemetry_${_fw}_sqlite.jsonl" 1 &
  TEL_PIDS+=($!)
done
cleanup() {
  kill "${TEL_PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

run_wrk() {
  local fw="$1" label="$2" url="$3"; shift 3
  local out="$RESULTS/wrk_${fw}_${label}.txt"
  echo "== $fw $label $(date -Is) $*" >>"$RESULTS/wrk_runs_sqlite.log"
  timeout 40 "$WRK" -t4 "$@" --latency "$url" >"$out" 2>&1 || true
  cat "$out" >>"$RESULTS/wrk_runs_sqlite.log"
  echo >>"$RESULTS/wrk_runs_sqlite.log"
}

# Correctness gate: sqlite parity on all frameworks before measuring
for fw in "${FWLIST[@]}"; do
  p="${PORT[$fw]}"
  curl -s -m 2 "http://127.0.0.1:$p/db/health" | grep -q '"ok":true' || { echo "gate fail db/health $fw"; exit 1; }
  curl -s -m 2 "http://127.0.0.1:$p/db/user/42" | grep -q '"username":"user_42"' || { echo "gate fail db/user $fw"; exit 1; }
  curl -s -m 2 "http://127.0.0.1:$p/db/users?limit=3" | grep -q '"id":3' || { echo "gate fail db/users $fw"; exit 1; }
  curl -s -m 2 -X POST -H 'Content-Type: application/json' -d '{"username":"gate","email":"gate@bench.local"}' \
    "http://127.0.0.1:$p/db/user" | grep -q '"username":"gate"' || { echo "gate fail db/post $fw"; exit 1; }
  curl -s -m 2 -X PUT -H 'Content-Type: application/json' -d '{"username":"gate2","email":"gate2@bench.local"}' \
    "http://127.0.0.1:$p/db/user/42" | grep -q '"id":42' || { echo "gate fail db/put $fw"; exit 1; }
  curl -s -m 2 "http://127.0.0.1:$p/db/search?q=user_1&limit=3" | grep -q '"username":"user_1"' || { echo "gate fail db/search $fw"; exit 1; }
  curl -s -m 2 -X DELETE "http://127.0.0.1:$p/db/user/4998" | grep -q '"deleted":4998' || { echo "gate fail db/delete $fw"; exit 1; }
  code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/db/user/9999999")
  [[ "$code" == "404" ]] || { echo "gate fail db/404 $fw got $code"; exit 1; }
done
echo "[sqlite-harness] correctness gates passed"

for fw in "${FWLIST[@]}"; do
  timeout 10 "$WRK" -t4 -c10 -d3s "http://127.0.0.1:${PORT[$fw]}/db/health" >/dev/null 2>&1 || true
done

for rep in 1 2 3; do
  if (( rep % 2 == 1 )); then ORDER=(kabelweb fiber aspnet axum); else ORDER=(axum aspnet fiber kabelweb); fi
  for fw in "${ORDER[@]}"; do
    p="${PORT[$fw]}"
    for c in 10 50 200; do
      run_wrk "$fw" "sqlite_read_c${c}_r${rep}"  "http://127.0.0.1:$p/" -c"$c" -d10s -s scripts/wrk-sqlite-read.lua
      sleep 2
      run_wrk "$fw" "sqlite_write_c${c}_r${rep}" "http://127.0.0.1:$p/" -c"$c" -d10s -s scripts/wrk-sqlite-write.lua
      sleep 2
      run_wrk "$fw" "sqlite_mixed_c${c}_r${rep}" "http://127.0.0.1:$p/" -c"$c" -d10s -s scripts/wrk-sqlite-mixed.lua
      sleep 2
    done
  done
done

python3 scripts/collect_results.py "$RESULTS"
echo "[sqlite-harness] done — see $RESULTS/bench_results.json (filter sqlite_*) and wrk_runs_sqlite.log"
