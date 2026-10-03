# SpendPartition Weighted Allocation Extension — Draft v1

## 1. Purpose

This extension adds heterogeneous reservation weights to SpendPartition while preserving the existing SpendPartition v1.1 baseline unchanged.

The baseline contract `src/SpendPartition.sol` MUST NOT be modified.

The extension is implemented separately so that the existing equal-weight contract, tests, bytecode, and gas measurements remain reproducible.

The frozen documents under `docs/frozen/` remain the semantic source of truth for the baseline. This document defines only the weighted-allocation extension.

---

## 2. Configuration

The weighted contract takes:

- ERC-20 token
- ordered delegate list `agents[]`
- corresponding integer weights `weights[]`
- total budget `B_G`
- reservation ratio `rhoNum / rhoDen`
- window duration `Delta`

Requirements:

- `agents.length == weights.length`
- `N >= 1`
- the existing SpendPartition configuration bounds remain applicable
- individual weights MAY be zero
- `sum(weights)` MUST fit in `uint256`
- `sum(weights) > 0`
- delegate registration order is stable and defines the deterministic tie-break order

Weights are relative integers. They do not need to sum to a fixed scale.

For example, `[1, 1, 1]` and `[10, 10, 10]` represent the same allocation proportions.

---

## 3. Reserved and Shared Capacity

The existing SpendPartition definition is unchanged:

```text
R = floor(B_G * rhoNum / rhoDen)
S = B_G - R
```

where:

- `R` is the total capacity reserved across delegates
- `S` is the shared surplus

The weighted extension changes only how `R` is divided among delegates.

The payment debit rule remains reservation-first, then shared surplus.

---

## 4. Weighted Quotas

Let:

```text
W = sum(weights)
```

For delegate `i`, the exact proportional quota is:

```text
q_i = R * w_i / W
```

Because token amounts are integers, `q_i` generally cannot be represented exactly.

The initial integer allocation is:

```text
base_i = floor(R * w_i / W)
```

The exact fractional remainder is represented by:

```text
remainder_i = (R * w_i) mod W
```

No floating-point arithmetic is used.

---

## 5. Largest-Remainder / Hamilton Apportionment

After computing every `base_i`:

```text
L = R - sum(base_i)
```

Exactly `L` additional smallest units are assigned.

Delegates are ranked by:

1. larger `remainder_i` first
2. if remainders are equal, lower registration index first

The first `L` delegates in that deterministic ordering receive one additional unit.

Therefore:

```text
r_i = base_i + 1    if delegate i receives a remainder unit
    = base_i        otherwise
```

This is Hamilton / largest-remainder apportionment.

---

## 6. Required Properties

### P1 — Exact conservation

```text
sum(r_i) == R
```

No additional reservation remainder may be lost.

### P2 — Quota bound

Every delegate receives either the floor or ceiling of its exact quota:

```text
floor(q_i) <= r_i <= ceil(q_i)
```

### P3 — Equal-weight compatibility

For equal non-zero weights, the weighted implementation MUST reproduce the existing SpendPartition allocation exactly.

Therefore, if:

```text
weights = [1, 1, ..., 1]
```

then:

```text
base = R / N
rem  = R mod N

r_i = base + 1    if idx(i) < rem
    = base        otherwise
```

This property is required for backwards-compatible semantics.

### P4 — Determinism

For a fixed configuration and registration order, reservations are fully deterministic.

### P5 — Zero weight

A delegate with weight zero receives zero protected reservation.

Such a registered delegate may still consume shared surplus subject to the normal SpendPartition payment rules.

### P6 — Own-weight monotonicity

Holding `R` and every other delegate's weight fixed, increasing delegate `i`'s weight must not reduce delegate `i`'s resulting reservation.

This property will be tested separately rather than assumed from the implementation.

---

## 7. Endpoint Compatibility

At:

```text
rho = 0
```

we have:

```text
R = 0
r_i = 0 for all i
S = B_G
```

so the weighted contract reduces to the existing Shared Global Pool endpoint.

At:

```text
rho = 1
```

we have:

```text
R = B_G
S = 0
```

so the full budget is statically partitioned according to the configured weights.

---

## 8. Implementation Architecture

Weighted apportionment MUST occur during deployment/configuration.

The `pay()` path MUST NOT rank delegates, sort weights, or iterate over the delegate set.

Each final `r_i` is therefore precomputed during construction and made available through an O(1) reservation lookup.

The weighted payment path must remain O(1) with respect to `N`.

Unlike the baseline equal-weight contract, the weighted implementation cannot derive every `r_i` from only `base`, `rem`, and `idx`.

The weighted implementation will therefore require additional reservation storage or an equivalent O(1) lookup structure.

This may increase absolute payment gas relative to `SpendPartition.sol`, but payment gas should remain independent of `N`.

That trade-off is part of the weighted-extension evaluation.

---

## 9. Arithmetic

The baseline bound:

```text
R <= B_G <= uint192.max
```

continues to hold.

However, arbitrary integer weights mean that the intermediate:

```text
R * w_i
```

must not be assumed to fit into `uint256`.

The optimized weighted implementation should therefore use full-precision integer arithmetic such as:

```text
Math.mulDiv(R, w_i, W)
```

for `floor(R * w_i / W)`, and:

```text
mulmod(R, w_i, W)
```

for the exact remainder.

Arithmetic used by the independent reference implementation should remain structurally separate where practical so that differential testing does not simply reproduce a common implementation mistake.

---

## 10. Verification Requirements

The weighted extension must include:

- fixed weighted scenarios
- fuzz/property tests
- invariant testing
- an independent plain weighted reference implementation
- differential testing between optimized and reference implementations

At minimum, tests must verify:

```text
sum(r_i) == R

floor(q_i) <= r_i <= ceil(q_i)

equal weights reproduce the existing SpendPartition reservations

reservations are deterministic

increasing one delegate's weight does not reduce its own reservation

rho = 0 and rho = 1 retain their endpoint meanings
```

Existing SpendPartition safety properties I1-I5 should continue to hold under the weighted reservation vector.

---

## 11. Differential Campaign

The optimized weighted implementation and the independent weighted reference implementation will receive identical:

- configurations
- delegates and weights
- callers
- payment amounts
- window changes

Their externally observable outcomes and state must agree.

Target:

```text
at least 4 configurations
64 runs
depth 128
```

giving:

```text
8192 handler calls per configuration
```

consistent with the existing project methodology.

---

## 12. Gas Evaluation

Weighted measurements should vary two independent dimensions:

1. delegate count `N`
2. weight distribution / unevenness

Suggested `N` values:

```text
2, 5, 10, 20, 50
```

Suggested weight profiles:

```text
equal
mildly skewed
highly skewed
one dominant delegate
```

Measure separately:

- deployment gas
- reservation-only payment gas
- surplus payment gas
- optimized weighted vs existing equal-weight baseline
- optimized weighted vs plain weighted reference

The main scalability question is whether payment cost remains flat as `N` grows, even if weighted apportionment increases deployment cost.

---

## 13. Known Apportionment Limitation

Hamilton / largest-remainder apportionment has known apportionment paradoxes.

In particular, changing the participant set may cause an existing delegate's integer allocation to change even when that delegate's own weight did not change.

This is treated as a documented design property of deterministic integer apportionment, not as a violation of SpendPartition aggregate safety.

The extension does not claim cross-configuration allocation stability.

---

## 14. Non-Goals

This extension does not add:

- dynamic weight changes inside a deployment
- adding or removing delegates after deployment
- borrowing protected reservation
- reclaim within a window
- cross-window carry-over
- changes to the existing `SpendPartition.sol`
- changes to existing baseline measurements
