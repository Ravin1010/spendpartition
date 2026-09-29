# AgentPayGuard — Property-Test Plan v1.1 (against Spec v1.1)

**Changes from v1.** T12 replaced (v1's scenario silently assumed partial grant, contradicting the atomic all-or-nothing payment semantics of Spec §2). T8's `iff` on `R == 0` corrected to a one-way implication plus a floor bound. T14's monotonicity assertion removed. Mutation criteria corrected — the surplus-first mutation does **not** kill T13. New transition test T18. Spec v1.1 is unchanged; nothing here bumps it.

**Global rule.** Every assertion reads **effective** current-window values per Spec §1.5, never raw storage. A test asserting against physical storage passes spuriously across a window boundary and is invalid.

**Atomicity rule.** `pay(i, a)` either accepts the full amount `a` or reverts entirely. There is no partial grant anywhere in this plan. Any test whose expected outcome requires an agent to receive less than it requested in a single call is wrong by construction.

---

## 0. Harness

**Handler.** A bounded actor contract exposing `pay(agentSeed, amountSeed)` and `warp(timeSeed)`. Actors drawn from the fixed `N`-agent set; amounts bounded to `[1, B_G]`; time warps bounded so windows advance without overflow. Reverting calls are permitted and must not abort the run — a rejected payment is a valid outcome whose state effect must be nil.

**Ghost variables** maintained by the handler, never read from the contract: `g_spent[i]`, `g_surplusUsed`, `g_windowId`, `g_granted[i]`, `g_demanded[i]`, and an append-only log of `(windowId, agent, amount, accepted)`.

**Configuration matrix.** `ρ ∈ {0, 1/4, 1/2, 3/4, 1}` as exact rationals; `N ∈ {2, 3, 5, 10, 50}`; `B_G ∈ {100, 101, 1000, 2^64−1}` — the non-round values exist to exercise apportionment remainders.

---

## 1. Core Invariants

**T1 — Aggregate Safety (I1).** `Σ effective spent_i ≤ B_G` after every handler call, in every configuration. Must also hold immediately after any reverted call and immediately after any window rollover.

**T2 — Budget-Layer Isolation (I2).** For every agent `i` with `effective spent_i < r_i`, a probe payment by `i` of amount `a = r_i − spent_i` is accepted by the budget check, evaluated after arbitrary handler histories driven by agents `j ≠ i`.

*Probe mechanics.* Use `vm.snapshotState()` → invoke the **real** payment entry point → `vm.revertToState()` (cheatcode names vary by forge version; older builds use `vm.snapshot()` / `vm.revertTo()`). Do **not** implement a separate `canPay` predicate: a duplicated predicate can drift from the real state transition, and a plain `staticcall` cannot execute a path that writes storage.

*Scope.* Asserts budget-layer acceptance only. Must not assert end-to-end transfer success (Spec §3, I2 scope note).

**T3 — Surplus Conservation (I3).** `effective surplusUsed ≤ S`.

**T4 — Accounting Consistency (I4).** `effective surplusUsed == Σ max(0, effective spent_i − r_i)`. Cross-check `effective spent_i == g_spent[i]` for the current window.

**T5 — Window Isolation (I5).** After any `warp` advancing `currentWindowId`, every effective `spent_i` and `surplusUsed` reads `0` **before** any state-changing call in the new window. Includes the stale-leak case: an agent idle for `k > 1` windows must read `0` and be metered against a fresh `r_i`.

---

## 2. Endpoint Semantics

**T6 — `ρ = 1` is exactly Static Partition.** For every `N`, `B_G` in the matrix: `S == 0`; any payment with `fromSurplus > 0` reverts; each agent can spend exactly `r_i` and no more; `Σ r_i == B_G` exactly.

*Regression anchor for Spec v1.1 §1.4.* With `B_G = 100, N = 3, ρ = 1`: `R = 100`, `base = 33`, `rem = 1`, so `r = (34, 33, 33)`, `Σ r_i = 100`, `S = 0`. The superseded v1 rounding rule produced `r = (33,33,33)` with `S = 1`, breaking the endpoint. This test exists specifically to catch a regression to that rule. Also check `B_G = 101, N = 3`: `base = 33`, `rem = 2`, `r = (34, 34, 33)`, `Σ = 101`, `S = 0`.

**T7 — `ρ = 0` is exactly Shared Global Pool.** `R == 0`, all `r_i == 0`, `S == B_G`. One agent can consume the entire `B_G`. Assert that T2's antecedent is **unsatisfiable** here (I2 holds vacuously), rather than asserting acceptance.

**T8 — Integer Apportionment.** `testFuzz_apportionment(ρ_num, ρ_den, B_G, N)` with `0 ≤ ρ_num ≤ ρ_den`, `ρ_den > 0`. Assert:

- `Σ r_i == R` exactly, and `max_i r_i − min_i r_i ≤ 1`.
- Determinism: `r_i` depends only on `idx(i)` and configuration — recompute twice, compare.
- `ρ_num == 0 ⟹ R == 0`. **One direction only.** The converse is false: `B_G = 100, ρ = 1/1000` gives `R = floor(0.1) = 0` with `ρ_num ≠ 0`. Include this as an explicit fixed case.
- `ρ_num == ρ_den ⟹ R == B_G` (exact; no rounding occurs).
- General floor characterization, stated without division: `R · ρ_den ≤ B_G · ρ_num` and `B_G · ρ_num < (R + 1) · ρ_den`.

*Implementation note (not a Spec change).* `B_G · ρ_num` can exceed `uint256` for large operands. The implementation must **either** compute `R` with a full-precision `mulDiv` (OpenZeppelin `Math.mulDiv` or equivalent 512-bit intermediate), **or** enforce constructor bounds proving the intermediate multiplication fits in `uint256`. The optimized implementation chooses the latter: `B_G ≤ 2^192 − 1` and `ρ_den ≤ 2^32 − 1` give `B_G · ρ_num < 2^224`. This is an arithmetic requirement on the implementation; the semantics in Spec §1.4 are unchanged.

---

## 3. Window Rollover

**T9 — Lazy Reset Correctness.** An agent transacts in window `w`, is idle through `w+1 … w+k`, then transacts in `w+k+1`. Assert: its record is retagged and zeroed exactly once, on that first state-changing access; its full `r_i` is available; no other agent's record was touched.

**T10 — No Global Rollover Path** *(structural / regression, not a proof).* Report gas for the first payment in a new window at `N = 2, 5, 10, 50` and track the slope in a gas snapshot committed to the repo. A slope that grows with `N` is a regression signal. This is evidence, not a mathematical `O(1)` proof — the actual guarantee comes from a code-review assertion, recorded in the PR checklist, that no code path iterates over the agent set during rollover.

**T11 — Read Path Does Not Leak Stale State.** Call every public view function immediately after a window advance and before any write. All must return effective (zeroed) values. This catches "the invariant passes but the dashboard shows last window's numbers."

---

## 4. Adversarial Ordering

### T12 — Ordering Redistributes Capacity but Never Breaks I1 *(required)*

**Primary case (`ρ = 0`).** `N = 3`, `B_G = 100`, `ρ = 0` → `R = 0`, `r_i = 0`, `S = 100`. Three agents make one atomic request each: `A = 60`, `B = 60`, `C = 40`. Aggregate demand `160 > B_G`.

Enumerate all `3! = 6` orderings. Assert:

1. **Outcomes differ.** Exactly two distinct grant vectors occur: `(60, 0, 40)` and `(0, 60, 40)`. If all orderings coincide the scenario is mis-parameterized and the test is void.
2. **I1 holds with equality in every ordering.** `Σ granted == 100` exactly — not merely `≤ B_G`.
3. `surplusUsed == 100` in every ordering. The capacity is fully consumed regardless of who consumes it.

This is the central claim in executable form: *ordering decides who receives contested capacity; it never decides whether the principal is over-exposed.* This case is chosen so that atomic granularity leaves no residual, keeping the claim clean.

**Secondary case (`ρ > 0`, honest about stranding).** `N = 3`, `B_G = 100`, `ρ = 3/10` → `R = 30`, `r_i = 10`, `S = 70`. Each agent makes one atomic request of `40` (`= 10` reservation `+ 30` surplus).

After two acceptances `surplusUsed = 60`, leaving `10` of surplus. The third request needs `30` and therefore **reverts in full** — the atomic semantics forbid a partial grant of `20`. Assert: grant vector is `(40,40,0)` up to permutation of which agent is last; `Σ granted == 80`; `surplusUsed == 60`; stranded capacity `== 20` (the last agent's unused `r_i = 10` plus `10` of residual surplus).

Record this stranding as a measured consequence of atomic request granularity. It is a property of the workload and the request size, not a new mechanism or contribution, and must not be presented as one.

### T13 — Protected Reservation Cannot Be Encroached *(required)*

`N = 2`, `B_G = 100`, `ρ = 1/2` → `R = 50`, `r_A = r_B = 25`, `S = 50`.

Malicious agent `A` executes adversarial sequences — one maximal spend, many minimal spends, spends straddling its own reservation boundary, repeated rejected attempts — until it has consumed `r_A + S = 75`, its ceiling. Assert `A` cannot exceed 75: a request of `76` from a clean state reverts.

Then assert honest `B`'s request for `25` is **accepted by the budget check**, and `B`'s subsequent request for `1` reverts (both reservation and surplus exhausted).

*Generalized fuzz form.* For random `N`, `ρ`, and random adversarial sequences by all agents `j ≠ i`, any request by `i` of amount `a ≤ r_i − spent_i` is accepted. This is the executable form of I2 and the strongest single guarantee the system provides.

### T14 — Starvation Measurement *(measurement only, no shape assertion)*

One aggressive agent drains `S` immediately; honest agents then submit a fixed demand model. Record the starvation-vs-`ρ` curve across the sweep and report it.

**Assert only:** `Σ spent ≤ B_G` (I1 intact), and every rejected honest request had `a > r_i − spent_i` — i.e. no I2-protected request is ever rejected. **Do not assert that starvation decreases with `ρ`.** That is a workload-dependent observation, not a protocol guarantee.

*Counterexample proving the removed assertion was wrong.* `N = 2`, `B_G = 100`, honest request size `a = 60`, adversary drains maximally. At `ρ = 0`: `S = 100`, adversary takes 100, honest reverts. At `ρ = 1/2`: `r = 25` each, `S = 50`, adversary takes `25 + 50 = 75`, honest has `ownRemaining = 25 < 60` and no surplus left, reverts. At `ρ = 1`: `r = 50` each, `S = 0`, honest needs `10` of surplus that does not exist, reverts. Starvation is **flat at 100% across the entire `ρ` range**. Whenever honest request size exceeds `B_G / N`, raising `ρ` cannot help at all.

Separate what we hope to observe from what the mechanism guarantees, in the report and in the demo narration.

---

## 5. Randomized and Structural

**T15 — Randomized Amounts and Orderings.** Invariant runs at high depth with randomized actor and amount selection across the full configuration matrix. I1–I5 must hold at every step.

**T16 — Revert Atomicity.** Snapshot full state; submit a payment that must fail the budget check; expect revert; assert byte-identical state afterwards — `spent_i`, `surplusUsed`, and window tags unchanged, no transfer emitted. Include the case where the failing call is the first access in a new window, so an attempted lazy retag must be rolled back with everything else.

**T17 — Boundary Arithmetic.** `a = 0` rejected; `a` exactly equal to `ownRemaining`; `a = ownRemaining + 1`; `a = B_G`; `a = type(uint256).max` must revert, not wrap; `spent_i` exactly at `r_i` then one more unit (must route entirely to surplus); `B_G` at the maximum supported value.

**T18 — Debit-Order Transition Property** *(new)*. For every accepted payment, with `ownRemaining = max(0, r_i − spent_i)` evaluated **before** the call:

- if `a ≤ ownRemaining` then `Δ surplusUsed == 0`;
- if `a > ownRemaining` then `Δ surplusUsed == a − ownRemaining`;
- in both cases `Δ spent_i == a`.

This encodes reservation-before-surplus as an observable state transition. It is consistent with I4 (`surplusUsed = Σ max(0, spent_i − r_i)`) and is the property that a surplus-first implementation violates immediately.

---

## 6. Exit Criteria

Semantics are validated and storage layout may begin when:

1. T1–T18 pass across the full configuration matrix.
2. T12 (both cases) and T13 pass in fixed-scenario and fuzz form, with hand-computed traces in Appendix A matching actual execution step for step.
3. Invariant runs reach target depth with no `assume` rejection rate above the Foundry warning threshold. A high rejection rate means the handler never reaches contested states, and the suite proves nothing.
4. **Mutation checks** — each mutation must be killed by the named test:

| Mutation | Must be killed by | Why |
|---|---|---|
| Debit surplus before reservation | **T18**, and T4 | T13 does **not** die here: under surplus-first, `A` paying 75 takes 50 from surplus and 25 from its own reservation, leaving `B`'s 25 intact, so `B` is still accepted. T18 dies on the first payment with `a ≤ ownRemaining` (`Δ surplusUsed = a ≠ 0`); T4 dies at the same point (`surplusUsed = a` while `Σ max(0, spent_i − r_i) = 0`). |
| Remove the `surplusUsed + fromSurplus ≤ S` guard | **T1** | Spending becomes unbounded; `Σ spent_i` exceeds `B_G`. |
| Drop the window-tag check on the read path | **T5**, T11 | Stale counters survive rollover; effective state is non-zero at window start. |

A suite that survives any of these mutations is not testing what it claims to test.

---

## Appendix A — Hand-Computed Traces

All values from Spec v1.1 §2. `ownRem = max(0, r_i − spent_i)` evaluated before the call.

### A.1 — T12 Primary. `N=3, B_G=100, ρ=0` ⟹ `R=0, r_i=0, S=100`

**Ordering A → C → B**

| # | Agent | `a` | `spent` before | `surplusUsed` before | `ownRem` | `fromRes` | `fromSur` | Check | Result | `spent` after | `surplusUsed` after |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | A | 60 | 0 | 0 | 0 | 0 | 60 | 0+60=60 ≤ 100 | ACCEPT | A=60 | 60 |
| 2 | C | 40 | 0 | 60 | 0 | 0 | 40 | 60+40=100 ≤ 100 | ACCEPT | C=40 | 100 |
| 3 | B | 60 | 0 | 100 | 0 | 0 | 60 | 100+60=160 > 100 | **REVERT** | B=0 | 100 |

Final `(A,B,C) = (60, 0, 40)`, `Σ = 100`, `surplusUsed = 100`.

**Ordering B → C → A**

| # | Agent | `a` | `spent` before | `surplusUsed` before | `ownRem` | `fromRes` | `fromSur` | Check | Result | `spent` after | `surplusUsed` after |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | B | 60 | 0 | 0 | 0 | 0 | 60 | 0+60=60 ≤ 100 | ACCEPT | B=60 | 60 |
| 2 | C | 40 | 0 | 60 | 0 | 0 | 40 | 60+40=100 ≤ 100 | ACCEPT | C=40 | 100 |
| 3 | A | 60 | 0 | 100 | 0 | 0 | 60 | 100+60=160 > 100 | **REVERT** | A=0 | 100 |

Final `(0, 60, 40)`, `Σ = 100`, `surplusUsed = 100`.

All six orderings yield `Σ = 100` and `surplusUsed = 100`; the grant vector is `(60,0,40)` or `(0,60,40)`.

### A.2 — T12 Secondary. `N=3, B_G=100, ρ=3/10` ⟹ `R=30, r_i=10, S=70`

**Ordering A → B → C**, each requesting 40

| # | Agent | `a` | `spent` before | `surplusUsed` before | `ownRem` | `fromRes` | `fromSur` | Check | Result | `spent` after | `surplusUsed` after |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | A | 40 | 0 | 0 | 10 | 10 | 30 | 0+30=30 ≤ 70 | ACCEPT | A=40 | 30 |
| 2 | B | 40 | 0 | 30 | 10 | 10 | 30 | 30+30=60 ≤ 70 | ACCEPT | B=40 | 60 |
| 3 | C | 40 | 0 | 60 | 10 | 10 | 30 | 60+30=90 > 70 | **REVERT** | C=0 | 60 |

Final `(40, 40, 0)`, `Σ = 80`, `surplusUsed = 60`, stranded `= 20`.

### A.3 — T13. `N=2, B_G=100, ρ=1/2` ⟹ `R=50, r_A=r_B=25, S=50`

**Variant 1 — single maximal spend**

| # | Agent | `a` | `spent` before | `surplusUsed` before | `ownRem` | `fromRes` | `fromSur` | Check | Result | `spent` after | `surplusUsed` after |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | A | 76 | 0 | 0 | 25 | 25 | 51 | 0+51=51 > 50 | **REVERT** | A=0 | 0 |
| 1 | A | 75 | 0 | 0 | 25 | 25 | 50 | 0+50=50 ≤ 50 | ACCEPT | A=75 | 50 |
| 2 | A | 1 | 75 | 50 | 0 | 0 | 1 | 50+1=51 > 50 | **REVERT** | A=75 | 50 |
| 3 | B | 25 | 0 | 50 | 25 | 25 | 0 | 50+0=50 ≤ 50 | **ACCEPT** | B=25 | 50 |
| 4 | B | 1 | 25 | 50 | 0 | 0 | 1 | 50+1=51 > 50 | **REVERT** | B=25 | 50 |

Step 0 proves 75 is `A`'s ceiling. Step 3 is I2: `B` is accepted after `A` has taken everything it can.
`Σ spent = 100 = B_G`.

**Variant 2 — boundary-straddling increments**

| # | Agent | `a` | `spent` before | `surplusUsed` before | `ownRem` | `fromRes` | `fromSur` | Check | Result | `spent` after | `surplusUsed` after |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | A | 40 | 0 | 0 | 25 | 25 | 15 | 0+15=15 ≤ 50 | ACCEPT | A=40 | 15 |
| 2 | A | 35 | 40 | 15 | 0 | 0 | 35 | 15+35=50 ≤ 50 | ACCEPT | A=75 | 50 |
| 3 | A | 1 | 75 | 50 | 0 | 0 | 1 | 50+1=51 > 50 | **REVERT** | A=75 | 50 |
| 4 | B | 25 | 0 | 50 | 25 | 25 | 0 | 50+0=50 ≤ 50 | **ACCEPT** | B=25 | 50 |
| 5 | B | 1 | 25 | 50 | 0 | 0 | 1 | 50+1=51 > 50 | **REVERT** | B=25 | 50 |

Step 1 straddles the reservation boundary (`fromRes = 25`, `fromSur = 15`), exercising the `a > ownRemaining` branch of T18. `Σ spent = 100 = B_G`.
