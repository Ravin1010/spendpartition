# SpendPartition Weighted Allocation — Implementation Design Freeze v1

**Status:** implementation design freeze for the weighted-allocation extension.

**Basis:** `docs/extensions/WeightedAllocationSpec.md` and the frozen baseline documents under `docs/frozen/`.

**Non-negotiable baseline rule:** `src/SpendPartition.sol`, the frozen baseline documents, and the existing baseline measurements remain unchanged.

---

## 1. Contract and interface strategy

The optimized extension will be a new contract:

```text
src/SpendPartitionWeighted.sol
```

The independent plain reference will be:

```text
src/SpendPartitionWeightedReference.sol
```

Both expose the same externally observable baseline functions used by `ISpendPartition`:

- `pay`
- `currentWindowId`
- `isAgent`
- `indexOf`
- `reservationOf`
- `spentOf`
- `surplusUsed`
- `budget`
- `agentCount`
- `rhoNum`
- `rhoDen`
- `windowDuration`
- `startTime`
- `reservedTotal`
- `surplusCap`

The baseline `ISpendPartition.sol` does not need to be modified. The weighted implementations can be reached by casting their addresses to the existing interface in differential harnesses, exactly as the baseline optimized and reference implementations are today.

The weighted constructor adds one argument:

```text
weights[]
```

with one weight corresponding to each registered delegate.

---

## 2. Constructor validation

The weighted optimized contract preserves the baseline configuration checks and adds:

```text
agents.length == weights.length
sum(weights) > 0
sum(weights) fits in uint256
```

Individual weights may be zero.

The sum is accumulated with an explicit overflow check so an invalid configuration fails with the weighted contract's configuration error rather than relying on an incidental arithmetic panic.

The registration order is permanent and defines the Hamilton tie-break order.

---

## 3. Derived configuration

The baseline budget split is unchanged:

```text
R = floor(B_G * rhoNum / rhoDen)
S = B_G - R
```

`R` and `S` are computed once at deployment.

Let:

```text
W = sum(weights)
```

For delegate `i`:

```text
base_i      = floor(R * w_i / W)
remainder_i = (R * w_i) mod W
```

The optimized implementation uses full-precision integer arithmetic:

```text
Math.mulDiv(R, w_i, W)
mulmod(R, w_i, W)
```

so `R * w_i` never needs to fit in a 256-bit intermediate.

---

## 4. Hamilton assignment algorithm

After all `base_i` values are computed:

```text
L = R - sum(base_i)
```

Exactly `L` delegates receive one additional smallest unit.

The optimized constructor will use **remainder-rank counting** rather than an in-place sort.

For each delegate `i`, its rank is the number of delegates `j` for which either:

```text
remainder_j > remainder_i
```

or:

```text
remainder_j == remainder_i && j < i
```

Then:

```text
r_i = base_i + 1    if rank_i < L
    = base_i        otherwise
```

This implements largest-remainder / Hamilton apportionment with registration-index tie-breaking directly.

### Why this algorithm

- deterministic;
- simple to audit against the written rule;
- no floating point;
- equal remainders resolve by registration order;
- does not mutate the ordering of the registered delegates;
- constructor-only work, so it cannot make the payment path depend on `N`.

The constructor apportionment step is `O(N^2)` in comparisons. This is an explicit deployment-time trade-off. The project will measure deployment gas versus `N`; it will not describe weighted deployment as `O(N)`.

The existing benchmark range `N in {2, 5, 10, 20, 50}` remains the primary empirical range.

---

## 5. Optimized per-agent storage

The baseline optimized contract fits membership, index, epoch tag, and spend into one slot per delegate.

A weighted delegate additionally requires a precomputed reservation. The weighted optimized implementation will therefore use a two-slot mapping value:

```text
struct AgentSlot {
    uint16  indexPlusOne;
    uint48  windowId;
    uint192 spent;
    uint192 reservation;
}
```

Solidity packs the first three fields into one complete 256-bit slot:

```text
16 + 48 + 192 = 256 bits
```

and stores `reservation` in the second slot.

Consequences:

- membership/index/window/spend retain the baseline packed representation;
- reservation lookup is O(1);
- the payment path reads two per-agent storage slots instead of one;
- no payment path sorts, scans, or iterates over the delegate set;
- storage grows by one additional slot per delegate relative to the baseline optimized implementation.

`reservation <= R <= B_G <= uint192.max`, so `uint192 reservation` is sufficient under the inherited baseline budget bound.

No per-agent weight is stored in the optimized runtime state. Weights are constructor inputs used to derive the final reservation vector. The resulting reservations remain inspectable through `reservationOf`.

---

## 6. Weighted optimized payment path

After construction, the debit rule is intentionally the same as baseline SpendPartition:

```text
spentEff = effective current-window spent
r_i = precomputed reservation
ownRemaining = max(0, r_i - spentEff)
fromReservation = min(amount, ownRemaining)
fromSurplus = amount - fromReservation
require(surplusUsed + fromSurplus <= S)
spent_i += amount
surplusUsed += fromSurplus
transfer last
```

The same baseline properties remain applicable:

- aggregate safety;
- protected-reservation isolation;
- surplus conservation;
- accounting consistency;
- lazy window isolation;
- full accept-or-revert semantics;
- checks-effects-interactions;
- reentrancy guard.

The weighted extension changes reservation construction, not the debit rule.

---

## 7. Payment-path complexity claim

The weighted optimized payment path is required to be:

```text
O(1) with respect to N
```

This means the hot path may pay a larger constant cost than the equal-weight baseline because the precomputed reservation occupies an additional per-agent slot, but payment gas should remain flat as `N` increases for a fixed payment regime.

The report must distinguish:

```text
baseline payment complexity: O(1), one packed per-agent slot
weighted payment complexity: O(1), two per-agent slots
weighted constructor apportionment: O(N^2)
```

No claim of identical absolute gas to the baseline is made.

---

## 8. Reference implementation independence

`SpendPartitionWeightedReference.sol` remains a differential test fixture only.

It will deliberately use a different organization:

- ordinary storage rather than immutables where practical;
- an address array and linear scan for `indexOf`;
- window-keyed spending state rather than optimized epoch-tagged packed state;
- an explicit stored reservation array;
- a **selection/sort-style Hamilton construction** rather than the optimized remainder-rank algorithm;
- no packed storage arithmetic.

It may use the same audited full-precision arithmetic primitive for exact quotient/remainder arithmetic, but it must not call any weighted apportionment helper shared with the optimized contract.

The objective is behavioural equivalence without common state-transition or allocation code.

---

## 9. Test structure

New weighted tests will live in separate files and will not replace baseline tests:

```text
test/WeightedScenarios.t.sol
test/WeightedFuzz.t.sol
test/WeightedInvariant.t.sol
test/WeightedDifferential.t.sol
```

Initial fixed scenarios include:

### Equal weights

```text
R = 100
weights = [1, 1, 1]
expected = [34, 33, 33]
```

This must match baseline SpendPartition exactly.

### Unequal weights

```text
R = 100
weights = [1, 2, 3]
exact quotas = [16.666..., 33.333..., 50]
expected = [17, 33, 50]
```

### Zero weight

```text
R = 100
weights = [0, 1, 3]
expected = [0, 25, 75]
```

### Deterministic tie

Use a configuration where two delegates have equal fractional remainders and verify that the lower registration index receives priority.

### rho endpoints

Verify weighted `rho = 0` and `rho = 1` retain the baseline endpoint meanings.

---

## 10. Weighted property tests

At minimum the weighted property suite will assert:

```text
P1  sum(r_i) == R
P2  each r_i is floor(q_i) or ceil(q_i)
P3  equal weights reproduce baseline reservations
P4  fixed input and registration order are deterministic
P5  zero-weight delegates receive zero reservation
P6  increasing only w_i does not reduce r_i
```

P6 is intentionally tested as a property rather than relied on as an implementation assumption.

The test description must distinguish this single-coordinate own-weight property from broader population/new-participant stability claims, which Hamilton apportionment does not provide.

---

## 11. Weighted invariants

The existing SpendPartition invariants are re-run using the precomputed weighted reservation vector:

```text
I1  sum(spent_i) <= B_G
I2  a request that fits inside i's own remaining reservation is budget-accepted
I3  surplusUsed <= S
I4  surplusUsed == sum(max(0, spent_i - r_i))
I5  effective spending state is zero at the start of a new window
```

The weighted invariant handler maintains independent ghost spending state and exercises both payments and window movement.

---

## 12. Differential campaign

At least four weighted configurations will run:

```text
64 invariant runs x depth 128 = 8192 handler calls/configuration
```

Suggested configurations intentionally vary both `N` and weight shape, for example:

```text
N=2   equal
N=3   mild skew
N=5   zero + uneven weights
N=10  one dominant delegate
```

After every handler call, optimized and reference implementations compare:

- success/revert outcome;
- revert data where applicable;
- current window;
- reserved total;
- surplus cap and used surplus;
- every delegate reservation;
- every delegate spend;
- every delegate index;
- transferred token value.

---

## 13. Gas experiment

The weighted gas sweep will measure at least:

```text
N = 2, 5, 10, 20, 50
```

across weight profiles such as:

```text
equal
mildly skewed
highly skewed
one dominant delegate
```

Report deployment separately from payment regimes.

The central hypotheses are:

1. weighted deployment gas grows faster than the equal-weight baseline because apportionment is constructor-time `O(N^2)` and each delegate stores an extra slot;
2. weighted payment gas is higher in absolute terms than the baseline optimized path because reservation is stored explicitly;
3. weighted payment gas nevertheless remains approximately flat as `N` grows because there is no delegate-set iteration on the hot path;
4. weight shape may affect constructor gas and resulting payment regime, so the exact weight vector must be reported with every measurement.

These are hypotheses to measure, not results to assert in advance.

---

## 14. Files that remain untouched

The weighted workstream must not modify:

```text
src/SpendPartition.sol
docs/frozen/*
```

Existing baseline tests and recorded baseline measurements remain the comparison point.

Any integration change to shared tooling must be reviewed separately and must not alter previously reported baseline behaviour or overwrite baseline evidence.
