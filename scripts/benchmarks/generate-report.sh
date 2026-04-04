#!/usr/bin/env bash
set -euo pipefail

RESULTS_DIR="${RESULTS_DIR:-benchmark-results}"
REPORT="$RESULTS_DIR/benchmark-report.md"

python3 /dev/stdin "$RESULTS_DIR" "$REPORT" << 'PYEOF'
import json, sys, os, datetime
from collections import defaultdict

results_dir = sys.argv[1]
report_path = sys.argv[2]

# ── Parse resultados ──────────────────────────────
data = defaultdict(list)       # (tool, test) -> [total_ms...]
failures = defaultdict(int)    # (tool, test) -> count

input_file = os.path.join(results_dir, "all-results.jsonl")
with open(input_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        key = (r["tool"], r["test"])
        if r["exit_code"] == 0:
            data[key].append(r["total_ms"])
        else:
            failures[key] += 1

# ── Estadisticas ──────────────────────────────────
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

tests = sorted(set(t for _, t in data.keys()))
tools = ["autopilot", "maestro"]

# ── Generar reporte ───────────────────────────────
lines = []
lines.append("# Benchmark: AutoPilot vs Maestro")
lines.append("")
lines.append(f"Generated: {datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}")
lines.append("")
lines.append("## Methodology")
lines.append("")
lines.append("- 10 measured runs per tool per test (1 warm-up discarded)")
lines.append("- App terminated between runs for clean state")
lines.append("- Same simulator, same app, same session")
lines.append("- Maestro uses `runScript` for biometric (no native support)")
lines.append("")

for test in tests:
    lines.append(f"## Test: {test}")
    lines.append("")
    lines.append("| Metric | AutoPilot | Maestro | Delta |")
    lines.append("|--------|-----------|---------|-------|")

    s = {}
    for tool in tools:
        s[tool] = stats(data.get((tool, test), []))

    for metric in ["min", "avg", "max", "p95"]:
        ap = s["autopilot"][metric]
        ma = s["maestro"][metric]
        if ma > 0:
            delta_pct = ((ap - ma) / ma) * 100
            delta_str = f"{delta_pct:+.1f}%"
        else:
            delta_str = "N/A"

        # Formato: segundos con 1 decimal para legibilidad
        ap_str = f"{ap/1000:.1f}s" if ap >= 1000 else f"{ap}ms"
        ma_str = f"{ma/1000:.1f}s" if ma >= 1000 else f"{ma}ms"
        lines.append(f"| {metric.upper()} | {ap_str} | {ma_str} | {delta_str} |")

    ap_f = failures.get(("autopilot", test), 0)
    ma_f = failures.get(("maestro", test), 0)
    lines.append(f"| Runs (ok/fail) | {s['autopilot']['n']}/{ap_f} | {s['maestro']['n']}/{ma_f} | |")
    lines.append("")

# ── Resumen ───────────────────────────────────────
lines.append("## Summary")
lines.append("")

ap_total = sum(stats(data.get(("autopilot", t), []))["avg"] for t in tests)
ma_total = sum(stats(data.get(("maestro", t), []))["avg"] for t in tests)

if ap_total < ma_total:
    pct = ((ma_total - ap_total) / ma_total) * 100
    lines.append(f"**AutoPilot** was **{pct:.0f}% faster** on average ({ap_total/1000:.1f}s vs {ma_total/1000:.1f}s combined).")
elif ma_total < ap_total:
    pct = ((ap_total - ma_total) / ap_total) * 100
    lines.append(f"**Maestro** was **{pct:.0f}% faster** on average ({ma_total/1000:.1f}s vs {ap_total/1000:.1f}s combined).")
else:
    lines.append("Both tools had identical average times.")

lines.append("")
lines.append("---")
lines.append("*Benchmark ran on GitHub Actions macos-15 runner.*")

report_content = "\n".join(lines) + "\n"

# Escribir reporte markdown
with open(report_path, "w") as f:
    f.write(report_content)

# Escribir summary JSON
summary = {}
for tool in tools:
    summary[tool] = {}
    for test in tests:
        summary[tool][test] = stats(data.get((tool, test), []))
        summary[tool][test]["failures"] = failures.get((tool, test), 0)

with open(os.path.join(results_dir, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2)

# Stdout
print(report_content)
PYEOF

echo "Report: $REPORT"
