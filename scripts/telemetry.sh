#!/usr/bin/env bash
# scripts/telemetry.sh — sample CPU% and RSS of a harness container's init PID.
# Usage: telemetry.sh <container_name> <output_jsonl> <sample_interval_sec>
# Appends one JSON line per sample: {"t":epoch,"cpu_pct":x.y,"rss_kb":n}
set -u
CNAME="$1"
OUT="$2"
INTERVAL="${3:-1}"

PID=$(podman inspect -f '{{.State.Pid}}' "$CNAME" 2>/dev/null) || exit 1
[[ -n "$PID" && "$PID" != "0" ]] || exit 1

last_cpu=""
while true; do
  if ! kill -0 "$PID" 2>/dev/null; then
    exit 0
  fi
  read -r utime stime <<<"$(awk '{print $14, $15}' "/proc/$PID/stat" 2>/dev/null)"
  rss=$(awk '/VmRSS/{print $2}' "/proc/$PID/status" 2>/dev/null)
  hz=100
  now=$(date +%s.%N)
  total=$(( (utime + stime) ))
  if [[ -n "$last_cpu" ]]; then
    d=$(( total - last_cpu ))
    # interval measured by wall clock between samples
    cpu_pct=$(python3 -c "print(f'{$d / $hz / $INTERVAL * 100:.1f}')")
  else
    cpu_pct="0.0"
  fi
  last_cpu=$total
  printf '{"t":"%s","cpu_pct":"%s","rss_kb":"%s"}\n' "$now" "$cpu_pct" "${rss:-0}" >>"$OUT"
  sleep "$INTERVAL"
done
