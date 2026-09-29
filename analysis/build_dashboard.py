"""Build results/dashboard.html from the template and the CSVs the test suite produced.

Inputs : results/demo_trace.csv, results/rho_sweep.csv, results/gas_sweep.csv
Output : results/dashboard.html, one self-contained file that opens from the file system

The data is inlined rather than fetched, so the page works by double-clicking it and can be handed
to someone else as a single attachment. Rebuild it whenever the CSVs are regenerated.
"""

import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
TEMPLATE = ROOT / "analysis" / "dashboard_template.html"
OUT = RESULTS / "dashboard.html"

SOURCES = {
    "demo": ("demo_trace.csv", "forge test --match-contract DemoTraceTest"),
    "rho": ("rho_sweep.csv", "forge test --match-contract RhoSweepTest"),
    "gas": ("gas_sweep.csv", "./run_gas_sweep.sh"),
}


def read(name: str, how: str) -> list:
    path = RESULTS / name
    if not path.exists():
        sys.exit(f"missing {path.relative_to(ROOT)} — run `{how}` first")
    with path.open() as f:
        return list(csv.DictReader(f))


def main() -> None:
    data = {key: read(name, how) for key, (name, how) in SOURCES.items()}

    env = RESULTS / "container_2026-09-30" / "env.txt"
    toolchain = ""
    if env.exists():
        lines = [ln.strip() for ln in env.read_text().splitlines()]
        toolchain = "; ".join(ln for ln in lines if ln.startswith(("forge", "Version", "evm_version")))

    data["meta"] = {
        "provenance": (
            "Every number on this page was read back from a contract call or taken from a transaction "
            "receipt. The page only displays them; none of the rules are reimplemented here."
        ),
        "footer": (
            f"demo_trace.csv, rho_sweep.csv and gas_sweep.csv, built by analysis/build_dashboard.py. {toolchain}"
        ),
    }

    html = TEMPLATE.read_text().replace("/*__DATA__*/", json.dumps(data, separators=(",", ":")))
    OUT.write_text(html)
    counts = ", ".join(f"{k}: {len(v)} rows" for k, v in data.items() if k != "meta")
    print(f"wrote {OUT.relative_to(ROOT)} ({counts}, {len(html) / 1024:.0f} kB)")


if __name__ == "__main__":
    main()
