"""Parse the GasSweep broadcast receipts into results/gas_sweep.csv and results/gas_vs_N.png.

Input : broadcast/GasSweep.s.sol/31337/run-latest.json (written by `forge script --broadcast`)
Output: results/gas_sweep.csv, results/gas_vs_N.png, and a summary table on stdout.

Payment path labels come from the Paid event in each receipt (fromSurplus field), not from the
configuration: reservation_only (fromSurplus == 0), surplus_first_write (first payment in that
contract with fromSurplus > 0), surplus_repeat (later payments with fromSurplus > 0).
"""

import csv
import json
from fractions import Fraction
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BROADCAST = ROOT / "broadcast" / "GasSweep.s.sol" / "31337" / "run-latest.json"
OUT_CSV = ROOT / "results" / "gas_sweep.csv"
OUT_PNG = ROOT / "results" / "gas_vs_N.png"

def _paid_topic() -> str:
    """topic0 of the Paid event, from the compiled ABI and `cast keccak` (installed with forge)."""
    import subprocess

    art = json.loads((ROOT / "out" / "SpendPartition.sol" / "SpendPartition.json").read_text())
    events = [e for e in art["abi"] if e.get("type") == "event" and e["name"] == "Paid"]
    if not events:
        sys.exit("Paid event not found in ABI; run `forge build` first")
    sig = "Paid(" + ",".join(i["type"] for i in events[0]["inputs"]) + ")"
    out = subprocess.run(["cast", "keccak", sig], capture_output=True, text=True, check=True)
    return out.stdout.strip()


def _hex(x) -> int:
    return int(x, 16) if isinstance(x, str) else int(x)


def _parse_address_list(arg: str) -> list[str]:
    return [a.lower() for a in re.findall(r"0x[0-9a-fA-F]{40}", arg)]


def main() -> None:
    if not BROADCAST.exists():
        sys.exit(f"missing {BROADCAST}; run ./run_gas_sweep.sh first")
    data = json.loads(BROADCAST.read_text())
    paid_topic = _paid_topic().lower()
    receipts = {r["transactionHash"].lower(): r for r in data["receipts"]}

    configs = {}  # SpendPartition address -> dict
    rows = []
    for tx in data["transactions"]:
        h = tx["hash"].lower()
        rc = receipts[h]
        if _hex(rc["status"]) != 1:
            sys.exit(f"transaction {h} reverted on chain")
        gas = _hex(rc["gasUsed"])

        if tx["transactionType"] == "CREATE" and tx.get("contractName") == "SpendPartition":
            args = tx["arguments"]
            agents = _parse_address_list(args[1])
            rho = str(Fraction(int(args[3]), int(args[4])))
            addr = tx["contractAddress"].lower()
            configs[addr] = {"n": len(agents), "rho": rho, "agents": agents, "pays": 0, "surplus_written": False}
            rows.append({"n": len(agents), "rho": rho, "event": "deploy", "payer_idx": "", "ordinal": "",
                         "from_surplus": "", "path": "deploy", "gas_used": gas, "tx_hash": h})
            continue

        to = (tx["transaction"].get("to") or "").lower()
        if tx["transactionType"] == "CALL" and to in configs and (tx.get("function") or "").startswith("pay("):
            cfg = configs[to]
            payer = tx["transaction"]["from"].lower()
            from_surplus = None
            for log in rc["logs"]:
                if log["address"].lower() == to and log["topics"][0].lower() == paid_topic:
                    word = log["data"][2:]
                    from_surplus = int(word[64:128], 16)  # data: amount, fromSurplus, windowId
            if from_surplus is None:
                sys.exit(f"no Paid event in {h}")
            if from_surplus == 0:
                path = "reservation_only"
            elif not cfg["surplus_written"]:
                path = "surplus_first_write"
                cfg["surplus_written"] = True
            else:
                path = "surplus_repeat"
            cfg["pays"] += 1
            rows.append({"n": cfg["n"], "rho": cfg["rho"], "event": "pay", "payer_idx": cfg["agents"].index(payer),
                         "ordinal": cfg["pays"], "from_surplus": from_surplus, "path": path, "gas_used": gas, "tx_hash": h})

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with OUT_CSV.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    # ---- summary table -------------------------------------------------------------
    series = {}
    for r in rows:
        key = ("deploy", r["rho"]) if r["event"] == "deploy" else (r["path"], r["rho"])
        series.setdefault(key, {}).setdefault(r["n"], []).append(r["gas_used"])
    ns = sorted({r["n"] for r in rows})
    print(f"{'series':<34}" + "".join(f"{('N=' + str(n)):>11}" for n in ns))
    for key in sorted(series):
        label = f"{key[0]} (rho={key[1]})"
        cells = []
        for n in ns:
            v = series[key].get(n)
            cells.append(f"{int(statistics.median(v)):>11}" if v else f"{'-':>11}")
        print(f"{label:<34}" + "".join(cells))
    for key in sorted(k for k in series if k[0] == "deploy"):
        xs = [n for n in ns if n in series[key]]
        ys = [statistics.median(series[key][n]) for n in xs]
        mx, my = statistics.fmean(xs), statistics.fmean(ys)
        b1 = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        print(f"deploy (rho={key[1]}): least-squares increment per registered delegate = {b1:,.1f} gas")
    print(f"\nwrote {OUT_CSV.relative_to(ROOT)}")

    # ---- figure -----------------------------------------------------------------------
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed; skipped figure")
        return

    styles = [("o", "-"), ("s", "--"), ("^", ":"), ("D", "-.")]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 3.8))
    deploy_keys = sorted(k for k in series if k[0] == "deploy")
    for (marker, ls), key in zip(styles, deploy_keys):
        pts = series[key]
        ax1.plot(ns, [statistics.median(pts[n]) / 1e6 for n in ns], marker=marker, linestyle=ls,
                 markerfacecolor="none", label=f"rho={key[1]}")
    ax1.set_xlabel("N (registered delegates)")
    ax1.set_ylabel("gasUsed, millions (receipt)")
    ax1.set_title("(a) Deployment")
    ax1.legend(frameon=False, fontsize=8)

    pay_keys = sorted(k for k in series if k[0] != "deploy")
    for (marker, ls), key in zip(styles, pay_keys):
        pts = series[key]
        xs = [n for n in ns if n in pts]
        ax2.plot(xs, [statistics.median(pts[n]) for n in xs], marker=marker, linestyle=ls,
                 markerfacecolor="none", label=f"{key[0]}, rho={key[1]}")
    ax2.set_xlabel("N (registered delegates)")
    ax2.set_ylabel("gasUsed (receipt)")
    ax2.set_title("(b) Single payment")
    ax2.legend(frameon=False, fontsize=7)

    for ax in (ax1, ax2):
        ax.set_xticks(ns)
        ax.grid(True, linewidth=0.3)
    fig.tight_layout()
    fig.savefig(OUT_PNG, dpi=160)
    print(f"wrote {OUT_PNG.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
