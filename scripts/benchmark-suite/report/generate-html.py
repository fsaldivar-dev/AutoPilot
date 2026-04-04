#!/usr/bin/env python3
"""Generate HTML benchmark report from JSONL results + evidence screenshots."""
import json, sys, os, glob, datetime, base64
from collections import defaultdict

results_file = sys.argv[1] if len(sys.argv) > 1 else "benchmark-results/all-results.jsonl"
evidence_dir = sys.argv[2] if len(sys.argv) > 2 else "evidence"
output_file = sys.argv[3] if len(sys.argv) > 3 else "benchmark-results/benchmark-report.html"

# Parse results
data = defaultdict(list)
failures = defaultdict(int)

with open(results_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        r = json.loads(line)
        key = (r["tool"], r["test"])
        if r["exit_code"] == 0:
            data[key].append(r["total_ms"])
        else:
            failures[key] += 1

def stats(values):
    if not values:
        return {"min": 0, "avg": 0, "max": 0, "p95": 0, "n": 0}
    values = sorted(values)
    n = len(values)
    p95_idx = min(int(n * 0.95), n - 1)
    return {
        "min": values[0],
        "avg": int(sum(values) / n),
        "max": values[-1],
        "p95": values[p95_idx],
        "n": n
    }

def fmt_ms(ms):
    if ms == 0: return "N/A"
    if ms >= 1000: return f"{ms/1000:.1f}s"
    return f"{ms}ms"

def img_to_base64(path):
    if not os.path.exists(path): return None
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()

tests = sorted(set(t for _, t in data.keys()))
tools = ["autopilot", "maestro", "wda"]
tool_colors = {"autopilot": "#FF6B6B", "maestro": "#4ECDC4", "wda": "#9B59B6"}
tool_labels = {"autopilot": "AutoPilot", "maestro": "Maestro", "wda": "WDA"}

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Find screenshots
screenshots = defaultdict(lambda: defaultdict(list))
for f in sorted(glob.glob(os.path.join(evidence_dir, "*.png"))):
    name = os.path.basename(f)
    parts = name.replace(".png", "").split("-")
    if len(parts) >= 3:
        tool = parts[0]
        test = parts[1]
        screenshots[test][tool].append(f)

# Build HTML
html = []
html.append(f"""<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>Benchmark: AutoPilot vs Maestro vs WDA</title>
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{ font: 14px/1.6 -apple-system, system-ui, sans-serif; background: #0f0f1a; color: #e0e0e0; padding: 40px; }}
  h1 {{ font-size: 28px; margin-bottom: 8px; color: #fff; }}
  h2 {{ font-size: 20px; margin: 32px 0 16px; color: #fff; }}
  h3 {{ font-size: 16px; margin: 24px 0 12px; color: #ccc; }}
  .subtitle {{ color: #888; margin-bottom: 32px; }}
  .callout {{ background: #1a1a2e; border-left: 4px solid #f39c12; padding: 12px 16px; margin: 16px 0; border-radius: 4px; }}
  table {{ width: 100%; border-collapse: collapse; margin: 16px 0; }}
  th {{ background: #1a1a2e; padding: 10px 12px; text-align: left; font-weight: 600; border-bottom: 2px solid #333; }}
  td {{ padding: 10px 12px; border-bottom: 1px solid #222; }}
  .winner {{ background: rgba(46, 204, 113, 0.15); font-weight: bold; }}
  .na {{ color: #666; font-style: italic; }}
  .tool-badge {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; color: #fff; }}
  .screenshots {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 16px; margin: 16px 0; }}
  .screenshot-card {{ background: #1a1a2e; border-radius: 8px; overflow: hidden; }}
  .screenshot-card img {{ width: 100%; height: auto; }}
  .screenshot-card .label {{ padding: 8px 12px; font-size: 12px; color: #aaa; }}
  .summary {{ background: #1a1a2e; border-radius: 8px; padding: 20px; margin: 24px 0; }}
  .summary strong {{ color: #2ecc71; }}
</style>
</head><body>
<h1>Benchmark Suite</h1>
<p class="subtitle">AutoPilot vs Maestro vs WDA &mdash; {now}</p>
""")

# Summary table per test
for test in tests:
    html.append(f"<h2>Test: {test}</h2>")

    test_tools = tools if test != "biometric" else ["autopilot", "wda"]

    if test == "biometric":
        html.append('<div class="callout">Maestro no soporta biometric nativo. Su sandbox JS no permite ejecutar comandos del sistema (xcrun simctl). <a href="https://github.com/mobile-dev-inc/maestro/issues/1075" style="color:#3498db">#1075</a></div>')

    html.append("<table><tr><th>Metric</th>")
    for tool in test_tools:
        color = tool_colors[tool]
        html.append(f'<th><span class="tool-badge" style="background:{color}">{tool_labels[tool]}</span></th>')
    html.append("</tr>")

    s = {}
    for tool in test_tools:
        s[tool] = stats(data.get((tool, test), []))

    # Find winner (lowest avg with at least 1 run)
    valid = {t: s[t]["avg"] for t in test_tools if s[t]["n"] > 0}
    winner = min(valid, key=valid.get) if valid else None

    for metric in ["min", "avg", "max", "p95"]:
        html.append(f"<tr><td>{metric.upper()}</td>")
        for tool in test_tools:
            val = s[tool][metric]
            cls = ' class="winner"' if tool == winner else ''
            if s[tool]["n"] == 0:
                html.append(f'<td class="na">N/A (failed)</td>')
            else:
                html.append(f"<td{cls}>{fmt_ms(val)}</td>")
        html.append("</tr>")

    # Runs row
    html.append("<tr><td>Runs (ok/fail)</td>")
    for tool in test_tools:
        ok = s[tool]["n"]
        fail = failures.get((tool, test), 0)
        html.append(f"<td>{ok}/{fail}</td>")
    html.append("</tr></table>")

    # Screenshots
    if any(screenshots[test].get(t) for t in test_tools):
        html.append("<h3>Evidence</h3><div class='screenshots'>")
        max_steps = max(len(screenshots[test].get(t, [])) for t in test_tools)
        for step in range(max_steps):
            for tool in test_tools:
                imgs = screenshots[test].get(tool, [])
                if step < len(imgs):
                    b64 = img_to_base64(imgs[step])
                    if b64:
                        name = os.path.basename(imgs[step])
                        color = tool_colors[tool]
                        html.append(f'<div class="screenshot-card"><img src="data:image/png;base64,{b64}"/><div class="label"><span class="tool-badge" style="background:{color}">{tool_labels[tool]}</span> {name}</div></div>')
        html.append("</div>")

# Overall summary
html.append('<div class="summary"><h2>Summary</h2>')
for test in tests:
    test_tools = tools if test != "biometric" else ["autopilot", "wda"]
    valid = {t: stats(data.get((t, test), []))["avg"] for t in test_tools if stats(data.get((t, test), []))["n"] > 0}
    if valid:
        winner = min(valid, key=valid.get)
        winner_ms = valid[winner]
        others = {t: v for t, v in valid.items() if t != winner}
        comparisons = []
        for t, v in others.items():
            if winner_ms > 0:
                speedup = v / winner_ms
                comparisons.append(f"{speedup:.1f}x vs {tool_labels[t]}")
        html.append(f"<p><strong>{tool_labels[winner]}</strong> wins <strong>{test}</strong> ({fmt_ms(winner_ms)} avg) &mdash; {', '.join(comparisons)}</p>")
html.append("</div>")

html.append("</body></html>")

os.makedirs(os.path.dirname(output_file), exist_ok=True)
with open(output_file, "w") as f:
    f.write("\n".join(html))

print(f"Report: {output_file}")
