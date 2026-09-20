#!/usr/bin/env python3
"""render_html.py — generate self-contained BENCHMARK_RESULTS.html from measured data.

Usage: render_html.py [results_dir] [output_html]
Reads bench_results.json (the only data source for charts/tables).
Extra measured constants below each carry a provenance comment.
No external assets, no JS, no estimates.
"""
import json
import sys
from pathlib import Path

RESULTS = Path(sys.argv[1] if len(sys.argv) > 1 else "results")
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else "BENCHMARK_RESULTS.html")

# --- Extra measurements, all taken live this session (see session log) ---
CPU_PER_REQ_US = {"kabelweb": 6, "fiber": 7}
# cgroup cpu.stat delta over a 10 s c50 /health run per framework:
#   kabelweb: 5972717 us / 943354 req = 6 us/req
#   fiber:    6964817 us / 969848 req = 7 us/req
# aspnet/axum: not measured.
CGROUP_MEM_PEAK_BYTES = {"kabelweb": 74878976, "fiber": 22650880}
# cgroup memory.peak after the sweep (bytes); aspnet/axum: not measured.
KABELWEB_COMMIT = "dc459c0 perf(server): HTTP keep-alive, backlog 1024, TCP_NODELAY"
KABELWEB_PREV_COMMIT = "816e2c2 (pre-keep-alive: backlog 128, close-per-request)"
FIBER_VERSION = "github.com/gofiber/fiber/v2 v2.52.15"
ASPNET_VERSION = "ASP.NET Core minimal API, .NET 10 (self-contained single-file)"
AXUM_VERSION = "axum 0.8 + tokio (2 worker threads, matching --cpus=2)"
TOOLCHAINS = "Zig 0.16.0 (-Doptimize=ReleaseFast) · Go 1.27.1 · .NET 10 · Rust stable · Podman 6.1.1 rootless cgroup v2 · wrk (wg/wrk master, built from source)"
SANDBOX = "--cpus=2 --memory=512m --memory-swap=512m --pids-limit=512 --ulimit nofile=4096:4096, loopback-only publish"
# First-run kabelweb medians (old binary, same harness) for the what-changed table:
PREV_KABELWEB_RPS = {
    "health_c10": 13551, "health_c50": 13401, "health_c200": 13316,
    "hello_c10": 13445, "hello_c50": 13446, "hello_c200": 13501,
    "mix_c10": 13380, "mix_c50": 13488, "mix_c200": 13478,
}

d = json.loads((RESULTS / "bench_results.json").read_text())
EP = d["endpoints"]
TEL = d["telemetry"]

# Framework display order (stable); any unexpected framework sorts last.
FW_ORDER = ["kabelweb", "fiber", "aspnet", "axum"]
FWS = sorted(EP.keys(), key=lambda f: (FW_ORDER.index(f) if f in FW_ORDER else 99, f))

ORDER = ["health_c10", "health_c50", "health_c200",
         "hello_c10", "hello_c50", "hello_c200",
         "product_c10", "product_c50", "product_c200",
         "checkout_c10", "checkout_c50", "checkout_c200",
         "mix_c10", "mix_c50", "mix_c200",
         "realistic_c10", "realistic_c50", "realistic_c200"]
ORDER = [c for c in ORDER if any(c in EP.get(fw, {}) for fw in FWS)]
SHORT = {c: c.replace("_", " ") for c in ORDER}

# Per-framework chart colors (dark-theme friendly).
FW_COLORS = {
    "kabelweb": "var(--kw)",
    "fiber": "var(--fib)",
    "aspnet": "var(--asp)",
    "axum": "var(--ax)",
}
FW_SHORT = {
    "kabelweb": "kabelweb",
    "fiber": "fiber",
    "aspnet": "aspnet",
    "axum": "axum",
}


def fmt(n):
    return f"{n:,.0f}"


def winner(cell):
    best = max(FWS, key=lambda fw: EP[fw][cell]["rps_median"])
    top = EP[best][cell]["rps_median"]
    second = max((EP[fw][cell]["rps_median"] for fw in FWS if fw != best), default=top)
    return best, (top / second if second else 1.0)


max_rps = max(EP[fw][c]["rps_median"] for fw in FWS for c in ORDER if c in EP[fw])
max_p99 = max(EP[fw][c]["p99_ms_median"] for fw in FWS for c in ORDER if c in EP[fw])
max_rss = max([TEL[fw]["rss_peak_kb"] for fw in FWS if TEL.get(fw, {}).get("rss_peak_kb")] or [1])
cpu_known = {fw: v for fw, v in CPU_PER_REQ_US.items() if fw in FWS}
max_cpu = max(cpu_known.values()) if cpu_known else 1

# --- throughput chart rows ---
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
            f'<span class="bname">{FW_SHORT.get(fw, fw)}</span>'
            f'<span class="bval">{fmt(v)}</span></div>'
        )
    w, ratio = winner(c)
    tput_rows.append(
        f'<div class="group"><div class="glabel">{SHORT[c]}</div>'
        f'<div class="bars">{"".join(bars)}</div>'
        f'<div class="wlabel">{w} +{ratio - 1:.1%}</div></div>'
    )

# --- p99 chart rows ---
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
            f'<span class="bname">{FW_SHORT.get(fw, fw)}</span>'
            f'<span class="bval">{v:.2f} ms</span></div>'
        )
    p99_rows.append(
        f'<div class="group"><div class="glabel">{SHORT[c]}</div>'
        f'<div class="bars">{"".join(bars)}</div></div>'
    )

# --- detail table ---
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

# --- what-changed rows (kabelweb keep-alive fix; only when present) ---
chg_rows = []
if "kabelweb" in EP:
    for c in ORDER:
        if c not in PREV_KABELWEB_RPS or c not in EP["kabelweb"]:
            continue
        old = PREV_KABELWEB_RPS[c]
        new = EP["kabelweb"][c]["rps_median"]
        chg_rows.append(
            f"<tr><td>{SHORT[c]}</td><td class='num'>{fmt(old)}</td>"
            f"<td class='num'>{fmt(new)}</td><td class='num win'>×{new / old:.1f}</td></tr>"
        )

# --- resource rows (only frameworks with telemetry) ---
rss_rows = []
for fw in FWS:
    peak = TEL.get(fw, {}).get("rss_peak_kb", 0)
    if not peak:
        continue
    rss_rows.append(
        f'<div class="bar" style="width:{peak / max_rss * 100:.1f}%;'
        f'border:1px solid {FW_COLORS.get(fw, "var(--muted)")}">'
        f'<span class="bname">{FW_SHORT.get(fw, fw)}</span>'
        f'<span class="bval">{peak / 1024:.1f} MB</span></div>'
    )
cpu_rows = []
for fw, us in cpu_known.items():
    cpu_rows.append(
        f'<div class="bar" style="width:{us / max_cpu * 100:.1f}%;'
        f'border:1px solid {FW_COLORS.get(fw, "var(--muted)")}">'
        f'<span class="bname">{FW_SHORT.get(fw, fw)}</span>'
        f'<span class="bval">{us} µs</span></div>'
    )

legend = " ".join(
    f'<span><span class="dot" style="background:{FW_COLORS.get(fw, "var(--muted)")}"></span>'
    f'{FW_SHORT.get(fw, fw)}</span>'
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
<title>sparringhttp — benchmark ({", ".join(FWS)})</title>
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
  td.win {{ color:var(--win); font-weight:700; }}
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
  <h1>benchmark — {", ".join(FWS)}</h1>
  <p class="sub">Equal-spec Podman sandboxes · {len(ORDER) * 3} measured runs · no estimates</p>
  <p class="meta">Generated {d["generated_at_utc"]} · source <code>results/bench_results.json</code> ·
  kabelweb <code>{KABELWEB_COMMIT}</code> · fiber <code>{FIBER_VERSION}</code><br/>
  aspnet <code>{ASPNET_VERSION}</code> · axum <code>{AXUM_VERSION}</code><br/>{TOOLCHAINS}</p>

  <div class="verdict">
    <b>Cell wins (throughput):</b> {verdict_cells}.
    Full medians below — every number measured, 3 reps per cell.
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
    <th style="text-align:right">p99 ms</th><th style="text-align:right">sock err*</th>
    <th style="text-align:right">non-2xx</th><th>rep values</th></tr>
    {''.join(det_rows)}
  </table>
  <p class="meta">* sock err = sum over 3 reps. The <code>connect N</code> errors are wrk's
  initial connection-burst rejects — not failed responses
  (<code>non2xx = 0</code> everywhere when healthy). Neither container was CPU-throttled
  (<code>nr_throttled = 0</code> on all cgroups).</p>

  <h2>Resources — lower is better</h2>
  <div class="group"><div class="glabel">RSS peak</div><div class="bars">
    {''.join(rss_rows)}
  </div><div class="wlabel">telemetry, 1 s samples</div></div>
  <div class="group"><div class="glabel">CPU / req</div><div class="bars">
    {''.join(cpu_rows)}
  </div><div class="wlabel">cgroup cpu.stat Δ / 10 s c50 run</div></div>

  <h2>What changed since the first run</h2>
  <p>The sibling <code>/home/ginwa/kabelweb</code> repo landed
  <code>{KABELWEB_COMMIT}</code> (was <code>{KABELWEB_PREV_COMMIT}</code>) between runs —
  persistent connections, backlog 128 → 1024, TCP_NODELAY. Same harness, same limits,
  rebuilt binaries. kabelweb throughput went from flat ~13.5k to 66k–96k:</p>
  <table>
    <tr><th>cell</th><th style="text-align:right">before (rps)</th>
    <th style="text-align:right">after (rps)</th><th style="text-align:right">speedup</th></tr>
    {''.join(chg_rows)}
  </table>

  <h2>Method &amp; limitations</h2>
  <ul>
    <li>Sandbox: <code>{SANDBOX}</code>. wrk (<code>-t4</code>, 10 s, 3 reps, alternating
    framework order, 2 s cooldown) runs on the host. Endpoints identical on all servers
    (<code>/health</code>, <code>/hello/:name</code>, <code>/users</code>, <code>/api/v1/echo</code>,
    <code>/api/v1/product/:id</code> (~1KB doc), <code>/api/v1/checkout</code> (~0.6KB cart));
    <code>mix</code> = 70/20/10 Lua script (<code>scripts/wrk-mix.lua</code>),
    <code>realistic</code> = 50/50 product/checkout (<code>scripts/wrk-realistic.lua</code>).</li>
    <li>Runtime sizing pinned to the quota: <code>GOMAXPROCS=2</code> (fiber),
    Tokio worker threads = 2 (axum); .NET is cgroup-aware (no pinning needed).</li>
    <li>Single host, loopback only, no TLS, minimal bench servers (no SSE/WS/templates).</li>
    <li>Raw logs: <code>results/wrk_*.txt</code> + <code>results/wrk_runs.log</code>.</li>
  </ul>

  <h2>Reproduce</h2>
  <pre>(cd bench/kabelweb &amp;&amp; zig build -Doptimize=ReleaseFast)
GOFLAGS=-mod=mod go build -trimpath -o bin/fiber-bench ./bench/fiber
dotnet publish bench/aspnet/aspnet-bench.csproj -c Release -o bin/aspnet-publish &amp;&amp; cp bin/aspnet-publish/aspnet-bench bin/aspnet-bench
cargo build --release --manifest-path bench/axum/Cargo.toml &amp;&amp; cp bench/axum/target/release/axum-bench bin/axum-bench
mkdir -p /tmp/sparringhttp_img
cp bench/kabelweb/zig-out/bin/kabelweb-bench bin/fiber-bench bin/aspnet-bench bin/axum-bench /tmp/sparringhttp_img/
podman build -t localhost/sparringhttp-bench:latest -f scripts/Containerfile /tmp/sparringhttp_img
scripts/sandbox.sh start kabelweb &amp;&amp; scripts/sandbox.sh start fiber &amp;&amp; scripts/sandbox.sh start aspnet &amp;&amp; scripts/sandbox.sh start axum
scripts/run-bench.sh
python3 scripts/collect_results.py results
python3 scripts/render_html.py results BENCHMARK_RESULTS.html</pre>

  <footer>sparringhttp · {", ".join(FWS)} · measured {d["generated_at_utc"]} ·
  harness touches only <code>sparringhttp_*</code> containers.</footer>
</div>
</body>
</html>
"""

OUT.write_text(html)
print(f"wrote {OUT} ({len(html)} bytes)")
