#!/usr/bin/env bash
# scripts/bench-host-sqlite.sh — host-level (no container) sqlite iteration loop.
# NOT a replacement for the equal-spec sandbox sweep; used ONLY to measure
# relative deltas of ruangsql changes quickly. Same workloads as the sandbox
# sweep. Usage: bench-host-sqlite.sh [bin] [c] [dur] [reps]
set -uo pipefail
cd /home/ginwa/sparringhttp
BIN="${1:-bench/kabelweb/zig-out/bin/kabelweb-bench}"
C="${2:-50}"
DUR="${3:-10s}"
REPS="${4:-3}"
WRK=./tools/wrk/wrk
PORT=29590
DB=/tmp/sparring_sqlite.db

pkill -x kabelweb-bench 2>/dev/null; sleep 1
rm -f "$DB" "$DB-wal" "$DB-shm"

"$BIN" >/tmp/host-bench-server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 40); do
  curl -s -m 1 "http://127.0.0.1:$PORT/db/health" | grep -q '"ok":true' && break
  sleep 0.25
done
curl -s -m 2 "http://127.0.0.1:$PORT/db/health" | grep -q '"ok":true' || { echo "server not ready"; cat /tmp/host-bench-server.log; exit 1; }

row() { # label lua
  local label="$1" lua="$2" rps_vals=() p99_vals=()
  for _ in $(seq 1 "$REPS"); do
    local out; out=$("$WRK" -t4 -c"$C" -d"$DUR" --latency -s "$lua" "http://127.0.0.1:$PORT/" 2>&1)
    rps_vals+=("$(awk '/Requests\/sec:/{printf "%.0f", $2}' <<<"$out")")
    p99_vals+=("$(awk '/^ *99%/{print $2}' <<<"$out")")
    sleep 1
  done
  local rps_sorted; rps_sorted=$(printf '%s\n' "${rps_vals[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  printf '%-14s c%-4s rps_med=%-9s reps=[%s] p99=[%s]ms\n' "$label" "$C" "$rps_sorted" "$(IFS=,; echo "${rps_vals[*]}")" "$(IFS=,; echo "${p99_vals[*]}")"
}

row sqlite_read  scripts/wrk-sqlite-read.lua
row sqlite_write scripts/wrk-sqlite-write.lua
row sqlite_mixed scripts/wrk-sqlite-mixed.lua

kill $SRV 2>/dev/null; sleep 1
