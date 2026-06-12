#!/usr/bin/env python3
"""Telegraph event log analyzer.

Reads a telegraph_events.log produced by `/tele debug` and renders a
verdict per validation question - the addon generates its own
validation data and this tool judges the models against it:

    TP_ESTIMATE   at every TP-move fire the server-implied truth is
                  TP >= 1000 (mobentity.cpp shouldUseTPMove). For
                  CALIBRATED entries the ledger interval must contain
                  that truth: hi < 1000 is a model violation (a feed
                  undercounts, or MOB_TP_MULTIPLIER != 1). Cold-entry
                  fires are reported separately (expected misses -
                  no history yet). tp_free fires are excluded (no
                  gate applies to the special-skill path; the line is
                  flagged at write time).
    CAST_TIME     observed cast start->finish duration vs the table
                  castTime per spell. Systematic SHORTFALL flags
                  server-side fast-cast mods (out of model);
                  systematic excess flags slow/table problems. Only
                  outcome=finish lines count (interrupts/replacements
                  carry no duration truth).
    WINDUP        observed readying->finish duration vs
                  mob_prepare_time per skill (zone-script ready-time
                  overrides surface here as per-skill outliers).

LINE SEMANTICS (must match telegraph.lua):
    bar lines:  '<wall> t=<s> bar kind=<cast|ready> actor=<id> id=<id>
                label=<text> expected_s=<n|n/a> observed_s=<n>
                outcome=<finish|interrupt|replaced>'
    tp lines:   '<wall> t=<s> tp_estimate_at_fire actor=<id>
                skill=<id> kind=<k> lo=<n> hi=<n> best=<n>
                confidence=<c> implied_truth=ge1000[ tp_free]'

Each check reports PASS / FAIL / INSUFFICIENT_DATA with event counts.
Pure stdlib; no scipy.

Usage:
    python3 tools/analyze_telegraph.py telegraph_events.log
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict

BAR_RE = re.compile(
    r't=(?P<t>[\d.]+) bar kind=(?P<kind>\S+) actor=(?P<actor>\d+) '
    r'id=(?P<id>\S+) label=(?P<label>.+?) '
    r'expected_s=(?P<expected>\S+) observed_s=(?P<observed>[\d.]+) '
    r'outcome=(?P<outcome>\S+)$')

TP_RE = re.compile(
    r't=(?P<t>[\d.]+) tp_estimate_at_fire actor=(?P<actor>\d+) '
    r'skill=(?P<skill>\S+) kind=(?P<kind>\S+) '
    r'lo=(?P<lo>-?\d+) hi=(?P<hi>-?\d+) best=(?P<best>-?\d+) '
    r'confidence=(?P<confidence>\S+) '
    r'implied_truth=ge1000(?P<tp_free> tp_free)?$')

# The fire-time truth (shouldUseTPMove's hard floor)
TP_TRUTH = 1000

# A finish observed within this relative band of the table value
# counts as agreeing (network jitter + frame timing on both edges)
TIME_TOLERANCE = 0.15

# Minimum events per verdict
MIN_TP_EVENTS = 10
MIN_TIME_EVENTS = 10


def parse_log(text: str) -> dict:
    bars = []
    tp = []

    for line in text.splitlines():
        match = BAR_RE.search(line)
        if match:
            row = match.groupdict()
            bars.append({
                't': float(row['t']),
                'kind': row['kind'],
                'actor': int(row['actor']),
                'id': row['id'],
                'label': row['label'],
                'expected': None if row['expected'] == 'n/a'
                            else float(row['expected']),
                'observed': float(row['observed']),
                'outcome': row['outcome'],
            })
            continue

        match = TP_RE.search(line)
        if match:
            row = match.groupdict()
            tp.append({
                't': float(row['t']),
                'actor': int(row['actor']),
                'skill': row['skill'],
                'kind': row['kind'],
                'lo': int(row['lo']),
                'hi': int(row['hi']),
                'best': int(row['best']),
                'confidence': row['confidence'],
                'tp_free': row['tp_free'] is not None,
            })

    return {'bars': bars, 'tp': tp}


def check_tp_estimate(tp: list) -> dict:
    """Calibrated fire-time intervals must contain the >= 1000 truth."""
    gated = [row for row in tp if not row['tp_free']]
    calibrated = [row for row in gated
                  if row['confidence'] == 'calibrated']
    cold = [row for row in gated if row['confidence'] == 'cold']
    stale = [row for row in gated if row['confidence'] == 'stale']

    result = {'check': 'TP_ESTIMATE', 'events': len(gated),
              'calibrated': len(calibrated), 'cold': len(cold),
              'stale': len(stale)}

    if len(calibrated) < MIN_TP_EVENTS:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = ('need >= %d calibrated fires (have %d; '
                            'cold=%d stale=%d) - stay on one camp '
                            'longer' % (MIN_TP_EVENTS, len(calibrated),
                                        len(cold), len(stale)))
        return result

    # interval truth: hi >= 1000 means the interval admits the truth
    misses = [row for row in calibrated if row['hi'] < TP_TRUTH]
    # point diagnostics: how often the marked point estimate itself
    # had reached the gate
    best_ok = sum(1 for row in calibrated if row['best'] >= TP_TRUTH)

    miss_rate = len(misses) / len(calibrated)
    result['interval_misses'] = len(misses)
    result['best_at_gate_rate'] = best_ok / len(calibrated)

    if miss_rate <= 0.10:
        result['verdict'] = 'PASS'
        result['detail'] = ('%d/%d calibrated fires inside the '
                            'interval (best>=1000 in %.0f%%); '
                            'cold=%d stale=%d excluded-tp_free=%d'
                            % (len(calibrated) - len(misses),
                               len(calibrated),
                               result['best_at_gate_rate'] * 100,
                               len(cold), len(stale),
                               len(tp) - len(gated)))
    else:
        sample = misses[0]
        result['verdict'] = 'FAIL'
        result['detail'] = ('%.0f%% of calibrated fires had hi < 1000 '
                            '(e.g. actor=%d skill=%s hi=%d) - a feed '
                            'undercounts, or MOB_TP_MULTIPLIER != 1 '
                            'on this server'
                            % (miss_rate * 100, sample['actor'],
                               sample['skill'], sample['hi']))

    return result


def _check_durations(bars: list, kind: str, check_name: str,
                     short_hint: str, long_hint: str) -> dict:
    """Shared CAST_TIME / WINDUP machinery: observed vs table per id."""
    finished = [row for row in bars
                if row['kind'] == kind and row['outcome'] == 'finish'
                and row['expected'] and row['expected'] > 0]

    result = {'check': check_name, 'events': len(finished)}

    if len(finished) < MIN_TIME_EVENTS:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = ('need >= %d completed %s bars with table '
                            'durations (have %d)'
                            % (MIN_TIME_EVENTS, kind, len(finished)))
        return result

    ratios = [row['observed'] / row['expected'] for row in finished]
    inside = sum(1 for ratio in ratios
                 if 1 - TIME_TOLERANCE <= ratio <= 1 + TIME_TOLERANCE)
    mean_ratio = sum(ratios) / len(ratios)
    agree_rate = inside / len(finished)

    # per-id outliers for the detail line
    by_id = defaultdict(list)

    for row, ratio in zip(finished, ratios):
        by_id[(row['id'], row['label'])].append(ratio)

    worst_id, worst_ratio = None, None

    for key, id_ratios in by_id.items():
        id_mean = sum(id_ratios) / len(id_ratios)

        if worst_ratio is None or abs(id_mean - 1) > abs(worst_ratio - 1):
            worst_id, worst_ratio = key, id_mean

    result['mean_ratio'] = mean_ratio
    result['agree_rate'] = agree_rate

    if agree_rate >= 0.70:
        result['verdict'] = 'PASS'
        result['detail'] = ('%.0f%% of %d finishes within +/-%.0f%% of '
                            'the table (mean ratio %.3f)'
                            % (agree_rate * 100, len(finished),
                               TIME_TOLERANCE * 100, mean_ratio))
    elif mean_ratio < 1 - TIME_TOLERANCE:
        result['verdict'] = 'FAIL'
        result['detail'] = ('observed durations run %.0f%% SHORT of '
                            'the table (worst: %s at %.3f) - %s'
                            % ((1 - mean_ratio) * 100,
                               worst_id and worst_id[1], worst_ratio,
                               short_hint))
    else:
        result['verdict'] = 'FAIL'
        result['detail'] = ('only %.0f%% of finishes near the table '
                            '(mean ratio %.3f; worst: %s at %.3f) - %s'
                            % (agree_rate * 100, mean_ratio,
                               worst_id and worst_id[1], worst_ratio,
                               long_hint))

    return result


def check_cast_time(bars: list) -> dict:
    return _check_durations(
        bars, 'cast', 'CAST_TIME',
        'mob fast-cast mods are server-side and out of model',
        'check the spell table vintage against the server commit')


def check_windup(bars: list) -> dict:
    return _check_durations(
        bars, 'ready', 'WINDUP',
        'a zone script overrides ready time (OnMobSkillReadyTime)',
        'check mob_prepare_time vintage / per-skill zone overrides')


def check_interrupt_accounting(bars: list) -> dict:
    """Informational: how bars ended. A high 'replaced' rate points at
    missed finish packets (range/packet loss), which also degrades
    the TP ledger's spend bookkeeping."""
    tracked = [row for row in bars if row['kind'] in ('cast', 'ready')]

    result = {'check': 'BAR_OUTCOMES', 'events': len(tracked)}

    if not tracked:
        result['verdict'] = 'INSUFFICIENT_DATA'
        result['detail'] = 'no bar events in log'
        return result

    counts = defaultdict(int)

    for row in tracked:
        counts[row['outcome']] += 1

    replaced_rate = counts.get('replaced', 0) / len(tracked)

    result['verdict'] = 'PASS' if replaced_rate <= 0.10 else 'FAIL'
    result['detail'] = ('finish=%d interrupt=%d replaced=%d%s'
                        % (counts.get('finish', 0),
                           counts.get('interrupt', 0),
                           counts.get('replaced', 0),
                           '' if replaced_rate <= 0.10 else
                           ' - high replacement rate: finishes are '
                           'being missed (range/packet loss), TP '
                           'spend bookkeeping degrades with them'))

    return result


def analyze(text: str) -> list:
    parsed = parse_log(text)

    return [
        check_tp_estimate(parsed['tp']),
        check_cast_time(parsed['bars']),
        check_windup(parsed['bars']),
        check_interrupt_accounting(parsed['bars']),
    ]


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]

    if len(argv) != 1:
        print(__doc__)
        return 2

    with open(argv[0], encoding='utf-8', errors='replace') as handle:
        results = analyze(handle.read())

    worst = 0

    for result in results:
        print('%-16s %-18s events=%-6d %s'
              % (result['check'], result['verdict'],
                 result.get('events', 0), result.get('detail', '')))

        if result['verdict'] == 'FAIL':
            worst = 1

    return worst


if __name__ == '__main__':
    sys.exit(main())
