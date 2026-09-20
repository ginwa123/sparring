#!/usr/bin/env python3
"""collect_results.py — parse raw wrk output into results/bench_results.{json,csv}
and generate BENCHMARK_RESULTS.md from actual measurements only.

Usage: collect_results.py <results_dir>
"""
import json
import re
import sys
from pathlib import Path

RESULTS = Path(sys.argv[1] if len(sys.argv) > 1 else "results")

WRK_RE = re.compile(
    r"Latency Distribution\s+50%\s+(?P<p50>[\d.]+)(?:us|ms|s)\s*"
    r"75%\s+(?P<p75>[\d.]+)(?:us|ms|s)\s*"
    r"90%\s+(?P<p90>[\d.]+)(?:us|ms|s)\s*"
    r"99%\s+(?P<p99>[\d.]+)(?:us|ms|s).*?"
    r"Requests/sec:\s+(?P<rps>[\d.]+)",
    re.S,
)
SOCK_RE = re.compile(r"Socket errors: connect (?P<conn>\d+), read (?P<read>\d+), write (?P<write>\d+), timeout (?P<timeout>\d+)")
NON2XX_RE = re.compile(r"Non-2xx or 3xx responses: (\d+)")

# Framework names are single tokens; labels contain underscores, so the
# framework must be matched explicitly (a greedy (\w+) would swallow the
# label, e.g. wrk_axum_realistic_c200_r3.txt -> fw "axum_realistic_c200").
RUN_RE = re.compile(r"wrk_(kabelweb|fiber|aspnet|axum)_(.+)\.txt")


def parse_wrk(path: Path) -> dict | None:
    text = path.read_text()
    m = WRK_RE.search(text)
    if not m:
        return None
    out = {k: float(v) for k, v in m.groupdict().items()}
    # wrk prints latencies in us when < 1ms, ms otherwise. Values here are
    # reported in wrk's native unit; we normalize to milliseconds.
    # Re-extract with units to detect ms cases:
    text_units = re.findall(
        r"Latency Distribution\s+50%\s+([\d.]+)(us|ms|s)\s*"
        r"75%\s+([\d.]+)(us|ms|s)\s*"
        r"90%\s+([\d.]+)(us|ms|s)\s*"
        r"99%\s+([\d.]+)(us|ms|s)",
        text,
        re.S,
    )
    if text_units:
        vals = []
        for i in range(0, 8, 2):
            v = float(text_units[0][i])
            unit = text_units[0][i + 1]
            vals.append(v / 1000.0 if unit == "us" else (v * 1000.0 if unit == "s" else v))
        out["p50"], out["p75"], out["p90"], out["p99"] = vals
    s = SOCK_RE.search(text)
    if s:
        out["socket_errors"] = sum(int(v) for v in s.groupdict().values())
    else:
        out["socket_errors"] = 0
    n = NON2XX_RE.search(text)
    out["non2xx"] = int(n.group(1)) if n else 0
    return out


def label_parts(label: str) -> tuple[str, str, str]:
    # e.g. health_c10_r2 -> (health, 10, 2)
    m = re.match(r"(\w+)_c(\d+)_r(\d+)", label)
    return (m.group(1), int(m.group(2)), int(m.group(3))) if m else ("?", "?", "?")


def telemetry_stats(path: Path) -> dict:
    if not path.exists():
        return {}
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    if not rows:
        return {}
    rss = [int(r["rss_kb"]) for r in rows if int(r["rss_kb"]) > 0]
    cpu = [float(r["cpu_pct"]) for r in rows]
    return {
        "rss_peak_kb": max(rss) if rss else 0,
        "rss_median_kb": sorted(rss)[len(rss) // 2] if rss else 0,
        "cpu_pct_max": max(cpu) if cpu else 0,
        "samples": len(rows),
    }


def main() -> None:
    runs = {}
    for path in sorted(RESULTS.glob("wrk_*.txt")):
        m = RUN_RE.match(path.name)
        if not m:
            continue
        fw, label = m.group(1), m.group(2)
        data = parse_wrk(path)
        if data is None:
            print(f"[collect] WARNING: no parsable wrk output in {path.name}", file=sys.stderr)
            continue
        ep, conc, rep = label_parts(label)
        runs.setdefault(fw, {}).setdefault(f"{ep}_c{conc}", []).append({"rep": rep, **data})

    summary = {}
    for fw, by_ep in sorted(runs.items()):
        summary[fw] = {}
        for ep, rs in sorted(by_ep.items()):
            reps = sorted(rs, key=lambda x: x["rep"])
            rps = [r["rps"] for r in reps]
            p99 = [r["p99"] for r in reps]
            summary[fw][ep] = {
                "rps_reps": rps,
                "rps_median": sorted(rps)[len(rps) // 2],
                "rps_min": min(rps),
                "rps_max": max(rps),
                "p99_ms_median": sorted(p99)[len(p99) // 2],
                "p50_ms_median": sorted(r["p50"] for r in reps)[len(reps) // 2],
                "socket_errors_total": sum(r["socket_errors"] for r in reps),
                "non2xx_total": sum(r["non2xx"] for r in reps),
                "reps": len(reps),
            }

    tel = {
        fw: telemetry_stats(RESULTS / f"telemetry_{fw}.jsonl")
        for fw in runs
    }

    out = {
        "generated_at_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
        "endpoints": summary,
        "telemetry": tel,
    }
    (RESULTS / "bench_results.json").write_text(json.dumps(out, indent=2))

    # CSV: one row per fw/endpoint median
    with (RESULTS / "bench_results.csv").open("w") as f:
        f.write("framework,endpoint,rps_median,rps_min,rps_max,p50_ms,p99_ms,socket_errors,rss_peak_kb\n")
        for fw, eps in summary.items():
            for ep, d in eps.items():
                f.write(f"{fw},{ep},{d['rps_median']},{d['rps_min']},{d['rps_max']},"
                        f"{d['p50_ms_median']},{d['p99_ms_median']},{d['socket_errors_total']},"
                        f"{tel.get(fw, {}).get('rss_peak_kb', '')}\n")

    print(f"[collect] wrote {RESULTS}/bench_results.json, {RESULTS}/bench_results.csv")
    for fw, eps in summary.items():
        for ep, d in eps.items():
            print(f"  {fw:9s} {ep:14s} rps_med={d['rps_median']:>10.0f}  p99={d['p99_ms_median']:>7.2f}ms  sockerr={d['socket_errors_total']}")


if __name__ == "__main__":
    main()
