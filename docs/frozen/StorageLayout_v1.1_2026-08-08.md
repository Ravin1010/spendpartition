# AgentPayGuard — Storage Layout Design v1.1 (Implementation Freeze)

**Basis.** Spec v1.1 (with 2026-08-08 errata) and Property-Test Plan v1.1. This is an implementation-level freeze: no Spec semantics change, no feature-scope reopening, no complete Solidity.

**Changes from v1.** `windowId` widened to `uint48` with `B_G` narrowed to `uint192` (v1's A2 claim "implied by A4" was simply wrong — `ρ_den` has no relation to window identity). H3 rewritten to distinguish logical, materialized, and touched storage. H6 rewritten by scenario. H1 made directional rather than a fixed gas range. H5 demoted to appendix microbenchmark with no production batch API. H7 added. The `a ≤ B_G` proof reordered. Open questions resolved.

**Resolved decisions (previously open).**
1. The Reference implementation stays in the repo as a **differential test fixture only** — never deployed, never behind the dashboard, never in the demo. It is an independent, plain implementation and **must not share any debit or state-transition helper with the Optimized contract**; a shared helper reproduces its own bug in both and yields common-mode confidence.
2. Reference keeps the `_agents` array for inspection. Optimized drops it; the constructor emits `AgentRegistered(address agent, uint256 idx)` and the dashboard recovers enumeration from deployment logs.
3. `ρ_den` implementation range fixed at `0 < ρ_den ≤ 2^32 − 1`, with constructor-enforced bounded multiplication. No `mulDiv` dependency.

**Governing fact.** Every deployment has a permanently fixed configuration. `B_G`, `N`, `ρ_num`, `ρ_den`, `Δ`, `t₀`, the token, and the agent set never change; `R`, `S`, `base`, `rem` are computed once in the constructor. The hot path performs zero `mulDiv` and zero configuration `SLOAD`s.

---

## Part 1 — Reference Storage Layout (differential fixture)

Optimized for obvious correspondence to the spec. No packing, no width narrowing, no cleverness. Correctness is argued by inspection.

### 1.1 Configuration (`immutable`)

`B_G`, `N`, `rhoNum`, `rhoDen`, `windowDuration` (`Δ`), `startTime` (`t₀`), `token`, and the derived `R`, `S`, `base`, `rem` — all `uint256 immutable` (or `IERC20 immutable`).

`immutable` values are inlined into runtime bytecode and read with a `PUSH` (≈3 gas) rather than a cold `SLOAD` (2100). This removes every configuration read from the payment path and is available only because configuration is fixed per deployment.

### 1.2 Mutable state

```
struct SurplusRecord { uint256 windowId; uint256 used; }
SurplusRecord private _surplus;                       // 2 slots

struct AgentRecord  { uint256 indexPlusOne; uint256 windowId; uint256 spent; }
mapping(address => AgentRecord) private _agentState;  // 3 slots per agent

address[] private _agents;                            // inspection only, never on the payment path
```

### 1.3 Derived, never stored

`r_i`, `ownRemaining`, `fromReservation`, `fromSurplus`, `currentWindowId`, and every effective (window-masked) value. `r_i = base + (idx < rem ? 1 : 0)` — two immutable reads and a comparison.

---

## Part 2 — Optimized Storage Layout

### 2.1 Packed slots

```
struct AgentSlot {          // 256 bits exactly
    uint16  indexPlusOne;   //  16
    uint48  windowId;       //  48
    uint192 spent;          // 192
}
mapping(address => AgentSlot) private _agentState;    // 1 slot per agent

struct SurplusSlot {        // 256 bits exactly
    uint48  windowId;       //  48
    uint208 used;           // 208
}
SurplusSlot private _surplus;                         // 1 slot total
```

The registry is folded into `AgentSlot`: one `keccak` yields membership, index, window tag, and spent counter together. No separate `_indexPlusOne` mapping. No `_agents` array — enumeration comes from `AgentRegistered` events.

### 2.2 Maximum-value assumptions (constructor-enforced)

| # | Assumption | Enforcement | Headroom |
|---|---|---|---|
| A1 | `1 ≤ N ≤ 2^16 − 1` | `require` | Benchmark max `N = 50`; 1310× margin. |
| A2 | `windowId ≤ 2^48 − 1` | `SafeCast` at every derivation of `currentWindowId` | At `Δ = 1 second`, 2^48 windows ≈ **8.9 million years**. No artificial century-scale horizon, and no dependence on any other assumption. |
| A3 | `0 < B_G ≤ 2^192 − 1` | `require` | ≈6.3×10^57. An 18-decimal token with 10^12 supply is 10^30 smallest units — margin ≈6×10^27. |
| A4 | `0 < ρ_den ≤ 2^32 − 1`, `ρ_num ≤ ρ_den` | `require` | Basis points (10^4) and ppm (10^6) sit far below. |

A2 is now enforced directly and independently. It is **not** implied by A4; v1 claimed otherwise and was wrong.

`spent_i ≤ B_G ≤ 2^192 − 1` by I1, so `uint192` cannot overflow. `used ≤ S ≤ B_G < 2^208 − 1`, so `uint208` is deliberately wider than required, absorbing what would otherwise be padding.

`currentWindowId` must be produced through an explicit checked cast. Since `Δ ≥ 1`, `windowId ≤ block.timestamp − t₀`, so exceeding `uint48` requires a timestamp past year ≈8.9 million. The cast will never fire in practice and fails closed if it ever does.

### 2.3 Why the packing does not break T17

Add one guard at the top of the payment path:

```
require(a > 0 && a <= B_G);
```

**This is semantics-preserving.** Proof, in order:

1. `fromReservation ≤ r_i` by definition (`fromReservation = min(a, ownRemaining)` and `ownRemaining ≤ r_i`).
2. Suppose `a > B_G`. Then `fromSurplus = a − fromReservation ≥ a − r_i > B_G − r_i`.
3. `r_i ≤ R`, therefore `B_G − r_i ≥ B_G − R = S`.
4. Combining (2) and (3): `fromSurplus > S`.
5. Therefore `surplusUsed + fromSurplus ≥ fromSurplus > S`.
6. Therefore the Spec §2 guard `surplusUsed + fromSurplus ≤ S` fails, and the payment is rejected.

Every `a > B_G` is already rejected by the frozen semantics. The `require` changes no accept/reject outcome — only the reason and the stage of rejection.

Consequences: `a ≤ B_G ≤ 2^192 − 1`, so `spent_i + a ≤ B_G` on any accepted path and the `uint192` downcast is provably lossless; `surplusUsed + fromSurplus ≤ B_G < 2^208` cannot wrap; `a = type(uint256).max` reverts on a named check rather than incidentally inside checked arithmetic; `a = 0` is rejected by the same guard. All downcasts remain explicit `SafeCast`, so a future change to A3 fails loudly instead of silently truncating.

### 2.4 Constructor product bound

`B_G · ρ_num ≤ (2^192 − 1)(2^32 − 1) < 2^224 < 2^256`. Naive bounded multiplication is provably safe; no `mulDiv` needed. `base = R / N` and `rem = R % N` operate on values `≤ B_G` and cannot overflow.

---

## Part 3 — Hot-Path State Transition

```
pay(recipient, a):

  1.  require(a > 0 && a <= B_G)                       // immutables only
  2.  slot = _agentState[msg.sender]                   // 1 cold SLOAD
  3.  require(slot.indexPlusOne != 0)                  // membership
  4.  idx = slot.indexPlusOne − 1
  5.  w   = SafeCast.toUint48((block.timestamp − t₀) / Δ)
  6.  spent_eff = (slot.windowId == w) ? slot.spent : 0     // Spec §1.5
  7.  r_i = base + (idx < rem ? 1 : 0)                 // immutables only, O(1)
  8.  ownRem  = r_i > spent_eff ? r_i − spent_eff : 0
  9.  fromRes = a < ownRem ? a : ownRem
  10. fromSur = a − fromRes

  11. if (fromSur > 0):                                // G2
        sslot    = _surplus                            // 1 cold SLOAD
        used_eff = (sslot.windowId == w) ? sslot.used : 0
        require(used_eff + fromSur <= S)               // budget guard
        _surplus = SurplusSlot(w, used_eff + fromSur)  // 1 SSTORE — G1

  12. _agentState[msg.sender] = AgentSlot(idx+1, w, spent_eff + a)   // 1 SSTORE

  13. token.safeTransfer(recipient, a)                 // interaction, last
```

**Rule G1 — deferred global retag.** The surplus record is written only when `fromSurplus > 0`. Effective semantics depend only on `(windowId, used)` read through the mask of Spec §1.5, so leaving a stale pair untouched preserves `effective = 0` for the current window. The next surplus-consuming payment finds it stale, treats it as `0`, and writes `(w, fromSurplus)`. Retag and value update are the same single `SSTORE`; there is never a standalone retag write.

**Rule G2 — conditional surplus load.** `fromSurplus` is computable from the agent slot and immutables alone (steps 4–10), so when it is zero the surplus slot is never read either.

**Storage access per accepted payment**

| Configuration | Cold `SLOAD` | `SSTORE` |
|---|---|---|
| `ρ = 1` (`fromSurplus` always 0 on accepted paths) | 1 | 1 |
| `ρ = 0` (`fromSurplus = a > 0` always) | 2 | 2 |
| `0 < ρ < 1` | 1 if the payment fits in reservation, else 2 | 1 or 2 |

**A rejected refinement, recorded deliberately.** At `ρ = 1` we have `S = 0`, so any `fromSurplus > 0` fails the guard regardless of `used_eff`; the load at step 11 could be short-circuited by testing the immutable `S == 0` first. We **do not** do this. Special-casing `ρ = 1` would give it a different code path from the other configurations and destroy the apples-to-apples property that makes the gas comparison in Part 6 meaningful. The cost is one cold `SLOAD` on a path that reverts anyway.

The agent slot is written on every accepted payment (`a > 0` always increases `spent_i`), with retag folded in. No code path iterates the agent set — the structural claim behind T10.

---

## Part 4 — Arithmetic, Overflow, and Oracle Independence

**Constructor.** `R = floor(B_G · ρ_num / ρ_den)` by bounded multiplication under A3 and A4 (§2.4). No external arithmetic dependency.

**Hot path.** After the `a ≤ B_G` guard every intermediate is bounded by `B_G`: `ownRem ≤ r_i ≤ R ≤ B_G`, `fromRes ≤ a ≤ B_G`, `fromSur ≤ a ≤ B_G`, and `used_eff + fromSur ≤ B_G` on accepted paths. The only division is `/ Δ` for the window id. Solidity 0.8 checked arithmetic stays enabled; `unchecked` is permitted only where a comment restates the bound that makes it safe and names the assumption (A1–A4) it rests on.

**Three layers that must not share code.**

- *Mathematical semantics* — Spec v1.1 §1.4, prose and formulas only.
- *Implementation arithmetic* — the constructor's bounded multiply, `SafeCast` downcasts, hot-path branches.
- *Test oracle* — must not recompute `R` with the implementation's helper or a copy of it.

The oracle asserts the **characterizing inequality** instead of recomputing:

```
R · ρ_den ≤ B_G · ρ_num    and    B_G · ρ_num < (R + 1) · ρ_den
```

This validates `R` against its definition without reimplementing it, so it cannot inherit the same error. Under A3 and A4 both products fit `uint256`, so the oracle needs no wide arithmetic. For apportionment the oracle likewise asserts properties — `Σ r_i == R`, `max − min ≤ 1`, non-increasing in `idx` — rather than re-deriving `r_i`. Fixed-scenario expectations such as `(34, 33, 33)` at `B_G = 100, N = 3, ρ = 1` are hand-computed constants written literally into the tests.

The same independence rule governs the Reference fixture: it must implement the debit rule from the spec on its own, not by calling into anything the Optimized contract also calls.

---

## Part 5 — Reentrancy and the External-Call Boundary

**Custody.** The contract holds the principal's tokens, prefunded, and calls `transfer` on payment. No deposit manager, no withdrawal path, no emergency admin — none of these belong to a budget-allocation study. Before the demo the deployer transfers the mock or USDC-like token directly to the contract.

Budget and liquidity stay two independent bounds: budget is the authorization bound enforced here; balance is the liquidity bound enforced by the token. A payment can pass the budget check and still revert on insufficient balance. This is exactly the premise in Spec §3 I2, which reads in implementation terms as **"the principal-controlled wallet/contract balance is sufficient."** The implementation therefore matches the invariant's stated scope rather than quietly widening it.

**Ordering.** Strict checks–effects–interactions, as in Part 3: bounds and membership checks, then the budget guard, then all state writes, then the transfer last. If the transfer reverts the whole transaction reverts and `spent_i` / `surplusUsed` roll back, so the budget accounts **settled** value, not attempted value — consistent with I4 and required by T16. If a malicious token re-enters `pay()` from inside `transfer`, budget state is already updated, so the nested call is evaluated against post-debit state: **I1 survives reentrancy under CEI alone.**

**Why `nonReentrant` anyway.** Not because reentrancy breaks safety. EVM execution is sequential regardless; what reentrancy produces is *nested* `pay` transitions. The property-test handler verifies an abstraction of one external call per one state transition, and T18's transition property is stated over `ownRemaining` evaluated immediately before a call. Nested transitions fall outside that abstraction, so a passing suite would no longer certify what actually happens on chain. The guard keeps on-chain behaviour inside the model the tests verify.

**Threat boundary.** *In scope:* reentrancy via the token transfer path; transfer failure causing full rollback; non-standard ERC-20 return values (`SafeERC20`). *Out of scope, stated as assumptions rather than ignored:* fee-on-transfer tokens (the contract accounts the authorized amount, not the received amount), rebasing tokens, blacklist or pause switches (a blocked transfer reverts the payment — correct, but not otherwise modelled), tokens that misreport balances. The MVP assumes a standard non-rebasing, non-fee-on-transfer ERC-20 with USDC-like behaviour; the test mock conforms, plus one adversarial mock with a reentrant `transfer` hook to exercise this section.

---

## Part 6 — Hypotheses to Benchmark

Falsifiable predictions for the evaluation, not claims to assert.

**H1 — Reservation-only payments are cheaper (directional).** An accepted payment with `fromSurplus = 0` never loads or writes the surplus slot (G1, G2), so it should cost less than an otherwise identical payment with `fromSurplus > 0` by one global state load plus one write. **No fixed gas range is predicted**, because `SSTORE` cost depends on zero→nonzero versus nonzero→nonzero, on original versus current value, and on access warmth. Record the three regimes separately rather than averaging them together:
  - first-ever surplus use in the contract's life (zero→nonzero, cold);
  - a later surplus use within the same window (nonzero→nonzero);
  - the first surplus use after a rollover (nonzero→nonzero against a stale value, cold).
*Falsified if* reservation-only and surplus-consuming payments cost the same — meaning G2 is not short-circuiting.

**H2 — Per-redemption gas is flat in `N`.** Slope over `N ∈ {2, 5, 10, 20, 50}` indistinguishable from zero. *Falsified by* any positive slope, which would mean a code path iterates the agent set.

**H3 — Mandatory versus optional storage locations.** Distinguish three things that v1 conflated:
  - *Logical locations* in the layout: `N` agent slots plus one global surplus slot.
  - *Materialized (non-zero persistent) locations:* the `N` agent slots are materialized at construction by registration. The global surplus slot is **optional** — under `ρ = 1` no accepted payment ever writes it, so it stays zero and unmaterialized for the contract's whole life. (It may be *read* on a doomed path that then reverts; the revert discards everything, so persistent state is unaffected.) Surplus-consuming configurations activate it, and that first activation is a zero→nonzero write in its own gas regime.
  - *Touched per payment:* one slot at `ρ = 1`, two at `ρ = 0`.

  So the three mechanisms do **not** have identical footprints, and the difference should be reported rather than smoothed away. *Falsified if* the global slot is found materialized under `ρ = 1`, which would indicate G1 is writing when it should not.

**H4 — Hybrid gas interpolates by spill rate.** Mean per-payment gas in hybrid `ρ` is a spill-rate-weighted interpolation between the `ρ = 1` and `ρ = 0` costs, spill rate being the fraction of payments with `fromSurplus > 0`. *Falsified by* systematic deviation, indicating an unmodelled branch cost.

**H6 — Optimized versus Reference, by scenario.** No blanket "one fewer `SSTORE`" claim; in a same-window payment the Reference also writes only `spent`, since `indexPlusOne` and `windowId` are unchanged. The predicted differences are:
  - *Same-window accepted payment:* Reference reads up to three separate cold slots versus Optimized's one — the saving is roughly two cold `SLOAD`s. `SSTORE` count is the same.
  - *First access after rollover:* Optimized updates `windowId` and `spent` in one packed `SSTORE`; Reference needs two. Saving ≈ one `SSTORE`.
  - *Persistent agent-state footprint:* `3N` slots versus `N`.

  Measure all three; do not assume a uniform saving. *Falsified if* the compiler already coalesces the Reference's adjacent slots, in which case the packing is not earning its complexity.

**H7 — `N`-dependent cost is moved, not removed.** Deployment and initialization gas grows approximately linearly in `N`, because the constructor must write `N` membership/index slots and emit `N` registration events. Per-redemption gas stays approximately flat in `N`. Report both curves side by side. The honest framing for the presentation is *"we move `N`-dependent work into one-time initialization rather than pretending it disappears."* *Falsified if* deployment gas is sublinear (unexpected) or per-redemption gas is superconstant (contradicts H2).

**Appendix microbenchmark (not a core hypothesis).** EIP-2929 batched versus unbatched access. There is **no production `batchPay()`**; the core API remains a single atomic payment. The experiment lives entirely in the benchmark harness, which places several `pay()` calls inside one top-level transaction so they share an access list, and it is labelled an appendix microbenchmark in the report.

### Evaluation matrix split

**Correctness matrix** — rounding and boundary behaviour: `B_G ∈ {100, 101, 1000}`, `N ∈ {2, 3, 5, 50}`, `ρ ∈ {0, 1/4, 1/3, 1/2, 3/4, 1}`. Small values are chosen so apportionment remainders are visible and hand-checkable.

**Performance / fairness matrix** — utilization, starvation, Jain index, gas: realistic smallest-unit budgets with `B_G ≫ N`, e.g. `B_G = 10^12` (one million USDC at 6 decimals), `N ∈ {2, 5, 10, 20, 50}`. At `N = 50`, `base = 2×10^10`, so the ±1 smallest-unit apportionment difference perturbs a service ratio by ≈5×10^-11 and the Jain index by order 10^-21 — negligible.

**The fairness definition in Spec §6 is unchanged.** Only the benchmark parameters are chosen, so that the measured quantity reflects the mechanism rather than the quantization.

---

## Part 7 — Implementation Checklist

**Constructor and configuration**

- [ ] `require` A1: `1 ≤ N ≤ 2^16 − 1`
- [ ] `require` A3: `0 < B_G ≤ 2^192 − 1`
- [ ] `require` A4: `0 < ρ_den ≤ 2^32 − 1` and `ρ_num ≤ ρ_den`
- [ ] `require` `Δ > 0`; set `t₀ = block.timestamp` (Spec errata)
- [ ] `R` via bounded multiplication; assert `B_G · ρ_num < 2^224` holds by A3 ∧ A4, with the proof in a comment
- [ ] `base = R / N`, `rem = R % N`, `S = B_G − R`, all stored `immutable`
- [ ] Reject duplicate agent addresses at registration; reject the zero address
- [ ] Index assignment is stable, dense over `[0, N)`, and assigned once — no reuse, no reordering, no post-construction mutation
- [ ] Optimized: emit `AgentRegistered(agent, idx)` per agent; **no** `_agents` array
- [ ] Reference: keep `_agents` array for inspection

**Encoding and arithmetic**

- [ ] `AgentSlot` packs to exactly 256 bits: `uint16 | uint48 | uint192`
- [ ] `SurplusSlot` packs to exactly 256 bits: `uint48 | uint208`
- [ ] Unit test asserting each struct occupies one slot (encode/decode round-trip at max values)
- [ ] `currentWindowId` produced through a checked `uint48` cast (A2), failing closed
- [ ] Explicit `SafeCast` on every narrowing downcast
- [ ] No `unchecked` block without a comment naming the bound and the assumption (A1–A4) that justifies it

**Payment path**

- [ ] `require(a > 0 && a <= B_G)` as the first check, with the §2.3 proof referenced in a comment
- [ ] `r_i = base + (idx < rem ? 1 : 0)` — `O(1)`, no loop, no per-agent reservation storage
- [ ] Effective (window-masked) load for both `spent_i` and `surplusUsed`
- [ ] G2: surplus slot not read when `fromSurplus == 0`
- [ ] G1: surplus slot not written when `fromSurplus == 0`; retag folded into the value write
- [ ] Agent slot written on every accepted payment, retag folded in
- [ ] Strict CEI: checks → all state writes → `token.safeTransfer` last
- [ ] `nonReentrant` on the payment entry point
- [ ] `SafeERC20` for all token interaction
- [ ] Every public view returns effective current-window values; no stale physical state observable anywhere (T11)

**Tests**

- [ ] Reference implemented independently — no shared debit or state-transition helper with Optimized
- [ ] Differential harness: identical call sequences produce identical effective state at every step, across the full correctness matrix
- [ ] T1–T18 pass on both implementations
- [ ] Three mutation checks kill their named tests: surplus-first → T18 and T4; remove surplus guard → T1; drop window-tag check → T5 and T11
- [ ] Fuzz `assume` rejection rate below the Foundry warning threshold
- [ ] Adversarial token mock with a reentrant `transfer` hook
- [ ] T12 and T13 fixed traces match Appendix A of the test plan step for step

**Benchmarks**

- [ ] Deployment gas versus `N` (H7)
- [ ] Per-redemption gas versus `N` (H2)
- [ ] Accepted-payment gas split by path: `fromSurplus == 0` versus `> 0` (H1)
- [ ] Surplus `SSTORE` regimes recorded separately: first-ever, later-same-window, first-after-rollover (H1)
- [ ] Materialized slot count by configuration, showing the global slot unmaterialized at `ρ = 1` (H3)
- [ ] Optimized versus Reference by scenario: same-window, post-rollover, persistent footprint (H6)
- [ ] Hybrid spill-rate interpolation (H4)
- [ ] Batched-versus-unbatched appendix microbenchmark, harness only, no production `batchPay()`

---

**Status.** Topic Frozen → Semantics Frozen → Tests Frozen → **Layout v1.1 Frozen** → Implementation.
