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
               upper=2.0, hit_rate=0.95):
    return ('12:00:00 melee %s observed=%d predicted_mean=150.0 '
            'base=%d spike=%.3f pdif_range=%.3f-%.3f hit_rate=%.2f '
            'target=Test Crab'
            % (outcome, observed, base, spike, lower, upper, hit_rate))


def ws_line(name, observed, mean=400.0):
    return ('12:00:00 ws id=36 name=%s observed=%d '
            'predicted_mean=%.1f target=Test Crab' % (name, observed, mean))


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
        self.assertIn('WS_MEAN:sturmwind', checks)


if __name__ == '__main__':
    unittest.main(verbosity=2)
