#!/usr/bin/env bash
# scripts/bench-progress.sh — show run-bench.sh progress + ETA.
# Usage: scripts/bench-progress.sh
set -uo pipefail
cd /home/ginwa/sparringhttp

TOTAL=216  # 4 fw x 6 endpoints x 3 concurrencies x 3 reps
PER_RUN=12 # ~10s wrk + 2s cooldown

PID=$(pgrep -f "scripts/run-bench.sh" | head -n 1 || true)
if [[ -z "${PID:-}" ]]; then
  echo "run-bench.sh is NOT running."
  echo "last run line: $(grep '^== ' results/wrk_runs.log 2>/dev/null | tail -n 1 || echo none)"
  ls -lt results/bench_results.json 2>/dev/null || echo "no bench_results.json yet"
  exit 0
fi

START_EPOCH=$(date -d "$(ps -p "$PID" -o lstart=)" +%s)
NOW=$(date +%s)
ELAPSED=$((NOW - START_EPOCH))
DONE=$(find results -maxdepth 1 -name 'wrk_*_c*_r*.txt' -newermt "@$START_EPOCH" 2>/dev/null | wc -l)
LAST=$(grep '^== ' results/wrk_runs.log 2>/dev/null | tail -n 1 || echo "?")

# measured pace (avoid div-by-zero)
if (( DONE > 0 )); then AVG=$((ELAPSED / DONE)); else AVG=$PER_RUN; fi
# clamp crazy values (warmup/gate can skew first minute)
if (( AVG < 8 )); then AVG=8; fi
if (( AVG > 20 )); then AVG=20; fi

LEFT=$((TOTAL - DONE))
if (( LEFT < 0 )); then LEFT=0; fi
REMAIN=$((LEFT * AVG))
ETA=$(date -d "@$((NOW + REMAIN))" '+%H:%M')
PCT=$((DONE * 100 / TOTAL))

printf 'bench progress: %d/%d (%d%%)\n' "$DONE" "$TOTAL" "$PCT"
printf 'elapsed: %dm%ds | avg: %ds/run | remaining: ~%dm%ds\n' \
  $((ELAPSED/60)) $((ELAPSED%60)) "$AVG" $((REMAIN/60)) $((REMAIN%60))
printf 'started: %s | now: %s | ETA end: ~%s\n' \
  "$(date -d "@$START_EPOCH" '+%H:%M')" "$(date -d "@$NOW" '+%H:%M')" "$ETA"
echo "current: $LAST"
