# SpendPartition — implementation skeleton

One parameterised Solidity contract: a principal budget `B_G` per time window shared by `N`
registered delegates. Delegate `i` holds a reservation `r_i`; `S = B_G - R` is a shared surplus;
`rho = rhoNum / rhoDen` sets the split. `rho = 1` is a static partition, `rho = 0` a shared pool,
`0 < rho < 1` a reserved pool.

This tree covers the payment contract, the fixed-scenario and property tests, a rho sweep and a
gas sweep. It is the feasibility spike attached to the BYOP approval request, not the full build;
"Not implemented yet" at the bottom lists what the Layout v1.1 checklist still asks for.

## Source of truth

`docs/frozen/` holds the frozen documents; the code follows them and nothing else:

| File | Role |
|---|---|
| `Spec_v1.1_errata_2026-08-08.md` | semantics (window, apportionment, debit rule, invariants I1–I5) |
| `PropertyTestPlan_v1.1_2026-08-08.md` | test IDs T1–T18, hand-computed traces in Appendix A |
| `StorageLayout_v1.1_2026-08-08.md` | packed slots, hot path, constructor bounds A1–A4, hypotheses H1–H7 |

Changing behaviour means changing those documents first.

## Toolchain

Foundry 1.x (reference run: 1.8.3), solc 0.8.30, EVM version `prague`, optimizer on with 200 runs,
`via_ir` off. Dependencies: `openzeppelin-contracts` v5.7.0, `forge-std` v1.16.2. Python 3 with
`matplotlib` for the figure (the CSV is written without it).

## Setup

```bash
cd ~/Projects/spendpartition
git init -q                      # forge install needs a git repo; skip if one exists
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.7.0
forge build
```

## Tests

```bash
forge test                       # whole suite
forge test --match-contract ScenariosTest -vv
```

| File | Covers |
|---|---|
| `test/Scenarios.t.sol` | per-delegation caps exceeding the intended aggregate; a static split rejecting a request the aggregate could serve; shared-pool endpoints; T6, T7, T9, T12 (both cases), T13 (both appendix variants), T5/T11, T16, T17; constructor bounds; slot packing; G1/G2 storage-access counts |
| `test/Fuzz.t.sol` | T8 apportionment via the characterising inequality (`R * rhoDen <= B_G * rhoNum < (R + 1) * rhoDen`), T18 debit-order transition |
| `test/Invariant.t.sol` | I1, I3, I4, ghost agreement, the T2 probe (snapshot → real entry point → revert), and handler-side checks for T5, T16, T18, I2 across six configurations |
| `test/RhoSweep.t.sol` | T14 measurement, writes `results/rho_sweep.csv` |
| `test/ReferenceAnchors.t.sol` | the Appendix A traces (T6, T7, T12, T13, T5/T11, T9, T17) replayed against `SpendPartitionReference` |
| `test/Differential.t.sol` | both implementations driven through one call sequence and compared after every call, across five configurations |
| `test/Mutation.t.sol` | the four mutants in `test/mutants/` run against the named checks, with the resulting kill matrix printed |
| `test/AdversarialToken.t.sol` | tokens that call back during the transfer, revert, or return false |

Seeds and campaign sizes live in `foundry.toml`: fuzz seed `0x5eed`, fuzz runs 1000 (256 for T8),
invariant runs 64 × depth 128, `fail_on_revert = false` (a rejected payment is a valid outcome).
The invariant configurations are `(N, B_G, rho)` = (3, 100, 1/2), (5, 101, 1/4), (2, 1000, 0),
(10, 2^64−1, 3/4), (3, 100, 1), (50, 1000, 1/3).

`afterInvariant` appends one row per run to `results/invariant_coverage.csv` (accepted, accepted
with spill into surplus, rejected, rollovers) so the campaign's coverage can be checked rather than
assumed. Write the header first:

```bash
printf "n,budget,rho,accepted,accepted_with_spill,rejected,rollovers\n" > results/invariant_coverage.csv
forge test --match-contract "Invariant_"
```

## Differential harness

`src/SpendPartitionReference.sol` is a second implementation of the same spec, organised for
reading rather than for cost: state keyed by window id instead of epoch tags, a linear scan for the
agent index, R and r_i recomputed from their definitions on every call, nothing packed. Structural
choices are deliberately different so that a shared mistake has nowhere to hide.

`SpendPartition` itself is not modified and does not inherit `ISpendPartition`; leaving that file
untouched keeps its bytecode and the gas numbers above unchanged. The harness reaches both
implementations by casting their addresses to the interface.

```bash
printf "n,budget,rho,calls,accepted,rejected,rollovers,stranger_calls,out_of_range_amounts\n" > results/differential_coverage.csv
forge test --match-contract "Differential_"
```

Each handler call issues the same payment from the same caller to both implementations and compares
the success flag; on rejection it also compares the raw return data, which is meaningful because
both declare the same error signatures and therefore the same selectors. One caller in sixteen is an
address that was never registered, and one amount in eight falls outside [1, B_G], so the guard
paths are exercised too. After every call the invariant compares `currentWindowId`, `surplusUsed`,
`reservedTotal`, `surplusCap`, every agent's `spentOf`, `reservationOf` and `indexOf`, and the token
balance each implementation has paid out. Per-run counts land in
`results/differential_coverage.csv`.

To check that the harness can still fail, break the reference on purpose and rerun one
configuration: in `SpendPartitionReference.pay`, replace the `fromReservation` line with
`uint256 fromReservation = 0;` (surplus consumed before the reservation). The run reported
`rejected by both, different revert data` within one campaign. Restore the line afterwards.

## Mutation checks

`test/mutants/` holds three copies of the optimised contract, each generated from
`src/SpendPartition.sol` with one behaviour changed and the change marked by a `MUTATION` comment:

| Mutant | Change |
|---|---|
| `MutantM1DebitOrder` | the shared surplus is consumed before the delegate's own reservation |
| `MutantM2NoWindowTag` | the window tag comparison is dropped on the payment path, so stored values are used as is |
| `MutantM3PartialFill` | a payment that exceeds the remaining surplus is filled partially instead of refused |
| `MutantM4NoGuard` | the reentrancy guard is removed from the payment path |

```bash
forge test --match-contract MutationTest -vv
```

The five checks are the named properties the suite already tests, rewritten to return a boolean so
a failure is recorded rather than aborting the run. The test asserts that every check holds on the
real contract and that no mutant survives all of them, and prints the matrix:

```
check                 SpendPartition  M1  M2  M3  M4   (1 = property held)
T6 apportionment            1        1   1   0   1
T18 debit order             1        0   1   1   1
T5/T9 window reset          1        1   0   1   1
T12 ordering                1        1   1   0   1
T16 atomicity               1        1   1   0   1
R1 one call one payment     1        1   1   1   0
```

Each mutant is caught, and M1, M2 and M4 are each caught by exactly one check: drop the T18, the
T5/T9 or the R1 property and that mutant goes through the other 51 tests untouched. To see how far a
mutant is from the original, `diff src/SpendPartition.sol test/mutants/MutantM2NoWindowTag.sol`.

M4 took two attempts to catch, and the reason is worth recording. A token that calls `pay` on its own
account is refused whatever the guard does, because it was never registered as a delegate; the
attacker has to be a delegate that is itself a contract. Even then, the aggregate bound is not what
breaks: effects are committed before the transfer, so a nested payment reads the already-updated
spend and is accounted like any other, and per-window sum spend <= B_G still holds without the guard.
What the guard buys is narrower and is what R1 states: one call to the entry point performs exactly
one payment. Without it the same call emits two.

## Adversarial tokens

Layout v1.1 Part 5 assumes a standard token. `test/mocks/AdversarialTokens.sol` drops that
assumption with three tokens and one hostile delegate:

```bash
forge test --match-contract AdversarialTokenTest -vv
```

| Case | Behaviour asserted |
|---|---|
| token re-enters `pay` during the transfer | the nested call reverts with `ReentrancyGuardReentrantCall`, whether it is bubbled or swallowed |
| delegate is a contract and re-enters under its own authority | the nested call fails, exactly one `Paid` event is emitted, and the merchant balance equals the recorded spend |
| a view is read during the callback | it returns the already-updated spend, so there is no window where value is moving but the accounting has not landed |
| `transfer` reverts | the payment reverts and both raw storage slots are byte-identical to before |
| `transfer` returns false | SafeERC20 raises `SafeERC20FailedOperation` and no state moves |

## Gas sweep

```bash
./run_gas_sweep.sh               # PORT=8546 ./run_gas_sweep.sh if 8545 is taken
```

Starts a local anvil (60 accounts from the default test mnemonic, `--hardfork prague`), broadcasts
`script/GasSweep.s.sol`, then runs `analysis/gas_sweep.py`. Every deployment and every payment is
its own transaction, so each one pays real EIP-2929 cold-access costs; `gasUsed` is read from the
receipts in `broadcast/GasSweep.s.sol/31337/run-latest.json`.

Sweep: `N ∈ {2, 5, 10, 20, 50}` × `rho ∈ {0, 1/2, 1}`, `B_G = 1e12` (1,000,000 USDC at 6 decimals),
window 1 day, payments of 1e6 to a merchant whose token balance is made non-zero before the sweep.
Per configuration: deploy, prefund, three payments by delegate `N-1`, one by delegate `0`.
Payment paths are labelled from the `Paid` event's `fromSurplus` field, not from the configuration.

Outputs: `results/gas_sweep.csv`, `results/gas_vs_N.png`, and a summary table on stdout.

## Reference outputs

`results/container_2026-09-22/` holds a full run (environment in `env.txt`): 29 tests passed,
0 failed; the gas CSV, the rho sweep, the invariant coverage and the figure.

Reproduction check — payment gas and deployment gas are fixed by the bytecode and the EVM rules,
both pinned here, so a local run should match column for column:

```bash
cut -d, -f1-8 results/gas_sweep.csv > /tmp/mine.csv
cut -d, -f1-8 results/container_2026-09-22/gas_sweep.csv > /tmp/ref.csv
diff /tmp/mine.csv /tmp/ref.csv && echo "gas matches reference"
diff results/rho_sweep.csv results/container_2026-09-22/rho_sweep.csv && echo "rho sweep matches reference"
```

`tx_hash` (column 9) is excluded because it depends on chain state, not on the contract. If payment
gas matches but deployment gas is off by a few dozen, the likely cause is a different embedded
metadata hash (different dependency revisions); check the `forge install` tags first. Invariant
coverage counts are not part of the check: they depend on the fuzzer's RNG and will differ across
Foundry versions.

## Decisions this tree makes that the frozen documents do not specify

- Delegate identity is `msg.sender`; there is no relayer or signature path. Any diagram with a
  relayer in front of the contract contradicts the Layout v1.1 hot path.
- ABI: `pay(address recipient, uint256 amount)`, views `currentWindowId`, `isAgent`, `indexOf`,
  `reservationOf`, `spentOf`, `surplusUsed`, plus public immutables. Custom errors
  `InvalidConfig`, `ZeroAddress`, `DuplicateAgent`, `InvalidAmount`, `NotAgent`, `SurplusExhausted`.
- A `Paid(agent, recipient, amount, fromSurplus, windowId)` event. `AgentRegistered` is required by
  Layout v1.1 (the optimised contract keeps no agent array); `Paid` is an addition — the dashboard
  and the gas labelling both read it, and adding it after the benchmarks would move every number.
- `ReentrancyGuardTransient` rather than the storage-slot guard, so the reentrancy guard does not
  add a persistent slot to the per-payment storage accounting (H3). It needs `evm_version` at
  cancun or later, which `prague` satisfies.
- The per-delegation-cap baseline is modelled on the same code path as `rho = 1` with
  `B_G = sum of the individual caps`; each delegate then has an independent counter and `S = 0`.

## Not implemented yet

From the Layout v1.1 Part 7 checklist: H1's three surplus
`SSTORE` regimes measured separately (only first-ever and later-same-window appear here, not
first-after-rollover); H4 hybrid spill-rate interpolation; H6 Optimized vs Reference; the batched
vs unbatched appendix microbenchmark; the dashboard.

## Failure modes seen so far

- `forge install` fails outside a git repository → run `git init` first.
- Port 8545 already in use → `PORT=8546 ./run_gas_sweep.sh`.
- `matplotlib` missing → the CSV and the stdout table are still written, the figure is skipped.
- `vm.writeFile` permission errors → `fs_permissions` in `foundry.toml` must keep `./results`
  read-write.
