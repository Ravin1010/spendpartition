# AgentPayGuard — Technical Spec v1.1 (Semantics Frozen)

**Status.** This document supersedes v1 and is the single semantic source of truth for implementation. *Errata applied 2026-08-08 (hygiene only, no semantic change, no version bump):* explicit `ρ_den > 0`; explicit `Δ > 0` with `t₀` pinned to deployment timestamp; the remainder claim in §1.4 narrowed to per-agent apportionment. It defines state-machine semantics only: no storage packing, no Solidity, no new features. Work order: semantics (this document) → property tests → storage layout → implementation.

---

## 1. Model

### 1.1 Units

All amounts are non-negative integers denominated in the token's smallest unit. There is no fractional arithmetic anywhere in the semantics.

### 1.2 Budget Window

A **budget window** is a half-open interval of length `Δ`, with `Δ > 0`. Window identity is derived from time, not from an explicit rollover call:

```
currentWindowId = (blockTimestamp − t₀) / Δ        // integer division
```

`t₀` is fixed to the deployment `block.timestamp`. Because `block.timestamp` is non-decreasing, `blockTimestamp ≥ t₀` always holds and the subtraction can never underflow. There is consequently no pre-start regime and no semantics to define for `blockTimestamp < t₀`.

All spending state is scoped to exactly one window. There is no carry-over of unused capacity, no lease outliving a window, and therefore no cross-window conservation condition.

### 1.3 Window Configuration (immutable within a window)

| Symbol | Meaning | Constraint |
|---|---|---|
| `B_G` | Total spendable by all agents within the window | `B_G > 0`, integer |
| `N` | Number of delegated agents | `N ≥ 1` |
| `idx(i)` | Agent `i`'s index in the registered agent list | `0 ≤ idx(i) < N`, stable |
| `ρ` | Reservation ratio, as a rational `ρ_num / ρ_den` | `ρ_den > 0`; `0 ≤ ρ_num ≤ ρ_den`; both integers |
| `w_i` | Reservation weight | `w_i ≥ 0`, `Σ w_i = 1` |

**Immutability rule.** The agent set, `N`, `B_G`, `ρ`, and all `w_i` are immutable for the entire duration of a window. Adding an agent, removing an agent, changing a weight, changing `ρ`, or changing the total budget takes effect only from the *next* window. Reservations are never recomputed mid-window.

*MVP realization:* the contract is deployed once per configuration and the benchmark harness varies configurations across deployments. This trivially satisfies the immutability rule; no in-place mutation path is implemented.

### 1.4 Derived Quantities

```
R   = (B_G · ρ_num) / ρ_den          // integer division; reservedTotal
S   = B_G − R                         // shared surplus
```

Equal-weight apportionment (`w_i = 1/N`, the main experimental setting):

```
base = R / N                          // integer division
rem  = R mod N
r_i  = base + 1   if idx(i) < rem
     = base       otherwise
```

**Apportionment properties.**

- `Σ r_i = N·base + rem = R` exactly.
- `|r_i − r_j| ≤ 1` smallest unit for all `i, j`.
- `ρ_num = ρ_den` ⟹ `R = B_G` ⟹ `S = 0` ⟹ **exact Static Partition**.
- `ρ_num = 0` ⟹ `R = 0` ⟹ all `r_i = 0`, `S = B_G` ⟹ **exact Shared Global Pool**.

**Remainder claim (precise).** No *per-agent apportionment* remainder is lost: `Σ r_i = R` exactly, and `S = B_G − R` after the single integer quantization of `reservedTotal`. The quantization in `R = floor(B_G · ρ_num / ρ_den)` is itself a smallest-unit rounding, and its residue does fall into `S`; what the apportionment step guarantees is that splitting `R` across `N` agents loses nothing further.

`r_i` and `S` are derived on demand from immutable configuration; they are not stored per window.

*Heterogeneous weights:* out of scope for the MVP. If later introduced, use largest-remainder (Hamilton) apportionment so that `Σ r_i = R` is preserved. Stretch goal only.

### 1.5 Mutable State (epoch-tagged)

Two record kinds, each carrying the window it belongs to:

- Global surplus record: `(windowId_S, surplusUsed)`
- Per-agent record, one per agent: `(windowId_i, spent_i)`

**Effective value (read path).** For every record, the value observed by any logic — including all `view` and `external` read functions — is:

```
effective(X) = X.value   if X.windowId == currentWindowId
             = 0         otherwise
```

Read functions MUST return effective current-window values. Raw physical storage from a stale window MUST NOT be observable through any public interface.

**Lazy reset (write path).** On the first state-changing access to a record in a new window, that record alone is retagged to `currentWindowId` and its counter set to `0` before the delta is applied. This is `O(1)` per record touched. There is no global rollover operation, and no code path iterates over the `N` agents to perform rollover. A given agent's record may remain stale for arbitrarily many windows; it is reset on that agent's next payment.

---

## 2. Payment Debit Rule

Agent `i` requests amount `a > 0` in the current window. Let `spent_i` and `surplusUsed` denote **effective** values per §1.5.

```
ownRemaining    = max(0, r_i − spent_i)
fromReservation = min(a, ownRemaining)
fromSurplus     = a − fromReservation

require(surplusUsed + fromSurplus ≤ S)      // budget check; else revert

spent_i     += a
surplusUsed += fromSurplus
```

Reservation is consumed strictly before surplus. No agent may draw on another agent's unused reservation. There is no borrowing, no recall, and no reclaim within a window.

**Revert atomicity.** If the budget check fails, the call reverts and no state is modified — neither `spent_i` nor `surplusUsed`, and no transfer occurs. Lazy retagging performed earlier in the same call is reverted along with everything else.

---

## 3. Invariants

All quantities below are effective current-window values.

- **I1 — Aggregate Safety.** `Σ spent_i ≤ B_G` at all times within a window.
  *Proof:* `Σ spent_i = Σ[min(spent_i, r_i) + max(0, spent_i − r_i)] ≤ Σ r_i + surplusUsed = R + surplusUsed ≤ R + S = B_G`.

- **I2 — Budget-Layer Isolation (rejection independence).** Fix agent `i` and a request of amount `a ≤ r_i − spent_i` in window `W`. Assume the request has already passed agent `i`'s own local authorization, the principal's asset balance is sufficient, and the underlying transfer itself does not fail. Then for **every** history `H` of budget-accepted operations by agents `j ≠ i` within `W`, the AgentPayGuard budget check accepts the request.
  *Proof:* `a ≤ r_i − spent_i` gives `fromSurplus = 0`, so the guard reduces to `surplusUsed ≤ S`, which holds by I3 independently of `H`.
  *Scope note:* this is a statement about the budget layer only. AgentPayGuard does not and cannot promise that the end-to-end payment succeeds.

- **I3 — Surplus Conservation.** `surplusUsed ≤ S`.

- **I4 — Accounting Consistency.** `surplusUsed = Σ max(0, spent_i − r_i)`.

- **I5 — Window Isolation.** At the first observation in any window, every effective `spent_i` and `surplusUsed` is `0`, regardless of physical storage contents.

---

## 4. Design Space

`ρ` is the single knob spanning three operating points on one code path:

- `ρ = 1` → `S = 0`, `r_i = B_G/N ± 1` — **Static Partition.** Maximum isolation; unused `r_i` is stranded for the window. I2 is maximally strong.
- `ρ = 0` → `r_i = 0`, `S = B_G` — **Shared Global Pool.** Maximum work conservation; any agent may exhaust capacity others need. **I2 holds vacuously** (its antecedent `a ≤ r_i − spent_i = 0` is never satisfiable for `a > 0`), which is the formal statement that this configuration provides no isolation.
- `0 < ρ < 1` — **Hybrid Reserved Pool** (classically, *sharing with minimum allocation*): protected floor plus contested surplus.

Because all three are the same code path under different parameters, gas and failure comparisons are apples-to-apples by construction.

---

## 5. Explicit Non-Goals

**No borrowing of protected reservation, and no recall.** Precise statement for the report and for Q&A:

> In a fixed-budget, unbacked model, once agent B has consumed capacity nominally protected for agent A and the value transfer has completed, the system cannot unconditionally guarantee A later access to that same capacity without introducing additional backing — escrow, collateral, external credit or top-up, or a clawback-capable asset. Our design choice is therefore not to lend protected reservation. This is a statement about this model, not a claim that payment systems can never support recall.

**No reclaim inside a window.** Would require a two-level time model (window plus lease lifetime) and a cross-window conservation invariant, adding state complexity without changing the trade-off being measured.

**No cross-window carry-over.** Keeps I5 trivial.

**Also excluded:** token bucket / sliding window, x402 or AP2 or ERC-8004 integration, full ERC-7710 integration, multi-chain, ZK/FHE, LLM agents, MPC wallets, dispute arbitration.

---

## 6. Evaluation Definitions

- **Service ratio.** For agents with `demand_i > 0`: `x_i = granted_i / demanded_i`.
- **Fairness.** Jain index over `{x_i}` for agents with `demand_i > 0`: `J = (Σ x_i)² / (n · Σ x_i²)`, `n` = count of such agents. Valid only under equal priority; with heterogeneous `w_i`, switch to a weight-normalized measure, otherwise deliberate prioritization is scored as unfairness.
- **Utilization.** `Σ spent_i / B_G` at window end.
- **Stranded capacity.** `B_G − Σ spent_i` given aggregate demand `≥ B_G`.
- **Starvation rate.** Fraction of honest agents' legitimate requests rejected by the budget layer under adversarial ordering.
- **Cost.** Gas per redemption; distinct storage slots as a function of `N`.

*Deferred to the evaluation plan, not the proposal:* EIP-2929 cold/warm behaviour. Absent an EIP-2930 access list, the first access to a slot is cold in each separate transaction; subsequent accesses within the same batched transaction are warm. Access-list cases are reported separately if measured at all. Microbenchmark, not a central contribution.

---

## 7. Open Items

None. Semantics are frozen at v1.1. Any further change requires an explicit version bump and a re-run of the property-test plan.
