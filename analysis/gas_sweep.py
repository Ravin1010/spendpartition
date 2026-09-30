"""Parse the GasSweep broadcast receipts into results/gas_sweep.csv and two figures.

Input : broadcast/GasSweep.s.sol/31337/run-latest.json (written by `forge script --broadcast`)
Output: results/gas_sweep.csv, results/gas_vs_N.png, results/gas_regimes.png, tables on stdout.

Labels are derived from the Paid event of each receipt, not from the configuration:

  path          reservation_only        fromSurplus == 0
                surplus_first_ever      first surplus write this contract has ever done
                surplus_first_in_window first surplus write of a window that already had one before
                surplus_same_window     a later surplus write inside the same window
  agent_regime  same_window             the payer's slot already carries the current window id
                retag_new_window        the slot carries an older window id and is retagged
"""

import csv
import json
import re
import statistics
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BROADCAST_DIR = ROOT / "broadcast" / "GasSweep.s.sol" / "31337"
OUT_CSV = ROOT / "results" / "gas_sweep.csv"
OUT_BATCH = ROOT / "results" / "batching.csv"
OUT_PNG = ROOT / "results" / "gas_vs_N.png"
OUT_PNG_REGIMES = ROOT / "results" / "gas_regimes.png"

IMPLS = {"SpendPartition": "optimized", "SpendPartitionReference": "reference"}


def _paid_topic() -> str:
    """topic0 of the Paid event, from the compiled ABI and `cast keccak` (installed with forge)."""
    art = json.loads((ROOT / "out" / "SpendPartition.sol" / "SpendPartition.json").read_text())
    events = [e for e in art["abi"] if e.get("type") == "event" and e["name"] == "Paid"]
    if not events:
        sys.exit("Paid event not found in ABI; run `forge build` first")
    sig = "Paid(" + ",".join(i["type"] for i in events[0]["inputs"]) + ")"
    out = subprocess.run(["cast", "keccak", sig], capture_output=True, text=True, check=True)
    return out.stdout.strip()


def _hex(x) -> int:
    return int(x, 16) if isinstance(x, str) else int(x)


def _addresses(arg: str) -> list:
    return [a.lower() for a in re.findall(r"0x[0-9a-fA-F]{40}", arg)]


def main() -> None:
    runs = sorted(p for p in BROADCAST_DIR.glob("run-*.json") if p.name != "run-latest.json")
    if not runs:
        sys.exit(f"no broadcast files under {BROADCAST_DIR}; run ./run_gas_sweep.sh first")
    paid_topic = _paid_topic().lower()

    transactions, receipts = [], {}
    seen = set()
    for run in runs:  # one file per forge script invocation, in chain order
        data = json.loads(run.read_text())
        for r in data["receipts"]:
            receipts[r["transactionHash"].lower()] = r
        for tx in data["transactions"]:
            if tx["hash"].lower() in seen:
                continue
            seen.add(tx["hash"].lower())
            transactions.append(tx)

    # First pass: find the batching phase. A BatchDelegate is created, and the contract it pays into
    # is measured separately, so its rows stay out of the N sweep.
    batchers = {
        tx["contractAddress"].lower()
        for tx in transactions
        if tx["transactionType"] == "CREATE" and tx.get("contractName") == "BatchDelegate"
    }
    batch_targets = set()
    for tx in transactions:
        to = (tx["transaction"].get("to") or "").lower()
        if to in batchers:
            for log in receipts[tx["hash"].lower()]["logs"]:
                if log["topics"][0].lower() == paid_topic:
                    batch_targets.add(log["address"].lower())

    configs = {}
    rows = []
    batch_rows = []
    pending = None  # the separate-transaction baseline that follows each batched transaction
    for tx in transactions:
        h = tx["hash"].lower()
        rc = receipts[h]
        if _hex(rc["status"]) != 1:
            sys.exit(f"transaction {h} reverted on chain")
        gas = _hex(rc["gasUsed"])
        name = tx.get("contractName")

        if tx["transactionType"] == "CREATE" and name in IMPLS:
            args = tx["arguments"]
            agents = _addresses(args[1])
            addr = tx["contractAddress"].lower()
            if addr in batch_targets:
                configs[addr] = {"impl": IMPLS[name], "n": len(_addresses(args[1])),
                                 "rho": str(Fraction(int(args[3]), int(args[4]))), "window_s": int(args[5]),
                                 "agents": _addresses(args[1]), "pays": 0, "surplus_window": None, "payer_window": {}}
                continue
            configs[addr] = {
                "impl": IMPLS[name],
                "n": len(agents),
                "rho": str(Fraction(int(args[3]), int(args[4]))),
                "window_s": int(args[5]),
                "agents": agents,
                "pays": 0,
                "surplus_window": None,
                "payer_window": {},
            }
            cfg = configs[addr]
            rows.append(
                {
                    "n": cfg["n"], "rho": cfg["rho"], "window_s": cfg["window_s"], "impl": cfg["impl"],
                    "event": "deploy", "payer_idx": "", "ordinal": "", "amount": "", "from_surplus": "",
                    "window_id": "", "path": "deploy", "agent_regime": "", "gas_used": gas, "tx_hash": h,
                }
            )
            continue

        to = (tx["transaction"].get("to") or "").lower()

        if tx["transactionType"] == "CALL" and to in batchers:
            paid = [l for l in rc["logs"] if l["topics"][0].lower() == paid_topic]
            target = paid[0]["address"].lower()
            cfg = configs[target]
            batch_rows.append(
                {"rho": cfg["rho"], "n": cfg["n"], "k": len(paid), "mode": "batched",
                 "transactions": 1, "total_gas": gas, "gas_per_payment": round(gas / len(paid), 1)}
            )
            pending = {"rho": cfg["rho"], "n": cfg["n"], "k": len(paid), "mode": "separate",
                       "transactions": 0, "total_gas": 0, "target": target}
            continue

        if tx["transactionType"] == "CALL" and to in batch_targets and (tx.get("function") or "").startswith("pay("):
            if pending is not None and pending["target"] == to and pending["transactions"] < pending["k"]:
                pending["transactions"] += 1
                pending["total_gas"] += gas
                if pending["transactions"] == pending["k"]:
                    pending["gas_per_payment"] = round(pending["total_gas"] / pending["k"], 1)
                    pending.pop("target")
                    batch_rows.append(pending)
                    pending = None
            continue

        if tx["transactionType"] == "CALL" and to in configs and (tx.get("function") or "").startswith("pay("):
            cfg = configs[to]
            payer = tx["transaction"]["from"].lower()
            amount = from_surplus = window_id = None
            for log in rc["logs"]:
                if log["address"].lower() == to and log["topics"][0].lower() == paid_topic:
                    word = log["data"][2:]
                    amount = int(word[0:64], 16)
                    from_surplus = int(word[64:128], 16)
                    window_id = int(word[128:192], 16)
            if from_surplus is None:
                sys.exit(f"no Paid event in {h}")

            if from_surplus == 0:
                path = "reservation_only"
            elif cfg["surplus_window"] is None:
                path = "surplus_first_ever"
            elif cfg["surplus_window"] != window_id:
                path = "surplus_first_in_window"
            else:
                path = "surplus_same_window"
            if from_surplus > 0:
                cfg["surplus_window"] = window_id

            previous = cfg["payer_window"].get(payer, 0)  # the slot is written at construction, window 0
            agent_regime = "same_window" if previous == window_id else "retag_new_window"
            cfg["payer_window"][payer] = window_id

            cfg["pays"] += 1
            rows.append(
                {
                    "n": cfg["n"], "rho": cfg["rho"], "window_s": cfg["window_s"], "impl": cfg["impl"],
                    "event": "pay", "payer_idx": cfg["agents"].index(payer), "ordinal": cfg["pays"],
                    "amount": amount, "from_surplus": from_surplus, "window_id": window_id, "path": path,
                    "agent_regime": agent_regime, "gas_used": gas, "tx_hash": h,
                }
            )

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with OUT_CSV.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    day = [r for r in rows if r["window_s"] != 1]
    optimized = [r for r in day if r["impl"] == "optimized"]

    # ---- table 1: the N sweep on the optimised implementation -------------------------
    series = {}
    for r in optimized:
        key = ("deploy", r["rho"]) if r["event"] == "deploy" else (r["path"], r["rho"])
        series.setdefault(key, {}).setdefault(r["n"], []).append(r["gas_used"])
    ns = sorted({r["n"] for r in optimized})
    print(f"{'series':<34}" + "".join(f"{('N=' + str(n)):>11}" for n in ns))
    for key in sorted(series):
        cells = "".join(
            f"{int(statistics.median(series[key][n])):>11}" if n in series[key] else f"{'-':>11}" for n in ns
        )
        print(f"{f'{key[0]} (rho={key[1]})':<34}{cells}")
    for key in sorted(k for k in series if k[0] == "deploy"):
        xs = [n for n in ns if n in series[key]]
        ys = [statistics.median(series[key][n]) for n in xs]
        mx, my = statistics.fmean(xs), statistics.fmean(ys)
        b1 = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        print(f"deploy (rho={key[1]}): least-squares increment per registered delegate = {b1:,.1f} gas")

    # ---- table 2: per-payment regimes, both implementations ---------------------------
    regimes = {}
    for r in rows:
        if r["event"] != "pay":
            continue
        regimes.setdefault((r["impl"], r["path"], r["agent_regime"]), {}).setdefault(r["n"], []).append(r["gas_used"])
    print(f"\n{'implementation':<12}{'path':<26}{'agent slot':<18}" + "".join(f"{('N=' + str(n)):>11}" for n in ns))
    for key in sorted(regimes):
        cells = "".join(
            f"{int(statistics.median(regimes[key][n])):>11}" if n in regimes[key] else f"{'-':>11}" for n in ns
        )
        print(f"{key[0]:<12}{key[1]:<26}{key[2]:<18}{cells}")

    # ---- table 3: deployment, optimised against reference -----------------------------
    print(f"\n{'deployment':<24}" + "".join(f"{('N=' + str(n)):>11}" for n in ns))
    for impl in ("optimized", "reference"):
        per_n = {}
        for r in day:
            if r["event"] == "deploy" and r["impl"] == impl:
                per_n.setdefault(r["n"], []).append(r["gas_used"])
        cells = "".join(f"{int(statistics.median(per_n[n])):>11}" if n in per_n else f"{'-':>11}" for n in ns)
        print(f"{impl:<24}{cells}")
    if batch_rows:
        with OUT_BATCH.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(batch_rows[0].keys()), lineterminator="\n")
            w.writeheader()
            w.writerows(batch_rows)
        print(f"\n{'rho':<6}{'k':>4}{'batched, 1 tx':>16}{'separate, k tx':>16}{'per payment, batched':>22}{'per payment, separate':>23}")
        by = {}
        for r in batch_rows:
            by.setdefault((r["rho"], r["k"]), {})[r["mode"]] = r
        for (rho, k) in sorted(by, key=lambda t: (t[0], t[1])):
            pair = by[(rho, k)]
            if len(pair) != 2:
                continue
            b, sep = pair["batched"], pair["separate"]
            print(f"{rho:<6}{k:>4}{b['total_gas']:>16,}{sep['total_gas']:>16,}"
                  f"{b['gas_per_payment']:>22,.1f}{sep['gas_per_payment']:>23,.1f}")

    print(f"\nwrote {OUT_CSV.relative_to(ROOT)}")

    # ---- figures ------------------------------------------------------------------------
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed; skipped figures")
        return

    styles = [("o", "-"), ("s", "--"), ("^", ":"), ("D", "-.")]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 3.8))
    deploy_keys = sorted(k for k in series if k[0] == "deploy")
    for i, key in enumerate(deploy_keys):
        marker, ls = styles[i % len(styles)]
        ax1.plot(ns, [statistics.median(series[key][n]) / 1e6 for n in ns], marker=marker, linestyle=ls,
                 markerfacecolor="none", label=f"rho={key[1]}")
    ax1.set_xlabel("N (registered delegates)")
    ax1.set_ylabel("gasUsed, millions (receipt)")
    ax1.set_title("(a) Deployment")
    ax1.legend(frameon=False, fontsize=8)

    # Payment cost depends on the path, not on rho, so panel (b) groups by path and takes the
    # median across rho. Styles are cycled rather than zipped, so no series can be dropped
    # silently when a new path label appears.
    by_path = {}
    for r in optimized:
        if r["event"] == "pay":
            by_path.setdefault(r["path"], {}).setdefault(r["n"], []).append(r["gas_used"])
    for i, path in enumerate(sorted(by_path)):
        marker, ls = styles[i % len(styles)]
        xs = [n for n in ns if n in by_path[path]]
        ax2.plot(xs, [statistics.median(by_path[path][n]) for n in xs], marker=marker, linestyle=ls,
                 markerfacecolor="none", label=path.replace("_", " "))
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

    target_n = 10
    labels, values = [], []
    for key in sorted(regimes):
        if target_n in regimes[key]:
            labels.append(f"{key[0]}\n{key[1]}, {key[2]}")
            values.append(statistics.median(regimes[key][target_n]))
    fig2, ax = plt.subplots(figsize=(9, 0.55 * len(labels) + 1.4))
    ax.barh(range(len(values)), values, color="#4c72b0")
    ax.set_yticks(range(len(labels)))
    ax.set_yticklabels(labels, fontsize=7)
    ax.invert_yaxis()
    ax.set_xlabel("gasUsed (receipt)")
    ax.set_title(f"Single payment by path, N = {target_n}")
    for i, v in enumerate(values):
        ax.text(v, i, f" {int(v):,}", va="center", fontsize=7)
    ax.grid(True, axis="x", linewidth=0.3)
    fig2.tight_layout()
    fig2.savefig(OUT_PNG_REGIMES, dpi=160)
    print(f"wrote {OUT_PNG_REGIMES.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
