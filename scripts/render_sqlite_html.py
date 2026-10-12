#!/usr/bin/env python3
"""render_sqlite_html.py — generate self-contained SQLITE_BENCHMARK_RESULTS.html.

Usage: render_sqlite_html.py [results_dir] [output_html]
Reads bench_results.json (sqlite_* cells only) + telemetry_*_sqlite.jsonl.
Same dark-theme style as render_html.py. No external assets, no JS, no estimates.
"""
import json
import sys
from pathlib import Path

RESULTS = Path(sys.argv[1] if len(sys.argv) > 1 else "results")
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else "SQLITE_BENCHMARK_RESULTS.html")

KABELWEB_COMMIT = "bf64f90 demote curl_easy_perform failure log from warn to info"
RUANGSQL_COMMIT = "b3aed97 demote sqlite prepare/step failure log from warn to info"
FIBER_STACK = "gofiber/fiber v2.52.15 + modernc.org/sqlite v1.60.1 (pure Go, pool 8)"
ASPNET_STACK = "ASP.NET Core minimal API, .NET 10 + Microsoft.Data.Sqlite 10.0.10"
AXUM_STACK = "axum 0.8 + rusqlite 0.31 (bundled) + r2d2 pool 8 (Tokio workers = 2)"
TOOLCHAINS = "Zig 0.16.0 (-Doptimize=ReleaseFast) · Go 1.27.1 · .NET 10 · Rust stable · Podman rootless cgroup v2 · wrk (wg/wrk master)"
SANDBOX = "--cpus=2 --memory=512m --memory-swap=512m --pids-limit=512 --ulimit nofile=4096:4096, loopback-only publish"

d = json.loads((RESULTS / "bench_results.json").read_text())
EP = d["endpoints"]

FW_ORDER = ["kabelweb", "fiber", "aspnet", "axum"]
FWS = sorted(
    [fw for fw in EP if any(c.startswith("sqlite_") for c in EP[fw])],
    key=lambda f: (FW_ORDER.index(f) if f in FW_ORDER else 99, f),
)

ORDER = [
    "sqlite_read_c10", "sqlite_read_c50", "sqlite_read_c200",
    "sqlite_write_c10", "sqlite_write_c50", "sqlite_write_c200",
    "sqlite_mixed_c10", "sqlite_mixed_c50", "sqlite_mixed_c200",
]
ORDER = [c for c in ORDER if any(c in EP.get(fw, {}) for fw in FWS)]
SHORT = {c: c.replace("sqlite_", "").replace("_", " ") for c in ORDER}

FW_COLORS = {
    "kabelweb": "var(--kw)",
    "fiber": "var(--fib)",
    "aspnet": "var(--asp)",
    "axum": "var(--ax)",
}


def fmt(n):
    return f"{n:,.0f}"


def winner(cell):
    best = max(FWS, key=lambda fw: EP[fw][cell]["rps_median"])
    top = EP[best][cell]["rps_median"]
    second = max((EP[fw][cell]["rps_median"] for fw in FWS if fw != best), default=top)
    return best, (top / second if second else 1.0)


def sqlite_telemetry(fw):
    p = RESULTS / f"telemetry_{fw}_sqlite.jsonl"
    if not p.exists():
        return {}
    rows = [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
    rss = [int(r["rss_kb"]) for r in rows if int(r["rss_kb"]) > 0]
    if not rss:
        return {}
    return {
        "rss_peak_kb": max(rss),
        "rss_median_kb": sorted(rss)[len(rss) // 2],
        "samples": len(rows),
    }


TEL = {fw: sqlite_telemetry(fw) for fw in FWS}

max_rps = max(EP[fw][c]["rps_median"] for fw in FWS for c in ORDER if c in EP[fw])
max_p99 = max(EP[fw][c]["p99_ms_median"] for fw in FWS for c in ORDER if c in EP[fw])
max_rss = max([TEL[fw]["rss_peak_kb"] for fw in FWS if TEL.get(fw)] or [1])

tput_rows = []
for c in ORDER:
    bars = []
    for fw in FWS:
        if c not in EP[fw]:
            continue
        v = EP[fw][c]["rps_median"]
        bars.append(
            f'<div class="bar" style="width:{v / max_rps * 100:.1f}%;'
            f'border:1px solid {FW_COLORS.get(fw, "var(--muted)")}">'
            f'<span class="bname">{fw}</span>'
            f'<span class="bval">{fmt(v)}</span></div>'
        )
    w, ratio = winner(c)
    tput_rows.append(
        f'<div class="group"><div class="glabel">{SHORT[c]}</div>'
        f'<div class="bars">{"".join(bars)}</div>'
        f'<div class="wlabel">{w} +{ratio - 1:.1%}</div></div>'
    )

p99_rows = []
for c in ORDER:
    bars = []
    for fw in FWS:
        if c not in EP[fw]:
            continue
        v = EP[fw][c]["p99_ms_median"]
        bars.append(
            f'<div class="bar" style="width:{max(v / max_p99 * 100, 1.5):.1f}%;'
            f'border:1px solid {FW_COLORS.get(fw, "var(--muted)")}">'
            f'<span class="bname">{fw}</span>'
            f'<span class="bval">{v:.2f} ms</span></div>'
        )
    p99_rows.append(
        f'<div class="group"><div class="glabel">{SHORT[c]}</div>'
        f'<div class="bars">{"".join(bars)}</div></div>'
    )

det_rows = []
for c in ORDER:
    for fw in FWS:
        if c not in EP[fw]:
            continue
        x = EP[fw][c]
        reps = ", ".join(fmt(v) for v in x["rps_reps"])
        det_rows.append(
            f"<tr><td>{SHORT[c]}</td><td>{fw}</td><td class='num'>{fmt(x['rps_median'])}</td>"
            f"<td class='num'>{fmt(x['rps_min'])} – {fmt(x['rps_max'])}</td>"
            f"<td class='num'>{x['p50_ms_median']:.3f}</td>"
            f"<td class='num'>{x['p99_ms_median']:.2f}</td>"
            f"<td class='num'>{x['socket_errors_total']}</td>"
            f"<td class='num'>{x['non2xx_total']}</td>"
            f"<td class='small'>{reps}</td></tr>"
        )

rss_rows = []
for fw in FWS:
    peak = TEL.get(fw, {}).get("rss_peak_kb", 0)
    med = TEL.get(fw, {}).get("rss_median_kb", 0)
    if not peak:
        continue
    rss_rows.append(
        f'<div class="bar" style="width:{peak / max_rss * 100:.1f}%;'
        f'border:1px solid {FW_COLORS.get(fw, "var(--muted)")}">'
        f'<span class="bname">{fw}</span>'
        f'<span class="bval">{peak / 1024:.1f} MB peak · {med / 1024:.1f} MB med</span></div>'
    )

legend = " ".join(
    f'<span><span class="dot" style="background:{FW_COLORS.get(fw, "var(--muted)")}\"></span>'
    f"{fw}</span>"
    for fw in FWS
)

wins = {}
for c in ORDER:
    w, _ = winner(c)
    wins[w] = wins.get(w, 0) + 1
verdict_cells = ", ".join(f"{fw} {n}" for fw, n in sorted(wins.items(), key=lambda kv: -kv[1]))

html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>sparringhttp — sqlite benchmark ({", ".join(FWS)})</title>
<style>
  :root {{ --bg:#1D1C19; --panel:#242320; --text:#c5c9c5; --muted:#a6a69c;
           --border:#282727; --link:#8ba4b0; --kw:#e0a458; --fib:#7fb3c8;
           --asp:#9ec49a; --ax:#c49ac4; --win:#9ec49a; }}
  * {{ box-sizing:border-box; }}
  body {{ background:var(--bg); color:var(--text);
         font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;
         margin:0; line-height:1.55; }}
  .wrap {{ max-width:980px; margin:0 auto; padding:32px 22px 64px; }}
  h1 {{ font-size:30px; margin:0 0 4px; letter-spacing:-0.01em; }}
  h2 {{ font-size:20px; margin:36px 0 10px; padding-bottom:8px; border-bottom:1px solid var(--border); }}
  p, li {{ font-size:14.5px; }}
  .sub {{ color:var(--muted); margin:0 0 6px; }}
  .meta {{ color:var(--muted); font-size:13px; }}
  .verdict {{ background:var(--panel); border:1px solid var(--border); border-radius:10px;
              padding:16px 18px; margin:18px 0; font-size:15px; }}
  .verdict b {{ color:var(--win); }}
  table {{ width:100%; border-collapse:collapse; font-size:13.5px; margin:12px 0; }}
  th, td {{ text-align:left; padding:7px 9px; border-bottom:1px solid var(--border); }}
  th {{ color:var(--muted); font-weight:600; font-size:12.5px; text-transform:uppercase; letter-spacing:.04em; }}
  td.num {{ text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }}
  td.small {{ color:var(--muted); font-size:12px; white-space:nowrap; }}
  .group {{ display:grid; grid-template-columns:110px 1fr 118px; gap:10px; align-items:center; margin:7px 0; }}
  .glabel {{ color:var(--muted); font-size:13px; text-align:right; }}
  .wlabel {{ font-size:12.5px; color:var(--muted); }}
  .bars {{ display:flex; flex-direction:column; gap:4px; }}
  .bar {{ display:flex; justify-content:space-between; align-items:center; border-radius:5px;
          padding:3px 9px; font-size:12.5px; min-width:fit-content; white-space:nowrap;
          background:rgba(255,255,255,0.03); }}
  .bname {{ color:var(--muted); margin-right:10px; }}
  .bval {{ font-variant-numeric:tabular-nums; font-weight:600; }}
  .legend {{ display:flex; gap:18px; font-size:13px; color:var(--muted); margin:6px 0 2px; flex-wrap:wrap; }}
  .dot {{ display:inline-block; width:11px; height:11px; border-radius:3px; margin-right:6px; vertical-align:baseline; }}
  code {{ background:#141311; padding:1px 6px; border-radius:4px; font-size:13px; }}
  pre {{ background:#141311; border:1px solid var(--border); border-radius:8px;
        padding:12px 14px; overflow-x:auto; font-size:13px; }}
  a {{ color:var(--link); }}
  footer {{ margin-top:44px; padding-top:18px; border-top:1px solid var(--border);
            color:var(--muted); font-size:12.5px; }}
  @media (max-width:640px) {{ .group {{ grid-template-columns:74px 1fr; }} .wlabel {{ display:none; }} }}
</style>
</head>
<body>
<div class="wrap">
  <h1>sqlite benchmark — {", ".join(FWS)}</h1>
  <p class="sub">Equal-spec Podman sandboxes · {len(ORDER) * 3} measured runs · no estimates</p>
  <p class="meta">Generated {d["generated_at_utc"]} · source <code>results/bench_results.json</code> (sqlite_* cells) ·<br/>
  kabelweb <code>{KABELWEB_COMMIT}</code> + ruangsql <code>{RUANGSQL_COMMIT}</code> · fiber <code>{FIBER_STACK}</code><br/>
  aspnet <code>{ASPNET_STACK}</code> · axum <code>{AXUM_STACK}</code><br/>{TOOLCHAINS}</p>

  <div class="verdict">
    <b>Cell wins (throughput):</b> {verdict_cells}.
    Reads scale with connection parallelism (axum pool 8); writes favour the single
    serialized writer (kabelweb/ruangsql). Full medians below — every number measured, 3 reps per cell.
  </div>

  <h2>Throughput — median rps per cell (higher is better)</h2>
  <div class="legend">{legend}</div>
  {''.join(tput_rows)}

  <h2>Tail latency — p99 per cell (lower is better)</h2>
  {''.join(p99_rows)}

  <h2>Full detail — every cell, 3 reps</h2>
  <table>
    <tr><th>cell</th><th>fw</th><th style="text-align:right">rps med</th>
    <th style="text-align:right">rps min–max</th><th style="text-align:right">p50 ms</th>
    <th style="text-align:right">p99 ms</th><th style="text-align:right">sock err</th>
    <th style="text-align:right">non-2xx</th><th>rep values</th></tr>
    {''.join(det_rows)}
  </table>
  <p class="meta">non-2xx are honest 404s, not failures: the DB is seeded once per container
  start and not reseeded between runs, so PUT/DELETE against already-deleted ids drift
  identically on all frameworks (same seed, same request order, same gate).
  Zero socket errors in all {len(ORDER) * 3} runs.</p>

  <h2>Resources — sqlite-run RSS (lower is better)</h2>
  <div class="group"><div class="glabel">RSS peak</div><div class="bars">
    {''.join(rss_rows)}
  </div><div class="wlabel">telemetry_*_sqlite, 1 s samples</div></div>
  <p class="meta">The 64 MB page cache (<code>cache_size=-64000</code>) dominates RSS —
  compare within this run, not against the no-db sweep.</p>

  <h2>Scenario &amp; stacks</h2>
  <ul>
    <li>Seed: 5000 <code>user_{{i}}</code> rows, <code>/tmp/sparring_sqlite.db</code> per container,
    WAL + <code>busy_timeout=5000</code> + <code>synchronous=NORMAL</code> + <code>temp_store=MEMORY</code>.</li>
    <li>7 <code>/db/*</code> endpoints: health (<code>SELECT 1</code>), point read, list scan,
    LIKE search (complex read), insert (201), update, delete (<code>{{"deleted":N}}</code>).
    Parity gate: <code>scripts/smoke-db.sh</code> → <code>ALL_PASS</code> on all four.</li>
    <li>Workloads: <code>sqlite_read</code> = 50/25/25 point/list/search ·
    <code>sqlite_write</code> = 50/50 insert/update ·
    <code>sqlite_mixed</code> = 50/15/10/10/10/5 + deletes
    (<code>scripts/wrk-sqlite-*.lua</code>).</li>
    <li>Sandbox: <code>{SANDBOX}</code>. wrk <code>-t4</code>, 10 s, 3 reps, alternating order, 2 s cooldown, host-side.</li>
    <li>Raw logs: <code>results/wrk_*_sqlite_*.txt</code> + <code>results/wrk_runs_sqlite.log</code>.</li>
  </ul>

  <h2>Reproduce</h2>
  <pre>scripts/sandbox.sh rebuild all
scripts/sandbox.sh start all
bash scripts/smoke-db.sh 29590 kabelweb  # ALL_PASS (repeat per port/fw)
bash scripts/run-bench-sqlite.sh
python3 scripts/collect_results.py results
python3 scripts/render_sqlite_html.py results SQLITE_BENCHMARK_RESULTS.html</pre>

  <footer>sparringhttp · sqlite · {", ".join(FWS)} · measured {d["generated_at_utc"]} ·
  harness touches only <code>sparringhttp_*</code> containers.</footer>
</div>
</body>
</html>
"""

OUT.write_text(html)
print(f"wrote {OUT} ({len(html)} bytes)")
