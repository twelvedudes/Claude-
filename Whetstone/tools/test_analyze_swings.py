#!/usr/bin/env python3
"""Tests for analyze_swings.py with synthesized logs.

Run: python3 Whetstone/tools/test_analyze_swings.py
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analyze_swings as X  # noqa: E402


def melee_line(outcome, observed, base=100, spike=0.0, lower=1.54,
               upper=2.0, hit_rate=0.95, crit_rate=0.10):
    return ('12:00:00 melee %s observed=%d predicted_mean=150.0 '
            'base=%d spike=%.3f pdif_range=%.3f-%.3f hit_rate=%.2f '
            'crit_rate=%.3f target=Test Crab'
            % (outcome, observed, base, spike, lower, upper, hit_rate,
               crit_rate))


def ws_line(name, observed, mean=400.0):
    return ('12:00:00 ws id=36 name=%s observed=%d '
            'predicted_mean=%.1f target=Test Crab' % (name, observed, mean))


# v0.1.8+ line shapes: monotonic t= stamp, 'miss' label,
# predicted_landed= on melee, hits= on ws.
def melee_line_v2(outcome, observed, landed_mean=157.9, base=100,
                  hit_rate=0.95):
    return ('12:00:00 t=1042.123 melee %s observed=%d '
            'predicted_mean=150.0 predicted_landed=%.1f '
            'base=%d spike=0.000 pdif_range=1.540-2.000 hit_rate=%.2f '
            'crit_rate=0.100 target=Test Crab'
            % (outcome, observed, landed_mean, base, hit_rate))


def ws_line_v2(name, observed, mean=400.0, landed=2, rolled=2):
    return ('12:00:00 t=1042.456 ws id=36 name=%s observed=%d '
            'predicted_mean=%.1f hits=%d/%d target=Test Crab'
            % (name, observed, mean, landed, rolled))


class WilsonTests(unittest.TestCase):
    def test_interval_brackets_the_point_estimate(self):
        low, high = X.wilson_interval(20, 400)

        self.assertLess(low, 0.05)
        self.assertGreater(high, 0.05)
        self.assertLess(high, 0.08)  # 400 samples is reasonably tight

    def test_zero_samples(self):
        self.assertEqual((0.0, 1.0), X.wilson_interval(0, 0))


class HitCeilingTests(unittest.TestCase):
    def test_pass_at_95(self):
        # 400 capped swings, 20 misses = 5%
        lines = [melee_line('hit', 150)] * 380 \
            + [melee_line('other:15', 0)] * 20
        result = X.check_hit_ceiling(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('PASS', result['verdict'])

    def test_fail_detects_99_ceiling(self):
        # 400 capped swings, 4 misses = 1%
        lines = [melee_line('hit', 150)] * 396 \
            + [melee_line('other:15', 0)] * 4
        result = X.check_hit_ceiling(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('FAIL', result['verdict'])
        self.assertIn('99', result['detail'])

    def test_insufficient_below_200(self):
        lines = [melee_line('hit', 150)] * 50
        result = X.check_hit_ceiling(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('INSUFFICIENT_DATA', result['verdict'])

    def test_uncapped_swings_excluded(self):
        # hit_rate 0.70 lines must not count toward the ceiling check
        lines = [melee_line('hit', 150, hit_rate=0.70)] * 400
        result = X.check_hit_ceiling(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual(0, result['swings'])


class PdifBoundsTests(unittest.TestCase):
    def test_pass_inside_bounds(self):
        # bounds [1.54, 2.0 * 1.05]: damage 154..210 on base 100
        lines = [melee_line('hit', dmg) for dmg in
                 [154, 160, 170, 180, 190, 200, 205, 210] * 8]
        result = X.check_pdif_bounds(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('PASS', result['verdict'])

    def test_fail_outside_bounds(self):
        # 10% of swings land far above the cap
        good = [melee_line('hit', 180)] * 90
        bad = [melee_line('hit', 300)] * 10
        result = X.check_pdif_bounds(
            X.parse_log('\n'.join(good + bad))['melee'])

        self.assertEqual('FAIL', result['verdict'])

    def test_spike_value_is_always_legal(self):
        # damage == base exactly (the spike) even though base is far
        # below the lower bound
        lines = [melee_line('hit', 180)] * 60 \
            + [melee_line('hit', 100, spike=0.3)] * 10
        result = X.check_pdif_bounds(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('PASS', result['verdict'])


class SpikeTests(unittest.TestCase):
    def test_pass_at_predicted_frequency(self):
        # spike 1/3 predicted; 40 exact-base of 120 hits
        exact = [melee_line('hit', 100, spike=0.333,
                            lower=0.711, upper=1.3)] * 40
        rolled = [melee_line('hit', 110, spike=0.333,
                             lower=0.711, upper=1.3)] * 80
        result = X.check_spike(X.parse_log('\n'.join(exact + rolled))['melee'])

        self.assertEqual('PASS', result['verdict'])

    def test_fail_when_spike_missing(self):
        # predicted 1/3 but only 2% exact-base: spike model wrong
        exact = [melee_line('hit', 100, spike=0.333,
                            lower=0.711, upper=1.3)] * 4
        rolled = [melee_line('hit', 110, spike=0.333,
                             lower=0.711, upper=1.3)] * 196
        result = X.check_spike(X.parse_log('\n'.join(exact + rolled))['melee'])

        self.assertEqual('FAIL', result['verdict'])

    def test_skipped_at_high_wratio(self):
        # spike chance 0 logged -> excluded -> insufficient
        lines = [melee_line('hit', 180, spike=0.0)] * 300
        result = X.check_spike(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('INSUFFICIENT_DATA', result['verdict'])


class CritRateTests(unittest.TestCase):
    def test_pass_at_predicted_rate(self):
        # predicted 10%, observed 22/220 = 10%
        lines = [melee_line('hit', 180)] * 198 \
            + [melee_line('crit', 280)] * 22
        result = X.check_crit_rate(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('PASS', result['verdict'])

    def test_fail_when_rate_disagrees(self):
        # predicted 10%, observed 30% - tier curve or gear flow broken
        lines = [melee_line('hit', 180)] * 140 \
            + [melee_line('crit', 280)] * 60
        result = X.check_crit_rate(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('FAIL', result['verdict'])
        self.assertIn('dDEX', result['detail'])

    def test_misses_carry_no_crit_information(self):
        # 300 misses + 100 landed: only landed count -> insufficient
        lines = [melee_line('other:15', 0)] * 300 \
            + [melee_line('hit', 180)] * 100
        result = X.check_crit_rate(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('INSUFFICIENT_DATA', result['verdict'])
        self.assertEqual(100, result['swings'])


class WsMeanTests(unittest.TestCase):
    def test_pass_when_mean_matches(self):
        # observed scattered around the prediction
        lines = [ws_line('sturmwind', dmg) for dmg in
                 [380, 390, 400, 410, 420] * 8]
        results = X.check_ws_mean(X.parse_log('\n'.join(lines))['ws'])

        self.assertEqual('PASS', results[0]['verdict'])

    def test_fail_flags_adoulin_alpha_pattern(self):
        # consistently ~+10% hot: the legacy-alpha tell
        lines = [ws_line('sturmwind', dmg) for dmg in
                 [430, 437, 440, 443, 450] * 8]
        results = X.check_ws_mean(X.parse_log('\n'.join(lines))['ws'])

        self.assertEqual('FAIL', results[0]['verdict'])
        self.assertIn('alpha', results[0]['detail'])

    def test_insufficient_below_30(self):
        lines = [ws_line('sturmwind', 400)] * 5
        results = X.check_ws_mean(X.parse_log('\n'.join(lines))['ws'])

        self.assertEqual('INSUFFICIENT_DATA', results[0]['verdict'])


class V2LineFormatTests(unittest.TestCase):
    def test_v2_melee_parses_with_landed_mean_and_t_stamp(self):
        parsed = X.parse_log(melee_line_v2('hit', 160))['melee']

        self.assertEqual(1, len(parsed))
        self.assertEqual(160, parsed[0]['observed'])
        self.assertAlmostEqual(157.9, parsed[0]['landed_mean'])

    def test_v1_melee_still_parses_with_landed_none(self):
        parsed = X.parse_log(melee_line('hit', 160))['melee']

        self.assertEqual(1, len(parsed))
        self.assertIsNone(parsed[0]['landed_mean'])

    def test_miss_label_counts_for_hit_ceiling(self):
        # both the new 'miss' label and the legacy 'other:15' count
        lines = [melee_line_v2('hit', 150)] * 380 \
            + [melee_line_v2('miss', 0)] * 10 \
            + [melee_line('other:15', 0)] * 10
        result = X.check_hit_ceiling(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual(400, result['swings'])
        self.assertEqual(20, result['misses'])
        self.assertEqual('PASS', result['verdict'])

    def test_v2_ws_parses_hits(self):
        parsed = X.parse_log(ws_line_v2('raging_axe', 0,
                                        landed=0, rolled=2))['ws']

        self.assertEqual(1, len(parsed))
        self.assertEqual(0, parsed[0]['observed'])
        self.assertEqual(0, parsed[0]['hits_landed'])
        self.assertEqual(2, parsed[0]['hits_rolled'])

    def test_v1_ws_still_parses(self):
        parsed = X.parse_log(ws_line('raging_axe', 400))['ws']

        self.assertEqual(1, len(parsed))
        self.assertIsNone(parsed[0]['hits_landed'])


class MeleeMeanTests(unittest.TestCase):
    def test_landed_to_landed_pass(self):
        # landed swings around the landed mean: must NOT be compared
        # against the attempt mean (150 here vs landed 157.9)
        lines = ([melee_line_v2('hit', 150)] * 60
                 + [melee_line_v2('hit', 166)] * 60
                 + [melee_line_v2('miss', 0)] * 40)
        result = X.check_melee_mean(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('PASS', result['verdict'])
        self.assertEqual(120, result['swings'])  # misses excluded

    def test_systematic_excess_fails(self):
        lines = [melee_line_v2('hit', 190)] * 150
        result = X.check_melee_mean(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('FAIL', result['verdict'])

    def test_legacy_logs_are_insufficient(self):
        # v1 lines lack predicted_landed: the check must say so, not
        # silently compare against the wrong mean
        lines = [melee_line('hit', 160)] * 300
        result = X.check_melee_mean(X.parse_log('\n'.join(lines))['melee'])

        self.assertEqual('INSUFFICIENT_DATA', result['verdict'])


class EndToEndTests(unittest.TestCase):
    def test_analyze_produces_all_checks(self):
        text = '\n'.join(
            [melee_line('hit', 180)] * 250
            + [melee_line('other:15', 0)] * 13
            + [ws_line('sturmwind', 400)] * 40)

        checks = {result['check'] for result in X.analyze(text)}

        self.assertIn('HIT_CEILING', checks)
        self.assertIn('PDIF_BOUNDS', checks)
        self.assertIn('SPIKE', checks)
        self.assertIn('CRIT_RATE', checks)
        self.assertIn('WS_MEAN:sturmwind', checks)


if __name__ == '__main__':
    unittest.main(verbosity=2)
