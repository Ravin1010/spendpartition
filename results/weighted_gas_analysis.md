# Weighted Gas Analysis

## Dataset and methodology

Offline command: `python3 analysis/weighted_gas_analysis.py`. Python dependencies for these artifacts: NumPy 2.3.5, Matplotlib 3.10.8. The script validates 45 configurations / 225 raw rows, cross-checks the summary, environment and reproduction hashes, and derives every numerical table from committed inputs. It never runs Anvil or rewrites source data.

Receipt `gasUsed` measures each separate broadcast transaction. N=[2, 5, 10, 20, 50], rho=1/2, budget=1e12, window=86400 seconds; registered payer N−1; merchant starts with a nonzero token balance. Foundry v1.8.4, Solidity 0.8.30+commit.73712a01, Prague, optimizer enabled (200 runs), via_ir=false. Normal local block limit 30,000,000; raised-limit flag: False.

Profiles: equal w[i]=1; mild_skew w[i]=1 for even i and 2 for odd i; high_skew w[i]=i+1; dominant all weights 1 except w[N−1]=100*N. Full vectors remain in the canonical CSVs. N=2 mild/high intentionally have the same vector.

17 methodologically equivalent baseline-control rows match the September 30 archived evidence exactly (5 deployments, 10 reservation-only, 2 surplus-repeat). Variable boundary amounts are excluded from that comparison. The accepted reproduction record reports 225 identical rows across two fresh runs; this analysis verifies its hashes without rerunning the benchmark.

Units are gas unless stated otherwise; percent overhead uses baseline gas, reference comparison uses optimized gas, and profile spread uses the four-profile arithmetic mean. `weighted_gas_analysis.csv` retains full numerical precision and paired per-configuration metrics. These PNGs are measured curves, not fit extrapolations.

## Deployment results

| Implementation | Profile | N=2 | N=5 | N=10 | N=20 | N=50 |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | equal | 800,128 | 875,002 | 999,780 | 1,249,450 | 1,998,732 |
| weighted_optimized | equal | 842,134 | 995,335 | 1,265,051 | 1,858,200 | 4,066,258 |
| weighted_optimized | mild_skew | 842,108 | 994,683 | 1,261,921 | 1,844,440 | 3,975,608 |
| weighted_optimized | high_skew | 842,108 | 994,383 | 1,258,921 | 1,830,940 | 3,885,608 |
| weighted_optimized | dominant | 842,108 | 994,871 | 1,264,581 | 1,855,858 | 4,063,756 |
| weighted_reference | equal | 857,973 | 1,008,981 | 1,270,444 | 1,830,015 | 3,800,986 |
| weighted_reference | mild_skew | 859,051 | 1,012,668 | 1,285,564 | 1,884,472 | 4,118,828 |
| weighted_reference | high_skew | 859,051 | 1,012,676 | 1,285,524 | 1,884,400 | 4,118,828 |
| weighted_reference | dominant | 859,059 | 1,010,910 | 1,290,595 | 1,853,457 | 4,258,585 |

Weighted optimized overhead versus baseline: absolute gas (percent of baseline gas).

| Profile | N=2 | N=5 | N=10 | N=20 | N=50 |
| --- | --- | --- | --- | --- | --- |
| equal | 42,006 (5.25%) | 120,333 (13.75%) | 265,271 (26.53%) | 608,750 (48.72%) | 2,067,526 (103.44%) |
| mild_skew | 41,980 (5.25%) | 119,681 (13.68%) | 262,141 (26.22%) | 594,990 (47.62%) | 1,976,876 (98.91%) |
| high_skew | 41,980 (5.25%) | 119,381 (13.64%) | 259,141 (25.92%) | 581,490 (46.54%) | 1,886,876 (94.40%) |
| dominant | 41,980 (5.25%) | 119,869 (13.70%) | 264,801 (26.49%) | 606,408 (48.53%) | 2,065,024 (103.32%) |

Least-squares fits: linear gas=a+bN; quadratic gas=a+bN+cN². R²=1−SSE/SST. Each fit uses five measured points. Reference deployment is fitted separately as a descriptive linear trend, not assumed linear architecture.

| Implementation | Profile | Model | a | b (gas/N) | c (gas/N²) | R² |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | equal | linear | 750113.744192 | 24971.531943 | — | 0.999999979832 |
| weighted_optimized | equal | linear | 625809.088041 | 67792.328273 | — | 0.996169758596 |
| weighted_optimized | equal | quadratic | 743494.241559 | 48586.013853 | 357.386460 | 0.999999999319 |
| weighted_optimized | mild_skew | linear | 638149.217661 | 65839.240364 | — | 0.996744956986 |
| weighted_optimized | mild_skew | quadratic | 743482.558870 | 48648.751932 | 319.876457 | 0.999999999038 |
| weighted_optimized | high_skew | linear | 650587.615232 | 63896.803722 | — | 0.997303291567 |
| weighted_optimized | high_skew | quadratic | 743607.730538 | 48715.843945 | 282.483633 | 0.999999995012 |
| weighted_optimized | dominant | linear | 625544.268611 | 67740.835137 | — | 0.996116984385 |
| weighted_optimized | dominant | quadratic | 743949.757772 | 48416.961344 | 359.573976 | 0.999999948559 |
| weighted_reference | equal | linear | 679446.284847 | 61737.558342 | — | 0.997849016544 |
| weighted_reference | mild_skew | linear | 639268.306890 | 68554.499604 | — | 0.996104601237 |
| weighted_reference | high_skew | linear | 639247.396647 | 68554.505940 | — | 0.996101569661 |
| weighted_reference | dominant | linear | 610457.217265 | 71497.930042 | — | 0.993009273823 |

The baseline is nearly linear. Optimized quadratic fits describe the observed curves more closely than linear fits, consistent with constructor-only O(N²) remainder-rank counting plus stored runtime reservations. A five-point quadratic fit does not prove asymptotic complexity; no extrapolation is made.

## Fixed-payment results

Only reservation_only_first, reservation_only_repeat and surplus_repeat are compared here, each amount=1e6. The first two have from_surplus=0; surplus_repeat has from_surplus=1e6 after surplus accounting is active. The window and payer are unchanged.

| Implementation | Profile | Path | N=2 | N=5 | N=10 | N=20 | N=50 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | equal | reservation_only_first | 47,123 | 47,123 | 47,123 | 47,123 | 47,123 |
| baseline | equal | reservation_only_repeat | 47,123 | 47,123 | 47,123 | 47,123 | 47,123 |
| baseline | equal | surplus_repeat | 52,637 | 52,637 | 52,637 | 52,637 | 52,637 |
| weighted_optimized | all profiles | reservation_only_first | 48,865 | 48,865 | 48,865 | 48,865 | 48,865 |
| weighted_optimized | all profiles | reservation_only_repeat | 48,865 | 48,865 | 48,865 | 48,865 | 48,865 |
| weighted_optimized | all profiles | surplus_repeat | 54,379 | 54,379 | 54,379 | 54,379 | 54,379 |
| weighted_reference | all profiles | reservation_only_first | 90,068 | 97,529 | 109,964 | 134,834 | 209,444 |
| weighted_reference | all profiles | reservation_only_repeat | 74,295 | 80,429 | 92,864 | 117,734 | 192,344 |
| weighted_reference | all profiles | surplus_repeat | 76,634 | 83,353 | 95,788 | 120,658 | 195,268 |

| Implementation | Path | Min across matrix | Max across matrix | Max N range per profile | Max profile range per N |
| --- | --- | --- | --- | --- | --- |
| baseline | reservation_only_first | 47,123 | 47,123 | 0 | 0 |
| baseline | reservation_only_repeat | 47,123 | 47,123 | 0 | 0 |
| baseline | surplus_repeat | 52,637 | 52,637 | 0 | 0 |
| weighted_optimized | reservation_only_first | 48,865 | 48,865 | 0 | 0 |
| weighted_optimized | reservation_only_repeat | 48,865 | 48,865 | 0 | 0 |
| weighted_optimized | surplus_repeat | 54,379 | 54,379 | 0 | 0 |
| weighted_reference | reservation_only_first | 90,068 | 209,444 | 119,376 | 0 |
| weighted_reference | reservation_only_repeat | 74,295 | 192,344 | 118,049 | 0 |
| weighted_reference | surplus_repeat | 76,634 | 195,268 | 118,634 | 0 |

Weighted optimized overhead versus baseline (range across N/profiles):

| Path | Additional gas | Additional percent of baseline |
| --- | --- | --- |
| reservation_only_first | 1,742–1,742 | 3.6967–3.6967% |
| reservation_only_repeat | 1,742–1,742 | 3.6967–3.6967% |
| surplus_repeat | 1,742–1,742 | 3.3095–3.3095% |

Exactly constant measured optimized gas supports O(1) empirical hot-path flatness. It is a higher constant than baseline and does not mathematically prove complexity. Reference linear fits:

| Profile | Path | a | b (gas/N) | R² |
| --- | --- | --- | --- | --- |
| all profiles | reservation_only_first | 85094.000000 | 2487.000000 | 1.000000000000 |
| all profiles | reservation_only_repeat | 68494.077218 | 2473.512804 | 0.999877784826 |
| all profiles | surplus_repeat | 71197.621172 | 2479.458553 | 0.999961968603 |

## Boundary-payment results

surplus_first uses remaining reservation+1 after two reservation-only payments. Every recorded row has from_surplus=1. Each implementation/profile/N has one sample, so its amount/gas min=max in the derived CSV. Amounts below are exact; the final column is the gas range across N for that profile.

| Implementation | Profile | Amount N=2 | Amount N=5 | Amount N=10 | Amount N=20 | Amount N=50 | Gas range |
| --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | equal | 249,998,000,001 | 99,998,000,001 | 49,998,000,001 | 24,998,000,001 | 9,998,000,001 | 69,823–69,823 |
| weighted_optimized | equal | 249,998,000,001 | 99,998,000,001 | 49,998,000,001 | 24,998,000,001 | 9,998,000,001 | 71,565–71,565 |
| weighted_optimized | mild_skew | 333,331,333,334 | 71,426,571,429 | 66,664,666,668 | 33,331,333,334 | 13,331,333,334 | 71,553–71,565 |
| weighted_optimized | high_skew | 333,331,333,334 | 166,664,666,668 | 90,907,090,910 | 47,617,047,620 | 19,605,843,138 | 71,565–71,565 |
| weighted_optimized | dominant | 497,510,437,812 | 496,029,746,033 | 495,538,138,752 | 495,292,700,348 | 495,145,553,972 | 71,565–71,565 |
| weighted_reference | equal | 249,998,000,001 | 99,998,000,001 | 49,998,000,001 | 24,998,000,001 | 9,998,000,001 | 92,954–212,330 |
| weighted_reference | mild_skew | 333,331,333,334 | 71,426,571,429 | 66,664,666,668 | 33,331,333,334 | 13,331,333,334 | 92,954–212,318 |
| weighted_reference | high_skew | 333,331,333,334 | 166,664,666,668 | 90,907,090,910 | 47,617,047,620 | 19,605,843,138 | 92,954–212,330 |
| weighted_reference | dominant | 497,510,437,812 | 496,029,746,033 | 495,538,138,752 | 495,292,700,348 | 495,145,553,972 | 92,954–212,330 |

Optimized weighted boundary gas spans 71,553–71,565: a 12 gas range (0.01677% of the matrix mean). This is a small measured variation, not exact constancy. No material gas change is observed at that scale, but this variable-amount path is not primary evidence for fixed-payment flatness. Calldata amounts vary; no causal attribution of individual differences is established.

## Weight-profile sensitivity

Deployment spread=(max−min); percentage denominator is the four-profile mean. Tied extrema are listed explicitly.

| Implementation | N | Min | Max | Range | Spread / mean | Cheapest | Most expensive |
| --- | --- | --- | --- | --- | --- | --- | --- |
| weighted_optimized | 2 | 842,108 | 842,134 | 26 | 0.0031% | mild_skew, high_skew, dominant | equal |
| weighted_optimized | 5 | 994,383 | 995,335 | 952 | 0.0957% | high_skew | equal |
| weighted_optimized | 10 | 1,258,921 | 1,265,051 | 6,130 | 0.4855% | high_skew | equal |
| weighted_optimized | 20 | 1,830,940 | 1,858,200 | 27,260 | 1.4756% | high_skew | equal |
| weighted_optimized | 50 | 3,885,608 | 4,066,258 | 180,650 | 4.5187% | high_skew | equal |
| weighted_reference | 2 | 857,973 | 859,059 | 1,086 | 0.1265% | equal | dominant |
| weighted_reference | 5 | 1,008,981 | 1,012,676 | 3,695 | 0.3654% | equal | high_skew |
| weighted_reference | 10 | 1,270,444 | 1,290,595 | 20,151 | 1.5706% | equal | dominant |
| weighted_reference | 20 | 1,830,015 | 1,884,472 | 54,457 | 2.9229% | equal | mild_skew |
| weighted_reference | 50 | 3,800,986 | 4,258,585 | 457,599 | 11.2313% | equal | dominant |

For each fixed optimized payment regime, all four profiles have identical gas at every measured N (profile range zero, as independently computed above). Gas sensitivity says nothing about fairness or allocation quality.

The optimized high_skew constructor is cheaper than equal at every measured N. Established code-level contributors that could affect profile cost include remainder-comparison branch outcomes and remainder-award counts; these are possible contributors, not an isolated causal explanation of the individual gas differences. No targeted attribution experiment was performed.

## Optimized vs reference

Reference−optimized signed deployment deltas (percentage of optimized gas); negative values mean the reference is cheaper:

| Profile | N=2 | N=5 | N=10 | N=20 | N=50 |
| --- | --- | --- | --- | --- | --- |
| equal | +15,839 (+1.88%) | +13,646 (+1.37%) | +5,393 (+0.43%) | -28,185 (-1.52%) | -265,272 (-6.52%) |
| mild_skew | +16,943 (+2.01%) | +17,985 (+1.81%) | +23,643 (+1.87%) | +40,032 (+2.17%) | +143,220 (+3.60%) |
| high_skew | +16,943 (+2.01%) | +18,293 (+1.84%) | +26,603 (+2.11%) | +53,460 (+2.92%) | +233,220 (+6.00%) |
| dominant | +16,951 (+2.01%) | +16,039 (+1.61%) | +26,014 (+2.06%) | -2,401 (-0.13%) | +194,829 (+4.79%) |

Reference deployment is cheaper only in the following measured configurations:

| Profile | N | Optimized | Reference | Reference saving | Saving / optimized |
| --- | --- | --- | --- | --- | --- |
| equal | 20 | 1,858,200 | 1,830,015 | 28,185 | 1.5168% |
| equal | 50 | 4,066,258 | 3,800,986 | 265,272 | 6.5237% |
| dominant | 20 | 1,855,858 | 1,853,457 | 2,401 | 0.1294% |

These are sampled crossovers: no exact crossover N between sampled points is inferred. In the other measured configurations reference deployment is more expensive. Reference construction uses selection-style awards and plain storage, rather than optimized remainder-rank counting and runtime-friendly packed state; neither architecture makes one constructor universally cheaper.

Reference fixed-payment overhead versus optimized across all measured N/profiles:

| Path | Reference additional gas | Additional percent / optimized |
| --- | --- | --- |
| reservation_only_first | 41,203–160,579 | 84.32–328.62% |
| reservation_only_repeat | 25,430–143,479 | 52.04–293.62% |
| surplus_repeat | 22,255–140,889 | 40.93–259.09% |

The optimized payment has no delegate scan. The independent reference correctness fixture uses plain storage and a linear index lookup; payer N−1 traverses the ordered array. This explains the established structural scaling expectation, but does not isolate individual instruction/storage costs. The reference is not a production optimization target.

## Hypothesis evaluation

| Hypothesis | Verdict | Quantitative evidence / interpretation |
| --- | --- | --- |
| H1 | SUPPORTED | Optimized linear slopes 63,896.80–67,792.33 gas/N versus baseline 24,971.53; quadratic coefficients and R² are tabulated above as supporting architectural evidence. |
| H2 | PARTIALLY SUPPORTED | Fixed optimized payment overhead ranges from 1,742 to 1,742 gas. The extra reservation-slot read is established architecture, but this experiment does not isolate its causal share of the total overhead. |
| H3 | SUPPORTED | Exact optimized fixed-regime constancy across N and profiles: True. Empirical O(1) hot-path flatness is distinct from identical baseline gas and from a complexity proof. |
| H4 | SUPPORTED | Optimized deployment profile ranges are 26, 952, 6,130, 27,260, 180,650 gas in ascending N order. |
| H5 | SUPPORTED | Every reference fixed-payment series strictly increases with N: True; fitted slopes and R² are tabulated above. Payer N−1 exercises the full linear lookup. |

All verdicts are empirical over the measured N/profile/rho domain.

## Limitations

Five N values, four deterministic positive-weight profiles, rho=1/2, one budget/window and the last registered payer; these measurements do not establish performance for every configuration, zero weights, rho endpoints, other caller indices, token implementations or chains. Two identical deterministic runs establish repeatability, not statistical error bars. Curve fitting supports architectural expectations, not complexity proofs. Receipt gas includes transaction/calldata costs and the token environment. Boundary amounts vary and are separate. Existing lastCallGas() deprecation in test/WeightedStorageAudit.t.sol is unrelated to this receipt dataset and remains unchanged. No benchmark, contract, accepted test, configuration or frozen evidence was modified.

## Provenance

Measured contract-source revision: `a8ebb2702e31b9c37722b17e2a9ab7653ee40058`. Benchmark harness + canonical result commit: `eb56c2c5d61f303f25ad38a463c3f91af9b23d68`. The environment manifest records a8ebb270 because that was the accepted contract source checked out when measurements were produced; eb56c2c subsequently committed the benchmark tooling and canonical artifacts. The environment JSON is preserved verbatim.

Input SHA-256 fingerprints (also checked for unchanged bytes during generation):

| Input | SHA-256 |
| --- | --- |
| weighted_gas_sweep.csv | 36f0d74e83e2cfb2c0864710f8de2cae9ba518c7e02e1d5597faa350d4f1311d |
| weighted_gas_summary.csv | 042d836e300f22caadb73a71bf2cdb9a8349b50440539b445656d7ac1eec71ed |
| weighted_gas_environment.json | 18ee16626463d1a91accced170888a58d53d82d30090c201580dd6e9bb6ca388 |
| weighted_gas_reproducibility.json | c140515cfb399ff50a5f65528d847d43e70d4046b55df4dc7a4814ca8f6fc863 |
| container_2026-09-30/gas_sweep.csv | b3ff1d857a52b409e52b7e929b781ce7e5a2e3c4bc4abcc4496edb2ec2a453d7 |

Derived outputs: weighted_gas_analysis.csv, weighted_gas_deployment.png, weighted_gas_payments.png, weighted_gas_analysis.md. Rerun with the documented dependency versions for deterministic regeneration.
