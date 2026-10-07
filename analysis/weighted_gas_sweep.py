"""Validate and retain weighted sweep receipts; no plots or narrative result analysis.

--environment captures the running chain/compiler settings before broadcasting.
Default mode validates the complete matrix and observed paths before replacing weighted CSVs.
--compare FILE compares two raw CSVs excluding transaction hashes/addresses/block numbers.
"""
import argparse
import csv
import hashlib
import json
import os
import re
import statistics
import subprocess
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
RAW = RESULTS / "weighted_gas_sweep.csv"
SUMMARY = RESULTS / "weighted_gas_summary.csv"
ENV = RESULTS / "weighted_gas_environment.json"
NS = (2, 5, 10, 20, 50)
PROFILES = ("equal", "mild_skew", "high_skew", "dominant")
IMPLS = {"SpendPartition": "baseline", "SpendPartitionWeighted": "weighted_optimized",
         "SpendPartitionWeightedReference": "weighted_reference"}
PATHS = ("reservation_only_first", "reservation_only_repeat", "surplus_first", "surplus_repeat")
BUDGET, AMOUNT, WINDOW = 10**12, 10**6, 86400
MERCHANT = "0x000000000000000000000000000000000000beef"


def run(*args):
    return subprocess.check_output(args, text=True, cwd=ROOT).strip()


def number(value):
    return int(value, 16) if isinstance(value, str) and value.startswith("0x") else int(value)


def weights(n, profile):
    return [1 if profile == "equal" else (1 + i % 2 if profile == "mild_skew" else
            (i + 1 if profile == "high_skew" else (100 * n if i == n - 1 else 1))) for i in range(n)]


def environment():
    cfg = json.loads(run("forge", "config", "--json"))
    assert str(cfg["solc"]) == "0.8.30" and cfg["optimizer"] and cfg["optimizer_runs"] == 200
    assert cfg["evm_version"] == "prague" and not cfg["via_ir"]
    block = json.loads(run("cast", "rpc", "eth_getBlockByNumber", "latest", "false", "--rpc-url", os.environ["WEIGHTED_RPC"]))
    assert number(block["number"]) == 0, "chain must be fresh"
    manifest = {"forge": run("forge", "--version"), "anvil": run("anvil", "--version"),
                "solidity": json.loads((ROOT / "out/SpendPartition.sol/SpendPartition.json").read_text())["metadata"]["compiler"]["version"],
                "solc_version": "0.8.30", "evm_version": "prague", "optimizer_runs": 200,
                "optimizer": True, "via_ir": False, "genesis_timestamp": 1700000000,
                "chain_id": number(run("cast", "chain-id", "--rpc-url", os.environ["WEIGHTED_RPC"])),
                "block_gas_limit": number(block["gasLimit"]),
                "raised_local_limit": bool(os.environ.get("ANVIL_GAS_LIMIT")),
                "source_commit": run("git", "rev-parse", "HEAD"),
                "submodules": run("git", "submodule", "status"),
                "method": "separate broadcast transactions; receipt gasUsed; merchant prefunded with 1 unit",
                "profiles": {p: {str(n): weights(n, p) for n in NS} for p in PROFILES}}
    manifest["contract_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in (ROOT / "src").glob("SpendPartition*.sol")}
    ENV.write_text(json.dumps(manifest, indent=2) + "\n")


def write_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def parse():
    data = json.loads((ROOT / "broadcast/WeightedGasSweep.s.sol/31337/run-latest.json").read_text())
    env = json.loads(ENV.read_text())
    receipts = {r["transactionHash"].lower(): r for r in data["receipts"]}
    paid_topic = run("cast", "keccak", "Paid(address,address,uint256,uint256,uint48)").lower()
    transfer_topic = run("cast", "keccak", "Transfer(address,address,uint256)").lower()
    configs, rows = {}, []
    profile_ordinals = defaultdict(int)
    for tx in data["transactions"]:
        h = tx["hash"].lower()
        receipt = receipts[h]
        assert number(receipt["status"]) == 1, f"reverted transaction: {h}"
        name = tx.get("contractName")
        if tx["transactionType"] == "CREATE" and name in IMPLS:
            args = tx["arguments"]
            agents = [a.lower() for a in re.findall(r"0x[0-9a-fA-F]{40}", args[1])]
            n = len(agents)
            assert n in NS
            impl = IMPLS[name]
            if impl == "baseline":
                vector, profile, offset = [1] * n, "equal", 2
            else:
                vector = [int(v) for v in re.findall(r"\d+", args[2])]
                # At N=2 mild/high have the same vector. Preserve both distinct experiment
                # labels using the frozen broadcast order, validating each complete vector.
                index = profile_ordinals[(impl, n)]
                assert index < len(PROFILES)
                profile, offset = PROFILES[index], 3
                profile_ordinals[(impl, n)] += 1
                assert vector == weights(n, profile), f"profile/vector mismatch: {profile}: {vector}"
            assert list(map(int, args[offset:])) == [BUDGET, 1, 2, WINDOW]
            address = tx["contractAddress"].lower()
            reservation = number(run("cast", "call", address, "reservationOf(address)(uint256)", agents[-1],
                                     "--rpc-url", os.environ["WEIGHTED_RPC"]).split()[0])
            assert reservation >= 2 * AMOUNT
            cfg = {"implementation": impl, "n": n, "profile": profile,
                   "weights": json.dumps(vector, separators=(",", ":")), "rho": "1/2", "budget": BUDGET,
                   "window_s": WINDOW, "reservation": reservation, "contract_address": address}
            configs[address] = {"row": cfg, "agents": agents, "payments": 0, "used": 0, "spent": 0}
            rows.append(dict(cfg, event="deploy", path="deploy", payer_idx="", ordinal="", amount="",
                             from_surplus="", window_id="", gas_used=number(receipt["gasUsed"]), tx_hash=h,
                             block_number=number(receipt["blockNumber"]), block_gas_limit=env["block_gas_limit"],
                             raised_local_limit=env["raised_local_limit"]))
            continue
        address = (tx["transaction"].get("to") or "").lower()
        if address not in configs or not (tx.get("function") or "").startswith("pay("):
            continue
        cfg = configs[address]
        paid = [l for l in receipt["logs"] if l["address"].lower() == address and l["topics"][0].lower() == paid_topic]
        assert len(paid) == 1
        log = paid[0]
        words = log["data"][2:]
        amount, surplus, window = [int(words[i:i + 64], 16) for i in range(0, 192, 64)]
        payer = "0x" + log["topics"][1][-40:].lower()
        recipient = "0x" + log["topics"][2][-40:].lower()
        assert payer == cfg["agents"][-1] == tx["transaction"]["from"].lower() and recipient == MERCHANT
        assert amount == int(tx["arguments"][1]) and window == 0
        ordinal = cfg["payments"] + 1
        assert ordinal <= 4
        # Classify from actual surplus activity and payer history, then check the expected regime.
        path = (("reservation_only_first" if cfg["payments"] == 0 else "reservation_only_repeat")
                if surplus == 0 else ("surplus_first" if cfg["used"] == 0 else "surplus_repeat"))
        assert path == PATHS[ordinal - 1], f"unexpected path in {h}: {path}"
        expected_amount = cfg["row"]["reservation"] - cfg["spent"] + 1 if ordinal == 3 else AMOUNT
        assert amount == expected_amount and surplus == (1 if ordinal == 3 else AMOUNT if ordinal == 4 else 0)
        transfers = [l for l in receipt["logs"] if l["topics"][0].lower() == transfer_topic
                     and "0x" + l["topics"][1][-40:].lower() == address
                     and "0x" + l["topics"][2][-40:].lower() == MERCHANT]
        assert len(transfers) == 1 and number(transfers[0]["data"]) == amount
        cfg["payments"] += 1
        cfg["spent"] += amount
        cfg["used"] += surplus
        rows.append(dict(cfg["row"], event="pay", path=path, payer_idx=cfg["row"]["n"] - 1,
                         ordinal=ordinal, amount=amount, from_surplus=surplus, window_id=window,
                         gas_used=number(receipt["gasUsed"]), tx_hash=h, block_number=number(receipt["blockNumber"]),
                         block_gas_limit=env["block_gas_limit"], raised_local_limit=env["raised_local_limit"]))
    expected = {("baseline", n, "equal") for n in NS} | {
        (impl, n, p) for impl in ("weighted_optimized", "weighted_reference") for n in NS for p in PROFILES}
    assert {(c["row"]["implementation"], c["row"]["n"], c["row"]["profile"]) for c in configs.values()} == expected
    assert len(configs) == 45 and len(rows) == 225 and all(c["payments"] == 4 for c in configs.values())
    baseline_sanity(rows)
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["implementation"], row["n"], row["profile"], row["path"])].append(row)
    summary = []
    for key, values in sorted(grouped.items()):
        gas = [r["gas_used"] for r in values]
        summary.append(dict(implementation=key[0], n=key[1], profile=key[2], path=key[3], weights=values[0]["weights"],
                            amount=values[0]["amount"], from_surplus=values[0]["from_surplus"], samples=len(gas),
                            gas_min=min(gas), gas_median=statistics.median(gas), gas_max=max(gas)))
    write_csv(RAW, rows)
    write_csv(SUMMARY, summary)
    print(f"Validated 45 configurations, 45 deployments, 180 payments; wrote {RAW.name}, {SUMMARY.name}")
    print(f"Block gas limit: {env['block_gas_limit']}; raised override: {env['raised_local_limit']}")
    print(f"Maximum deployment gas: {max(r['gas_used'] for r in rows if r['event'] == 'deploy')}")


def baseline_sanity(rows):
    frozen = list(csv.DictReader((RESULTS / "container_2026-09-30/gas_sweep.csv").open()))
    checked = 0
    for row in rows:
        if row["implementation"] != "baseline" or row["path"] not in ("deploy", *PATHS[:2], "surplus_repeat"):
            continue
        matches = [r for r in frozen if int(r["n"]) == row["n"] and r["impl"] == "optimized"
                   and r["rho"] == "1/2" and r["window_s"] == str(WINDOW) and r["event"] == row["event"]
                   and (row["event"] == "deploy" or (r["payer_idx"] == str(row["payer_idx"])
                        and r["amount"] == str(AMOUNT) and r["window_id"] == "0"
                        and ((row["path"] == "surplus_repeat" and r["path"] == "surplus_same_window")
                             or (row["path"] in PATHS[:2] and r["path"] == "reservation_only"
                                 and r["ordinal"] == str(row["ordinal"])))))]
        if matches:
            expected = {int(r["gas_used"]) for r in matches}
            assert expected == {row["gas_used"]}, f"Investigate baseline discrepancy: {row}; frozen={expected}"
            checked += 1
    print(f"Baseline sanity: {checked} equivalent control rows exactly match archived receipt gas")


def compare(previous):
    first = list(csv.DictReader(Path(previous).open()))
    second = list(csv.DictReader(RAW.open()))
    ignored = {"tx_hash", "contract_address", "block_number"}
    normalize = lambda rows: [{k: v for k, v in r.items() if k not in ignored} for r in rows]
    assert normalize(first) == normalize(second), "reproduction mismatch: investigate before acceptance"
    digest = lambda rows: hashlib.sha256(json.dumps(normalize(rows), sort_keys=True).encode()).hexdigest()
    evidence = {"rows_per_run": len(first), "configurations_per_run": 45,
                "gas_used_and_observed_paths_identical": True, "excluded_fields": sorted(ignored),
                "first_normalized_sha256": digest(first), "second_normalized_sha256": digest(second),
                "first_raw_csv_sha256": hashlib.sha256(Path(previous).read_bytes()).hexdigest(),
                "second_raw_csv_sha256": hashlib.sha256(RAW.read_bytes()).hexdigest()}
    (RESULTS / "weighted_gas_reproducibility.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Reproducibility: all {len(first)} rows agree exactly, including gas_used and observed paths")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--environment", action="store_true")
    parser.add_argument("--compare")
    args = parser.parse_args()
    if args.environment:
        environment()
    elif args.compare:
        compare(args.compare)
    else:
        parse()
