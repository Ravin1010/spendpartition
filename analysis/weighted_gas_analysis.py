"""Offline Iteration 7 analysis; never broadcasts or writes canonical benchmark inputs.

Run: python3 analysis/weighted_gas_analysis.py
Dependencies used for canonical regeneration: numpy==2.3.5, matplotlib==3.10.8.
CSV metric values retain numerical precision; Markdown rounds only for presentation.
"""
import csv
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "results"
NS = (2, 5, 10, 20, 50)
PROFILES = ("equal", "mild_skew", "high_skew", "dominant")
IMPLS = ("baseline", "weighted_optimized", "weighted_reference")
FIXED = ("reservation_only_first", "reservation_only_repeat", "surplus_repeat")
PATHS = ("deploy", *FIXED[:2], "surplus_first", FIXED[2])
SOURCE = "a8ebb2702e31b9c37722b17e2a9ab7653ee40058"
BENCHMARK = "eb56c2c5d61f303f25ad38a463c3f91af9b23d68"
INPUTS = ("weighted_gas_sweep.csv", "weighted_gas_summary.csv", "weighted_gas_environment.json",
          "weighted_gas_reproducibility.json", "container_2026-09-30/gas_sweep.csv")


def require(condition, message):
    if not condition:
        raise ValueError(f"Canonical benchmark inconsistency: {message}; do not replace the benchmark")


def read_csv(name):
    with (OUT / name).open(newline="") as f:
        return list(csv.DictReader(f))


def vector(n, profile):
    return [1 if profile == "equal" else 1 + i % 2 if profile == "mild_skew" else
            i + 1 if profile == "high_skew" else 100 * n if i == n - 1 else 1 for i in range(n)]


def load():
    raw = read_csv(INPUTS[0])
    summary = read_csv(INPUTS[1])
    env = json.loads((OUT / INPUTS[2]).read_text())
    repro = json.loads((OUT / INPUTS[3]).read_text())
    require(len(raw) == 225, f"expected 225 raw rows, got {len(raw)}")
    expected = {("baseline", n, "equal") for n in NS} | {
        (impl, n, p) for impl in IMPLS[1:] for n in NS for p in PROFILES}
    require(len({(r['implementation'], int(r['n']), r['profile']) for r in raw}) == 45,
            "expected 45 configurations")
    data = {}
    for row in raw:
        impl, n, p, path = row['implementation'], int(row['n']), row['profile'], row['path']
        key = impl, n, p, path
        require(key not in data, f"duplicate row {key}")
        require((impl, n, p) in expected and path in PATHS, f"unexpected matrix key {key}")
        require(json.loads(row['weights']) == vector(n, p), f"weights {key}")
        require(row['rho'] == '1/2' and int(row['budget']) == 10**12 and int(row['window_s']) == 86400,
                f"configuration {key}")
        require(int(row['gas_used']) > 0 and int(row['block_gas_limit']) == env['block_gas_limit'], f"gas {key}")
        require(row['raised_local_limit'] == str(env['raised_local_limit']), f"block limit flag {key}")
        if path == 'deploy':
            require(row['event'] == 'deploy' and row['amount'] == '' and row['from_surplus'] == '', f"deployment {key}")
        else:
            ordinal = PATHS.index(path)
            require(row['event'] == 'pay' and int(row['payer_idx']) == n - 1 and int(row['ordinal']) == ordinal
                    and int(row['window_id']) == 0, f"payment identity {key}")
            amount = int(row['reservation']) - 2 * 10**6 + 1 if path == 'surplus_first' else 10**6
            surplus = 1 if path == 'surplus_first' else 10**6 if path == 'surplus_repeat' else 0
            require(int(row['amount']) == amount and int(row['from_surplus']) == surplus, f"amount/path {key}")
        data[key] = row
    require(set(data) == {(*cfg, path) for cfg in expected for path in PATHS}, "incomplete matrix")
    for cfg in expected:
        rows = [data[(*cfg, path)] for path in PATHS]
        require(len({r['contract_address'] for r in rows}) == 1 and len({r['reservation'] for r in rows}) == 1,
                f"configuration state {cfg}")
    require(len(summary) == 225, "expected 225 summary groups")
    seen = set()
    for s in summary:
        key = s['implementation'], int(s['n']), s['profile'], s['path']
        require(key in data and key not in seen, f"summary key {key}")
        seen.add(key)
        r = data[key]
        require(int(s['samples']) == 1 and all(float(s[x]) == int(r['gas_used'])
                                             for x in ('gas_min', 'gas_median', 'gas_max')), f"summary gas {key}")
        require(all(s[x] == r[x] for x in ('weights', 'amount', 'from_surplus')), f"summary fields {key}")
    require(env['source_commit'] == SOURCE and env['solc_version'] == '0.8.30' and env['evm_version'] == 'prague'
            and env['optimizer'] and env['optimizer_runs'] == 200 and not env['via_ir']
            and 'Version: 1.8.4' in env['forge'], "environment")
    require(repro['rows_per_run'] == 225 and repro['configurations_per_run'] == 45
            and repro['gas_used_and_observed_paths_identical'], "reproducibility counts")
    ignored = set(repro['excluded_fields'])
    normalized = [{k: v for k, v in r.items() if k not in ignored} for r in raw]
    digest = hashlib.sha256(json.dumps(normalized, sort_keys=True).encode()).hexdigest()
    raw_digest = hashlib.sha256((OUT / INPUTS[0]).read_bytes()).hexdigest()
    require(digest == repro['first_normalized_sha256'] == repro['second_normalized_sha256'], "normalized hashes")
    require(raw_digest == repro['first_raw_csv_sha256'] == repro['second_raw_csv_sha256'], "raw hashes")
    for p in PROFILES:
        require(all(env['profiles'][p][str(n)] == vector(n, p) for n in NS), f"manifest profile {p}")
    # Compare only equivalent same-window, fixed-amount archived baseline rows.
    frozen = read_csv(INPUTS[4])
    matches = []
    for key, row in data.items():
        impl, n, _, path = key
        if impl != 'baseline' or path not in ('deploy', *FIXED):
            continue
        old = [r for r in frozen if r['impl'] == 'optimized' and int(r['n']) == n and r['rho'] == '1/2'
               and r['window_s'] == '86400' and r['event'] == row['event']
               and (path == 'deploy' or (r['payer_idx'] == row['payer_idx'] and r['amount'] == row['amount']
                    and r['window_id'] == '0' and r['agent_regime'] == 'same_window'
                    and ((path == 'surplus_repeat' and r['path'] == 'surplus_same_window')
                         or (path in FIXED[:2] and r['path'] == 'reservation_only' and r['ordinal'] == row['ordinal']))))]
        if old:
            require({int(r['gas_used']) for r in old} == {int(row['gas_used'])}, f"baseline comparison {key}")
            matches.append(key)
    require(len(matches) == 17, f"expected 17 equivalent baseline rows, got {len(matches)}")
    return data, env, repro, matches


def fit(xs, ys, degree):
    x, y = np.array(xs, dtype=float), np.array(ys, dtype=float)
    design = np.column_stack([x**power for power in range(degree + 1)])
    coefficients = np.linalg.lstsq(design, y, rcond=None)[0]
    residual = np.sum((y - design @ coefficients)**2)
    total = np.sum((y - np.mean(y))**2)
    return tuple(float(v) for v in coefficients), float(1 - residual / total) if total else None


def table(headers, rows):
    return '\n'.join(['| ' + ' | '.join(headers) + ' |', '| ' + ' | '.join('---' for _ in headers) + ' |']
                     + ['| ' + ' | '.join(map(str, r)) + ' |' for r in rows])


def main():
    before = {p: hashlib.sha256((OUT / p).read_bytes()).hexdigest() for p in INPUTS}
    data, env, repro, sanity = load()
    metrics = []
    def metric(section, impl, n, profile, path, name, value, unit='gas', denominator=''):
        metrics.append(dict(section=section, implementation=impl, n=n, profile=profile, path=path,
                            metric=name, value=value, unit=unit, denominator=denominator))
    def gas(impl, n, profile, path='deploy'):
        return int(data[impl, n, profile, path]['gas_used'])
    def profiles(impl):
        return ('equal',) if impl == 'baseline' else PROFILES
    def series(impl, p, path='deploy'):
        return [gas(impl, n, p, path) for n in NS]
    def fmt(v):
        return f'{v:,}'
    deployment, overhead, spreads, fits, crossovers, deployment_gaps = [], [], [], [], [], []
    for impl in IMPLS:
        for p in profiles(impl):
            ys = series(impl, p)
            deployment.append([impl, p, *map(fmt, ys)])
            for n, y in zip(NS, ys):
                metric('deployment', impl, n, p, 'deploy', 'gas_used', y)
                if impl == 'weighted_optimized':
                    base = gas('baseline', n, 'equal')
                    metric('deployment', impl, n, p, 'deploy', 'overhead_vs_baseline', y-base)
                    metric('deployment', impl, n, p, 'deploy', 'overhead_vs_baseline_pct', 100*(y-base)/base, '%', 'baseline gas')
                if impl == 'weighted_reference':
                    opt = gas('weighted_optimized', n, p)
                    metric('comparison', impl, n, p, 'deploy', 'reference_minus_optimized', y-opt)
                    metric('comparison', impl, n, p, 'deploy', 'reference_minus_optimized_pct', 100*(y-opt)/opt, '%', 'optimized gas')
                    if y < opt:
                        crossovers.append([p, n, fmt(opt), fmt(y), fmt(opt-y), f'{100*(opt-y)/opt:.4f}%'])
            degrees = (1, 2) if impl == 'weighted_optimized' else (1,)
            for degree in degrees:
                coefficients, r2 = fit(NS, ys, degree)
                for name, value in zip(('a', 'b', 'c'), coefficients):
                    metric('fit', impl, '', p, 'deploy', f'degree_{degree}_{name}', value,
                           'gas' if name == 'a' else 'gas/N' if name == 'b' else 'gas/N^2')
                metric('fit', impl, '', p, 'deploy', f'degree_{degree}_r_squared', r2, 'dimensionless')
                fits.append([impl, p, 'linear' if degree == 1 else 'quadratic',
                             *(f'{v:.6f}' for v in coefficients), *(['—'] if degree == 1 else []), f'{r2:.12f}'])
    for p in PROFILES:
        overhead.append([p, *[f'{gas("weighted_optimized",n,p)-gas("baseline",n,"equal"):,} '
                                  f'({100*(gas("weighted_optimized",n,p)-gas("baseline",n,"equal"))/gas("baseline",n,"equal"):.2f}%)'
                                  for n in NS]])
        deployment_gaps.append([p, *[f'{gas("weighted_reference",n,p)-gas("weighted_optimized",n,p):+,} '
                                      f'({100*(gas("weighted_reference",n,p)-gas("weighted_optimized",n,p))/gas("weighted_optimized",n,p):+.2f}%)'
                                      for n in NS]])
    for impl in IMPLS[1:]:
        for n in NS:
            vals = {p: gas(impl,n,p) for p in PROFILES}
            low, high, mean = min(vals.values()), max(vals.values()), np.mean(list(vals.values()))
            cheapest = ', '.join(p for p in PROFILES if vals[p] == low)
            dearest = ', '.join(p for p in PROFILES if vals[p] == high)
            for name, value, unit, denom in [('profile_min',low,'gas',''), ('profile_max',high,'gas',''),
                    ('profile_mean',float(mean),'gas',''), ('profile_range',high-low,'gas',''),
                    ('profile_spread_pct',100*(high-low)/mean,'%','profile mean'),
                    ('cheapest_profiles',cheapest,'profile',''), ('most_expensive_profiles',dearest,'profile','')]:
                metric('profile_spread',impl,n,'all','deploy',name,value,unit,denom)
            spreads.append([impl,n,fmt(low),fmt(high),fmt(high-low),f'{100*(high-low)/mean:.4f}%',cheapest,dearest])
    payments, payment_ranges, payment_fits, reference_gaps = [], [], [], []
    for impl in IMPLS:
        for path in FIXED:
            vals = [gas(impl,n,p,path) for n in NS for p in profiles(impl)]
            profile_spread = max(max(gas(impl,n,p,path) for p in profiles(impl))
                                 - min(gas(impl,n,p,path) for p in profiles(impl)) for n in NS)
            n_spread = max(max(series(impl,p,path))-min(series(impl,p,path)) for p in profiles(impl))
            for name, value, unit in [('min_all',min(vals),'gas'), ('max_all',max(vals),'gas'),
                    ('max_range_across_n',n_spread,'gas'), ('max_range_across_profiles',profile_spread,'gas'),
                    ('exactly_constant_all',int(min(vals)==max(vals)),'boolean')]:
                metric('payment_range',impl,'all','all',path,name,value,unit)
            payment_ranges.append([impl,path,fmt(min(vals)),fmt(max(vals)),fmt(n_spread),fmt(profile_spread)])
            same_profiles = profile_spread == 0
            for p in profiles(impl):
                if not same_profiles or p == 'equal':
                    payments.append([impl,'all profiles' if same_profiles and impl!='baseline' else p,path,*map(fmt,series(impl,p,path))])
                for n in NS:
                    y = gas(impl,n,p,path)
                    metric('fixed_payment',impl,n,p,path,'gas_used',y)
                    if impl == 'weighted_optimized':
                        base = gas('baseline',n,'equal',path)
                        metric('fixed_payment',impl,n,p,path,'overhead_vs_baseline',y-base)
                        metric('fixed_payment',impl,n,p,path,'overhead_vs_baseline_pct',100*(y-base)/base,'%', 'baseline gas')
                    if impl == 'weighted_reference':
                        opt = gas('weighted_optimized',n,p,path)
                        metric('comparison',impl,n,p,path,'reference_minus_optimized',y-opt)
                        metric('comparison',impl,n,p,path,'reference_minus_optimized_pct',100*(y-opt)/opt,'%', 'optimized gas')
                if impl == 'weighted_reference':
                    coefficients,r2=fit(NS,series(impl,p,path),1)
                    for name,value,unit in [('a',coefficients[0],'gas'),('b',coefficients[1],'gas/N'),('r_squared',r2,'dimensionless')]:
                        metric('fit',impl,'',p,path,name,value,unit)
                    if not same_profiles or p=='equal':
                        payment_fits.append(['all profiles' if same_profiles else p,path,f'{coefficients[0]:.6f}',f'{coefficients[1]:.6f}',f'{r2:.12f}'])
            if impl=='weighted_reference':
                deltas=[gas(impl,n,p,path)-gas('weighted_optimized',n,p,path) for n in NS for p in PROFILES]
                percents=[100*(gas(impl,n,p,path)-gas('weighted_optimized',n,p,path))/gas('weighted_optimized',n,p,path) for n in NS for p in PROFILES]
                reference_gaps.append([path,f'{min(deltas):,}–{max(deltas):,}',f'{min(percents):.2f}–{max(percents):.2f}%'])
    fixed_overhead=[]
    for path in FIXED:
        deltas=[gas('weighted_optimized',n,p,path)-gas('baseline',n,'equal',path) for n in NS for p in PROFILES]
        percents=[100*(gas('weighted_optimized',n,p,path)-gas('baseline',n,'equal',path))
                  /gas('baseline',n,'equal',path) for n in NS for p in PROFILES]
        fixed_overhead.append([path,f'{min(deltas):,}–{max(deltas):,}',f'{min(percents):.4f}–{max(percents):.4f}%'])
    boundary=[]
    for impl in IMPLS:
        for p in profiles(impl):
            amounts=[]; vals=[]
            for n in NS:
                r=data[impl,n,p,'surplus_first']; amount=int(r['amount']); y=int(r['gas_used'])
                amounts.append(fmt(amount));vals.append(y)
                for name,value,unit in [('amount_min',amount,'token units'),('amount_max',amount,'token units'),
                                        ('gas_min',y,'gas'),('gas_max',y,'gas'),('from_surplus',int(r['from_surplus']),'token units')]:
                    metric('boundary',impl,n,p,'surplus_first',name,value,unit)
            boundary.append([impl,p,*amounts,f'{min(vals):,}–{max(vals):,}'])
    opt_boundary=[gas('weighted_optimized',n,p,'surplus_first') for n in NS for p in PROFILES]
    boundary_pct=100*(max(opt_boundary)-min(opt_boundary))/np.mean(opt_boundary)
    metric('boundary','weighted_optimized','all','all','surplus_first','spread_pct',float(boundary_pct),'%','matrix mean')
    baseline_slope=fit(NS,series('baseline','equal'),1)[0][1]
    opt_linear=[fit(NS,series('weighted_optimized',p),1)[0][1] for p in PROFILES]
    opt_spreads=[max(gas('weighted_optimized',n,p) for p in PROFILES)-min(gas('weighted_optimized',n,p) for p in PROFILES) for n in NS]
    # Verdicts are computed from the observed matrix, not presumed from architecture.
    faster_growth=all(slope > baseline_slope for slope in opt_linear)
    payment_deltas=[gas('weighted_optimized',n,p,path)-gas('baseline',n,'equal',path)
                    for n in NS for p in PROFILES for path in FIXED]
    constant_payments=all(len({gas('weighted_optimized',n,p,path) for n in NS for p in PROFILES}) == 1
                          for path in FIXED)
    increasing_reference=all(all(a < b for a,b in zip(series('weighted_reference',p,path),
                                                      series('weighted_reference',p,path)[1:]))
                             for p in PROFILES for path in FIXED)
    hypotheses=[
        ('H1','SUPPORTED' if faster_growth else 'NOT SUPPORTED',f'Optimized linear slopes {min(opt_linear):,.2f}–{max(opt_linear):,.2f} gas/N versus baseline {baseline_slope:,.2f}; quadratic coefficients and R² are tabulated above as supporting architectural evidence.'),
        ('H2','PARTIALLY SUPPORTED' if min(payment_deltas)>0 and constant_payments else 'NOT SUPPORTED',f'Fixed optimized payment overhead ranges from {min(payment_deltas):,} to {max(payment_deltas):,} gas. The extra reservation-slot read is established architecture, but this experiment does not isolate its causal share of the total overhead.'),
        ('H3','SUPPORTED' if constant_payments else 'NOT SUPPORTED',f'Exact optimized fixed-regime constancy across N and profiles: {constant_payments}. Empirical O(1) hot-path flatness is distinct from identical baseline gas and from a complexity proof.'),
        ('H4','SUPPORTED' if any(opt_spreads) else 'NOT SUPPORTED',f'Optimized deployment profile ranges are {", ".join(map(fmt,opt_spreads))} gas in ascending N order.'),
        ('H5','SUPPORTED' if increasing_reference else 'NOT SUPPORTED',f'Every reference fixed-payment series strictly increases with N: {increasing_reference}; fitted slopes and R² are tabulated above. Payer N−1 exercises the full linear lookup.')]
    for h,status,evidence in hypotheses:
        metric('hypothesis','','','','',h,status,'verdict')
    for impl,n,p,path in sanity:
        metric('baseline_sanity',impl,n,p,path,'difference_vs_frozen',0)
    # Auditable long-form metrics include every paired comparison and each boundary amount.
    with (OUT/'weighted_gas_analysis.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(metrics[0]),lineterminator='\n');writer.writeheader();writer.writerows(metrics)
    figures(data)
    report = [
        '# Weighted Gas Analysis',
        '## Dataset and methodology',
        f'Offline command: `python3 analysis/weighted_gas_analysis.py`. Python dependencies for these artifacts: NumPy {np.__version__}, Matplotlib {matplotlib.__version__}. The script validates 45 configurations / 225 raw rows, cross-checks the summary, environment and reproduction hashes, and derives every numerical table from committed inputs. It never runs Anvil or rewrites source data.',
        f'Receipt `gasUsed` measures each separate broadcast transaction. N={list(NS)}, rho=1/2, budget=1e12, window=86400 seconds; registered payer N−1; merchant starts with a nonzero token balance. Foundry v1.8.4, Solidity {env["solidity"]}, Prague, optimizer enabled (200 runs), via_ir=false. Normal local block limit {env["block_gas_limit"]:,}; raised-limit flag: {env["raised_local_limit"]}.',
        'Profiles: equal w[i]=1; mild_skew w[i]=1 for even i and 2 for odd i; high_skew w[i]=i+1; dominant all weights 1 except w[N−1]=100*N. Full vectors remain in the canonical CSVs. N=2 mild/high intentionally have the same vector.',
        f'{len(sanity)} methodologically equivalent baseline-control rows match the September 30 archived evidence exactly (5 deployments, 10 reservation-only, 2 surplus-repeat). Variable boundary amounts are excluded from that comparison. The accepted reproduction record reports {repro["rows_per_run"]} identical rows across two fresh runs; this analysis verifies its hashes without rerunning the benchmark.',
        'Units are gas unless stated otherwise; percent overhead uses baseline gas, reference comparison uses optimized gas, and profile spread uses the four-profile arithmetic mean. `weighted_gas_analysis.csv` retains full numerical precision and paired per-configuration metrics. These PNGs are measured curves, not fit extrapolations.',
        '## Deployment results',
        table(['Implementation','Profile',*[f'N={n}' for n in NS]],deployment),
        'Weighted optimized overhead versus baseline: absolute gas (percent of baseline gas).',
        table(['Profile',*[f'N={n}' for n in NS]],overhead),
        'Least-squares fits: linear gas=a+bN; quadratic gas=a+bN+cN². R²=1−SSE/SST. Each fit uses five measured points. Reference deployment is fitted separately as a descriptive linear trend, not assumed linear architecture.',
        table(['Implementation','Profile','Model','a','b (gas/N)','c (gas/N²)','R²'],fits),
        'The baseline is nearly linear. Optimized quadratic fits describe the observed curves more closely than linear fits, consistent with constructor-only O(N²) remainder-rank counting plus stored runtime reservations. A five-point quadratic fit does not prove asymptotic complexity; no extrapolation is made.',
        '## Fixed-payment results',
        'Only reservation_only_first, reservation_only_repeat and surplus_repeat are compared here, each amount=1e6. The first two have from_surplus=0; surplus_repeat has from_surplus=1e6 after surplus accounting is active. The window and payer are unchanged.',
        table(['Implementation','Profile','Path',*[f'N={n}' for n in NS]],payments),
        table(['Implementation','Path','Min across matrix','Max across matrix','Max N range per profile','Max profile range per N'],payment_ranges),
        'Weighted optimized overhead versus baseline (range across N/profiles):',
        table(['Path','Additional gas','Additional percent of baseline'],fixed_overhead),
        'Exactly constant measured optimized gas supports O(1) empirical hot-path flatness. It is a higher constant than baseline and does not mathematically prove complexity. Reference linear fits:',
        table(['Profile','Path','a','b (gas/N)','R²'],payment_fits),
        '## Boundary-payment results',
        'surplus_first uses remaining reservation+1 after two reservation-only payments. Every recorded row has from_surplus=1. Each implementation/profile/N has one sample, so its amount/gas min=max in the derived CSV. Amounts below are exact; the final column is the gas range across N for that profile.',
        table(['Implementation','Profile',*[f'Amount N={n}' for n in NS],'Gas range'],boundary),
        f'Optimized weighted boundary gas spans {min(opt_boundary):,}–{max(opt_boundary):,}: a {max(opt_boundary)-min(opt_boundary):,} gas range ({boundary_pct:.5f}% of the matrix mean). This is a small measured variation, not exact constancy. No material gas change is observed at that scale, but this variable-amount path is not primary evidence for fixed-payment flatness. Calldata amounts vary; no causal attribution of individual differences is established.',
        '## Weight-profile sensitivity',
        'Deployment spread=(max−min); percentage denominator is the four-profile mean. Tied extrema are listed explicitly.',
        table(['Implementation','N','Min','Max','Range','Spread / mean','Cheapest','Most expensive'],spreads),
        'For each fixed optimized payment regime, all four profiles have identical gas at every measured N (profile range zero, as independently computed above). Gas sensitivity says nothing about fairness or allocation quality.',
        'The optimized high_skew constructor is cheaper than equal at every measured N. Established code-level contributors that could affect profile cost include remainder-comparison branch outcomes and remainder-award counts; these are possible contributors, not an isolated causal explanation of the individual gas differences. No targeted attribution experiment was performed.',
        '## Optimized vs reference',
        'Reference−optimized signed deployment deltas (percentage of optimized gas); negative values mean the reference is cheaper:',
        table(['Profile',*[f'N={n}' for n in NS]],deployment_gaps),
        'Reference deployment is cheaper only in the following measured configurations:',
        table(['Profile','N','Optimized','Reference','Reference saving','Saving / optimized'],crossovers),
        'These are sampled crossovers: no exact crossover N between sampled points is inferred. In the other measured configurations reference deployment is more expensive. Reference construction uses selection-style awards and plain storage, rather than optimized remainder-rank counting and runtime-friendly packed state; neither architecture makes one constructor universally cheaper.',
        'Reference fixed-payment overhead versus optimized across all measured N/profiles:',
        table(['Path','Reference additional gas','Additional percent / optimized'],reference_gaps),
        'The optimized payment has no delegate scan. The independent reference correctness fixture uses plain storage and a linear index lookup; payer N−1 traverses the ordered array. This explains the established structural scaling expectation, but does not isolate individual instruction/storage costs. The reference is not a production optimization target.',
        '## Hypothesis evaluation',
        table(['Hypothesis','Verdict','Quantitative evidence / interpretation'],hypotheses),
        'All verdicts are empirical over the measured N/profile/rho domain.',
        '## Limitations',
        'Five N values, four deterministic positive-weight profiles, rho=1/2, one budget/window and the last registered payer; these measurements do not establish performance for every configuration, zero weights, rho endpoints, other caller indices, token implementations or chains. Two identical deterministic runs establish repeatability, not statistical error bars. Curve fitting supports architectural expectations, not complexity proofs. Receipt gas includes transaction/calldata costs and the token environment. Boundary amounts vary and are separate. Existing lastCallGas() deprecation in test/WeightedStorageAudit.t.sol is unrelated to this receipt dataset and remains unchanged. No benchmark, contract, accepted test, configuration or frozen evidence was modified.',
        '## Provenance',
        f'Measured contract-source revision: `{SOURCE}`. Benchmark harness + canonical result commit: `{BENCHMARK}`. The environment manifest records a8ebb270 because that was the accepted contract source checked out when measurements were produced; eb56c2c subsequently committed the benchmark tooling and canonical artifacts. The environment JSON is preserved verbatim.',
        'Input SHA-256 fingerprints (also checked for unchanged bytes during generation):',
        table(['Input','SHA-256'],[[p,before[p]] for p in INPUTS]),
        'Derived outputs: weighted_gas_analysis.csv, weighted_gas_deployment.png, weighted_gas_payments.png, weighted_gas_analysis.md. Rerun with the documented dependency versions for deterministic regeneration.'
    ]
    (OUT/'weighted_gas_analysis.md').write_text('\n\n'.join(report)+'\n')
    require(before == {p: hashlib.sha256((OUT/p).read_bytes()).hexdigest() for p in INPUTS}, 'inputs changed during analysis')
    print(f'Validated 45 configurations / 225 rows; {len(metrics)} derived metrics; {len(sanity)} archived baseline matches.')
    print('Wrote analysis CSV, two PNGs and engineering memo; canonical inputs unchanged.')


def figures(data):
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'axes.titlesize':12,
                         'axes.labelsize':11,'legend.fontsize':9,'figure.dpi':120})
    colors=('#0072B2','#D55E00','#009E73','#CC79A7')
    markers=('o','s','^','D')
    def values(impl,p,path):
        return np.array([int(data[impl,n,p,path]['gas_used']) for n in NS])/1000
    def finish(axes):
        for ax in axes:
            ax.set_xlabel('Registered delegates, N');ax.set_xticks(NS);ax.set_ylim(bottom=0)
            ax.grid(True,alpha=.25);ax.set_axisbelow(True);ax.legend(frameon=False)
    fig,axes=plt.subplots(1,2,figsize=(12,4.6),sharey=True,layout='constrained')
    for ax,impl,title in zip(axes,IMPLS[1:],('Weighted optimized deployment','Weighted reference deployment')):
        ax.plot(NS,values('baseline','equal','deploy'),color='black',marker='x',linestyle='--',label='Baseline control')
        for p,c,m in zip(PROFILES,colors,markers):
            ax.plot(NS,values(impl,p,'deploy'),color=c,marker=m,markerfacecolor='none',label=p.replace('_',' '))
        ax.set_title(title);ax.set_ylabel('Transaction receipt gasUsed (thousands)')
    finish(axes)
    fig.suptitle('Deployment: rho=1/2, budget=1e12; measured transactions')
    fig.savefig(OUT/'weighted_gas_deployment.png',dpi=200,metadata={'Software':'weighted_gas_analysis.py'});plt.close(fig)
    fig,axes=plt.subplots(1,3,figsize=(14,4.6),sharey=True,layout='constrained')
    for ax,path in zip(axes,FIXED):
        for impl,c,m,label in [('baseline','black','x','Baseline control'),
                ('weighted_optimized',colors[0],'o','Weighted optimized'),
                ('weighted_reference',colors[1],'s','Weighted reference')]:
            ps=('equal',) if impl=='baseline' else PROFILES
            same=all(np.array_equal(values(impl,p,path),values(impl,'equal',path)) for p in ps)
            for p in (('equal',) if same else ps):
                ax.plot(NS,values(impl,p,path),color=c,marker=m,markerfacecolor='none',
                        label=label+(' (all profiles)' if same and impl!='baseline' else '' if impl=='baseline' else f' ({p})'))
        ax.set_title(path.replace('_',' ').capitalize())
    axes[0].set_ylabel('Transaction receipt gasUsed (thousands)');finish(axes)
    fig.suptitle('Fixed payments: amount=1e6, rho=1/2; boundary payments excluded')
    fig.savefig(OUT/'weighted_gas_payments.png',dpi=200,metadata={'Software':'weighted_gas_analysis.py'});plt.close(fig)


if __name__ == '__main__':
    main()
