#!/usr/bin/env python3
"""Whetstone swing log analyzer.

Reads a whetstone_swings.log produced by `/whet debug` and renders a
verdict per beta-checklist item:

    HIT_CEILING   observed miss rate vs the predicted ceiling, with a
                  Wilson 95% CI - settles the 95-vs-99 cap question
                  (only evaluated over swings logged AT the cap)
    HIT_RATE_POOLED  observed landed fraction over ALL swings vs the
                  pooled predicted hit rate (Wilson CI) - catches an
                  off accuracy model even far from the cap
    PDIF_BOUNDS   per-swing observed/base must fall inside the FINAL
                  predicted band (roll x 1.00-1.05 melee random; new
                  logs print it directly as pdif_final=, legacy
                  pdif_range= is normalized at parse). The spike is
                  exactly 1.0 x base - the source early-returns
                  BEFORE the multiplier - and is always legal even
                  below the band
    SPIKE         frequency of damage == exactly 1.0 x base vs the
                  predicted spike chance (~1/3 near wRatio 1.0)
    CRIT_RATE     observed crit frequency among landed swings vs the
                  predicted melee crit rate (GetCritHitRate path),
                  Wilson 95% CI - run on a singleton target so dDEX
                  is exact
    MELEE_MEAN    LANDED-to-LANDED: mean observed damage over landed
                  swings (hit + crit) vs predicted_landed (the
                  per-landed-swing crit-blended mean) - never compares
                  landed observations against the per-attempt mean
    WS_MEAN       per-WS observed mean vs prediction, ATTEMPT-to-
                  ATTEMPT: ws lines log every use including whiffs
                  (observed=0), matching predicted_mean which includes
                  hit rates; a consistent ~+10% excess on WSC-heavy
                  skills suggests the legacy alpha assumption is wrong

LINE SEMANTICS (must match swinglog.lua observe()):
    melee lines: one per swing RESULT. 'hit'/'crit' = landed (observed
    is the landed damage); 'miss' (legacy logs: 'other:15') logs
    observed=0. predicted_mean = per-ATTEMPT expectation (includes hit
    rate); predicted_landed = per-LANDED-swing mean (no hit rate).
    ws lines: one per USE. observed sums the landed hits (0 on a full
    whiff), hits=landed/rolled.
    Every line carries wall time plus a monotonic t=<seconds.ms>.

Each check reports PASS / FAIL / INSUFFICIENT_DATA with swing counts.
Pure stdlib; no scipy.

Usage:
    python3 tools/analyze_swings.py whetstone_swings.log
"""

from __future__ import annotations

import math
import re
import sys
from collections import defaultdict

# predicted_landed=, tp= and hits= are optional: older logs lack them
# and must keep parsing. Bounds come in two formats:
#   pdif_range=L-U   (<= v0.1.10): PRE-multiplier - the final band is
#                    [L * 1.00, U * 1.05] (the v0.1.10 field finding:
#                    observed ratios clustered at exactly U * 1.05)
#   pdif_final=L-U   (>= v0.1.11): POST-multiplier, used as-is
# parse_log() normalizes both into final-band lower/upper.
MELEE_RE = re.compile(
    r'melee (?P<outcome>\S+) observed=(?P<observed>\d+) '
    r'predicted_mean=(?P<mean>-?[\d.]+) '
    r'(?:predicted_landed=(?P<landed>-?[\d.]+) )?'
    r'base=(?P<base>-?\d+) spike=(?P<spike>-?[\d.]+) '
    r'(?:pdif_range=(?P<pre_lower>-?[\d.]+)-(?P<pre_upper>-?[\d.]+)'
    r'|pdif_final=(?P<fin_lower>-?[\d.]+)-(?P<fin_upper>-?[\d.]+)) '
    r'hit_rate=(?P<hit_rate>-?[\d.]+) '
    r'crit_rate=(?P<crit_rate>-?[\d.]+) target=(?P<target>.+)$')

WS_RE = re.compile(
    r'ws id=(?P<id>\d+) name=(?P<name>\S+) observed=(?P<observed>\d+) '
    r'predicted_mean=(?P<mean>\S+) '
    r'(?:tp=(?P<tp>\S+) )?'
    r'(?:hits=(?P<hits_landed>\d+)/(?P<hits_rolled>\d+) )?'
    r'target=(?P<target>.+)$')

MELEE_RANDOM_MAX = 1.05

# 'miss' since v0.1.8; 'other:15' in older logs (MSG_MISS was parsed
# but never labeled).
MISS_OUTCOMES = {'miss', 'other:15'}

# At the Phoenix cap the question is "is the ceiling 95 or 99": the CI
# must exclude the competing hypothesis to call it.
CAP_MISS_95 = 0.05
CAP_MISS_99 = 0.01


def wilson_interval(successes: int, total: int, z: float = 1.96):
    """Wilson score 95% CI for a binomial proportion."""
    if total == 0:
        return (0.0, 1.0)

    p = successes / total
    denom = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denom
    spread = (z / denom) * math.sqrt(
        p * (1 - p) / total + z * z / (4 * total * total))

    return (max(0.0, center - spread), min(1.0, center + spread))


def parse_log(text: str) -> dict:
    melee = []
    ws = []

    for line in text.splitlines():
        match = MELEE_RE.search(line)
        if match:
            row = match.groupdict()
            # normalize bounds to the FINAL band (post melee random)
            if row['fin_lower'] is not None:
                lower = float(row['fin_lower'])
                upper = float(row['fin_upper'])
            else:
                lower = float(row['pre_lower'])
                upper = float(row['pre_upper']) * MELEE_RANDOM_MAX

            melee.append({
                'outcome': row['outcome'],
                'observed': int(row['observed']),
                'mean': float(row['mean']),
                'landed_mean': None if row['landed'] is None
                               else float(row['landed']),
                'base': int(row['base']),
                'spike': float(row['spike']),
                'lower': lower,
                'upper': upper,
                'hit_rate': float(row['hit_rate']),
                'crit_rate': float(row['crit_rate']),
                'target': row['target'],
            })
            continue

        match = WS_RE.search(line)
        if match:
            row = match.groupdict()
            ws.append({
                'name': row['name'],
                'observed': int(row['observed']),
                'mean': None if row['mean'] == 'n/a'
                        else float(row['mean']),
                'tp': None if row['tp'] in (None, '?')
                      else int(row['tp']),
                'hits_landed': None if row['hits_landed'] is None
                               else int(row['hits_landed']),
                'hits_rolled': None if row['hits_rolled'] is None
                               else int(row['hits_rolled']),
                'target': row['target'],
            })

    return {'melee': melee, 'ws': ws}


def check_hit_ceiling(melee: list) -> dict:
    """Miss rate over swings logged at the predicted ceiling."""
    at_cap = [row for row in melee if row['hit_rate'] >= 0.94]
    total = len(at_cap)
    misses = sum(1 for row in at_cap if row['outcome'] in MISS_OUTCOMES)

    result = {'check': 'HIT_CEILING', 'swings': total, 'misses': misses}

    if total < 200:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = ('need >= 200 capped swings to separate '
                            '5%% from 1%% (have %d)' % total)
        return result

    low, high = wilson_interval(misses, total)
    result['ci'] = (low, high)
    result['rate'] = misses / total

    contains_95 = low <= CAP_MISS_95 <= high
    contains_99 = low <= CAP_MISS_99 <= high

    if contains_95 and not contains_99:
        result['verdict'] = 'PASS'
        result['detail'] = ('miss rate %.3f CI [%.3f, %.3f] consistent '
                            'with the 95%% ceiling, excludes 99%%'
                            % (result['rate'], low, high))
    elif contains_99 and not contains_95:
        result['verdict'] = 'FAIL'
        result['detail'] = ('miss rate %.3f CI [%.3f, %.3f] looks like '
                            'a 99%% ceiling - is the soa hit cap module '
                            'really enabled?' % (result['rate'], low, high))
    elif contains_95 and contains_99:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = ('CI [%.3f, %.3f] contains both hypotheses; '
                            'log more capped swings' % (low, high))
    else:
        result['verdict'] = 'FAIL'
        result['detail'] = ('miss rate %.3f CI [%.3f, %.3f] matches '
                            'NEITHER ceiling - check accuracy model '
                            'first' % (result['rate'], low, high))

    return result


def check_pdif_bounds(melee: list) -> dict:
    """Non-crit hits: observed/base must lie inside the predicted
    pre-randomizer bounds x [1.00, 1.05], with the spike (exactly base)
    always legal and +/-1 damage tolerance for the final floor."""
    hits = [row for row in melee
            if row['outcome'] == 'hit' and row['base'] > 0]

    result = {'check': 'PDIF_BOUNDS', 'swings': len(hits)}

    if len(hits) < 50:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = 'need >= 50 landed hits (have %d)' % len(hits)
        return result

    outliers = []

    for row in hits:
        # row bounds are already the FINAL band (parse_log normalizes
        # both line formats); the spike (exactly base, BELOW the band
        # when wRatio is high) is always legal
        low_dmg = math.floor(row['lower'] * row['base']) - 1
        high_dmg = math.floor(row['upper'] * row['base']) + 1

        is_spike = row['observed'] == row['base']

        if not is_spike and not (low_dmg <= row['observed'] <= high_dmg):
            outliers.append(row)

    fraction = len(outliers) / len(hits)
    result['outliers'] = len(outliers)

    if fraction <= 0.01:
        result['verdict'] = 'PASS'
        result['detail'] = ('%d/%d hits inside predicted bounds '
                            '(%.1f%% outliers)'
                            % (len(hits) - len(outliers), len(hits),
                               fraction * 100))
    else:
        sample = outliers[0]
        result['verdict'] = 'FAIL'
        result['detail'] = ('%.1f%% of hits outside predicted pDIF '
                            'bounds (e.g. observed=%d base=%d '
                            'final_range=[%.3f, %.3f])'
                            % (fraction * 100, sample['observed'],
                               sample['base'], sample['lower'],
                               sample['upper']))

    return result


def check_spike(melee: list) -> dict:
    """Damage == exactly base at the predicted spike frequency. Only
    meaningful when the predicted spike chance is material."""
    hits = [row for row in melee
            if row['outcome'] in ('hit',) and row['base'] > 0
            and row['spike'] >= 0.05]

    result = {'check': 'SPIKE', 'swings': len(hits)}

    if len(hits) < 100:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = ('need >= 100 hits logged with spike chance '
                            '>= 5%% - park wRatio near 1.0 (have %d)'
                            % len(hits))
        return result

    expected = sum(row['spike'] for row in hits) / len(hits)
    exact = sum(1 for row in hits if row['observed'] == row['base'])

    low, high = wilson_interval(exact, len(hits))
    result['rate'] = exact / len(hits)
    result['expected'] = expected
    result['ci'] = (low, high)

    # The uniform roll can also land exactly on base, so observed exact
    # frequency runs slightly ABOVE the spike chance; allow the CI to
    # sit on or above the prediction but fail a clear shortfall or wild
    # excess.
    if high < expected * 0.7:
        result['verdict'] = 'FAIL'
        result['detail'] = ('exact-base rate %.3f CI [%.3f, %.3f] far '
                            'below predicted spike %.3f - spike model '
                            'wrong?' % (result['rate'], low, high,
                                        expected))
    elif low > expected * 1.8 + 0.05:
        result['verdict'] = 'FAIL'
        result['detail'] = ('exact-base rate %.3f far above predicted '
                            'spike %.3f' % (result['rate'], expected))
    else:
        result['verdict'] = 'PASS'
        result['detail'] = ('exact-base rate %.3f vs predicted spike '
                            '%.3f (CI [%.3f, %.3f])'
                            % (result['rate'], expected, low, high))

    return result


def check_crit_rate(melee: list) -> dict:
    """Crit frequency among LANDED swings vs the predicted melee crit
    rate. Misses carry no crit information and are excluded."""
    landed = [row for row in melee
              if row['outcome'] in ('hit', 'crit')
              and row['crit_rate'] >= 0]

    result = {'check': 'CRIT_RATE', 'swings': len(landed)}

    if len(landed) < 200:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = ('need >= 200 landed swings (have %d); use '
                            'a singleton target so dDEX is exact'
                            % len(landed))
        return result

    crits = sum(1 for row in landed if row['outcome'] == 'crit')
    predicted = sum(row['crit_rate'] for row in landed) / len(landed)

    low, high = wilson_interval(crits, len(landed))
    result['rate'] = crits / len(landed)
    result['predicted'] = predicted
    result['ci'] = (low, high)

    if low <= predicted <= high:
        result['verdict'] = 'PASS'
        result['detail'] = ('crit rate %.3f vs predicted %.3f '
                            '(CI [%.3f, %.3f])'
                            % (result['rate'], predicted, low, high))
    else:
        result['verdict'] = 'FAIL'
        result['detail'] = ('crit rate %.3f CI [%.3f, %.3f] excludes '
                            'predicted %.3f - check dDEX tier curve / '
                            'gear CRITHITRATE flow'
                            % (result['rate'], low, high, predicted))

    return result


def check_hit_rate_pooled(melee: list) -> dict:
    """Pooled hit rate over ALL swings (any predicted rate, not just
    at-cap): observed landed fraction vs the mean predicted hit_rate,
    Wilson 95% CI. Complements HIT_CEILING, which only judges capped
    swings - an independent analyzer pass surfaced the gap."""
    swings = [row for row in melee
              if row['hit_rate'] >= 0
              and (row['outcome'] in ('hit', 'crit')
                   or row['outcome'] in MISS_OUTCOMES)]

    result = {'check': 'HIT_RATE_POOLED', 'swings': len(swings)}

    if len(swings) < 100:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = 'need >= 100 swings (have %d)' % len(swings)
        return result

    landed = sum(1 for row in swings
                 if row['outcome'] in ('hit', 'crit'))
    predicted = sum(row['hit_rate'] for row in swings) / len(swings)

    low, high = wilson_interval(landed, len(swings))
    result['rate'] = landed / len(swings)
    result['predicted'] = predicted
    result['ci'] = (low, high)

    if low <= predicted <= high:
        result['verdict'] = 'PASS'
        result['detail'] = ('landed %.3f CI [%.3f, %.3f] vs pooled '
                            'predicted %.3f'
                            % (result['rate'], low, high, predicted))
    else:
        result['verdict'] = 'FAIL'
        result['detail'] = ('landed %.3f CI [%.3f, %.3f] excludes '
                            'pooled predicted %.3f - accuracy model '
                            'off (food/song acc? see WARN_EFFECTS)'
                            % (result['rate'], low, high, predicted))

    return result


def check_melee_mean(melee: list) -> dict:
    """LANDED-to-LANDED: observed mean over landed swings (hit + crit)
    vs predicted_landed. Comparing landed observations against the
    per-ATTEMPT mean would run systematically hot by 1/hit_rate."""
    landed = [row for row in melee
              if row['outcome'] in ('hit', 'crit')
              and row['landed_mean'] is not None
              and row['landed_mean'] > 0]

    result = {'check': 'MELEE_MEAN', 'swings': len(landed)}

    if len(landed) < 100:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = ('need >= 100 landed swings with '
                            'predicted_landed (have %d; logs from '
                            '<= v0.1.7 lack the field)' % len(landed))
        return result

    observed = [row['observed'] for row in landed]
    predicted = sum(row['landed_mean'] for row in landed) / len(landed)
    mean = sum(observed) / len(observed)
    variance = (sum((x - mean) ** 2 for x in observed)
                / (len(observed) - 1))
    stderr = math.sqrt(variance / len(observed))

    low, high = mean - 1.96 * stderr, mean + 1.96 * stderr
    ratio = mean / predicted if predicted else float('inf')

    result['mean'] = mean
    result['predicted'] = predicted
    result['ratio'] = ratio

    if low <= predicted <= high:
        result['verdict'] = 'PASS'
        result['detail'] = ('landed mean %.1f vs predicted_landed %.1f '
                            '(ratio %.3f, CI [%.1f, %.1f])'
                            % (mean, predicted, ratio, low, high))
    else:
        result['verdict'] = 'FAIL'
        result['detail'] = ('landed mean %.1f vs predicted_landed %.1f '
                            '(ratio %.3f) outside CI [%.1f, %.1f]'
                            % (mean, predicted, ratio, low, high))

    return result


def check_ws_mean(ws: list) -> list:
    """Per weapon skill: observed mean within the CI of the prediction.
    A consistent ~+10% excess flags the legacy-alpha assumption."""
    by_name = defaultdict(list)

    for row in ws:
        if row['mean'] is not None:
            by_name[row['name']].append(row)

    results = []

    for name in sorted(by_name):
        rows = by_name[name]
        result = {'check': 'WS_MEAN:%s' % name, 'swings': len(rows)}

        if len(rows) < 30:
            result['verdict'] = 'INSUFFICIENT_DATA'
            result['detail'] = 'need >= 30 uses (have %d)' % len(rows)
            results.append(result)
            continue

        observed = [row['observed'] for row in rows]
        predicted = sum(row['mean'] for row in rows) / len(rows)
        mean = sum(observed) / len(observed)
        variance = (sum((x - mean) ** 2 for x in observed)
                    / (len(observed) - 1))
        stderr = math.sqrt(variance / len(observed))

        low, high = mean - 1.96 * stderr, mean + 1.96 * stderr
        ratio = mean / predicted if predicted else float('inf')

        result['mean'] = mean
        result['predicted'] = predicted
        result['ratio'] = ratio

        if low <= predicted <= high:
            result['verdict'] = 'PASS'
            result['detail'] = ('observed mean %.1f vs predicted %.1f '
                                '(ratio %.3f, CI [%.1f, %.1f])'
                                % (mean, predicted, ratio, low, high))
        elif 1.05 <= ratio <= 1.20:
            result['verdict'] = 'FAIL'
            result['detail'] = ('observed %.1f runs %.0f%% HOT vs '
                                'predicted %.1f - pattern matches '
                                'Adoulin alpha (=1.0) being live; '
                                'check legacy_alpha'
                                % (mean, (ratio - 1) * 100, predicted))
        else:
            result['verdict'] = 'FAIL'
            result['detail'] = ('observed mean %.1f vs predicted %.1f '
                                '(ratio %.3f) outside CI'
                                % (mean, predicted, ratio))

        results.append(result)

    if not results:
        results.append({'check': 'WS_MEAN', 'swings': 0,
                        'verdict': 'INSUFFICIENT_DATA',
                        'detail': 'no weapon skill lines in log'})

    return results


def analyze(text: str) -> list:
    parsed = parse_log(text)

    results = [
        check_hit_ceiling(parsed['melee']),
        check_hit_rate_pooled(parsed['melee']),
        check_pdif_bounds(parsed['melee']),
        check_spike(parsed['melee']),
        check_crit_rate(parsed['melee']),
        check_melee_mean(parsed['melee']),
    ]
    results.extend(check_ws_mean(parsed['ws']))

    return results


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]

    if len(argv) != 1:
        print(__doc__)
        return 2

    with open(argv[0], encoding='utf-8', errors='replace') as handle:
        results = analyze(handle.read())

    worst = 0

    for result in results:
        print('%-22s %-18s swings=%-6d %s'
              % (result['check'], result['verdict'],
                 result.get('swings', 0), result.get('detail', '')))

        if result['verdict'] == 'FAIL':
            worst = 1

    return worst


if __name__ == '__main__':
    sys.exit(main())
