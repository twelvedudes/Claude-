#!/usr/bin/env python3
"""Tests for analyze_telegraph.py.

The fixture lines are written in telegraph.lua's exact log format
(format strings transcribed, not generated); every verdict's
arithmetic is worked out in the comment above the assertion.

Run: python3 Telegraph/tools/test_analyze_telegraph.py
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analyze_telegraph as X  # noqa: E402


def bar_line(t, kind, actor, skill_id, label, expected, observed,
             outcome):
    expected_part = ('%.3f' % expected) if expected is not None else 'n/a'

    return ('12:00:00 t=%.3f bar kind=%s actor=%d id=%s label=%s '
            'expected_s=%s observed_s=%.3f outcome=%s'
            % (t, kind, actor, skill_id, label, expected_part,
               observed, outcome))


def tp_line(t, actor, skill, kind, lo, hi, best, confidence,
            tp_free=False):
    return ('12:00:00 t=%.3f tp_estimate_at_fire actor=%d skill=%s '
            'kind=%s lo=%d hi=%d best=%d confidence=%s '
            'implied_truth=ge1000%s'
            % (t, actor, skill, kind, lo, hi, best, confidence,
               ' tp_free' if tp_free else ''))


class ParseTests(unittest.TestCase):
    def test_bar_line_round_trip(self):
        parsed = X.parse_log(bar_line(
            101.5, 'cast', 0x1000123, '159', 'Stone', 1.5, 1.62,
            'finish'))

        self.assertEqual(1, len(parsed['bars']))
        row = parsed['bars'][0]
        self.assertEqual('cast', row['kind'])
        self.assertEqual(0x1000123, row['actor'])
        self.assertEqual('Stone', row['label'])
        self.assertEqual(1.5, row['expected'])
        self.assertEqual(1.62, row['observed'])
        self.assertEqual('finish', row['outcome'])

    def test_labels_with_spaces_parse(self):
        parsed = X.parse_log(bar_line(
            5.0, 'ready', 17, '257', 'Wild Carrot', 3.0, 3.1,
            'finish'))

        self.assertEqual('Wild Carrot', parsed['bars'][0]['label'])

    def test_na_expected_parses_as_none(self):
        parsed = X.parse_log(bar_line(
            5.0, 'cast', 17, '9999', 'casting (id 9999)', None, 4.2,
            'interrupt'))

        self.assertIsNone(parsed['bars'][0]['expected'])

    def test_tp_line_round_trip(self):
        parsed = X.parse_log(tp_line(
            44.0, 0x1000123, '257', 'ready_start', 900, 1400, 1100,
            'calibrated'))

        row = parsed['tp'][0]
        self.assertEqual(900, row['lo'])
        self.assertEqual(1400, row['hi'])
        self.assertEqual('calibrated', row['confidence'])
        self.assertFalse(row['tp_free'])

    def test_tp_free_flag_parses(self):
        parsed = X.parse_log(tp_line(
            44.0, 5, '600', 'ready_start', 0, 100, 50, 'calibrated',
            tp_free=True))

        self.assertTrue(parsed['tp'][0]['tp_free'])


class TpEstimateTests(unittest.TestCase):
    def test_insufficient_without_calibrated_fires(self):
        log = '\n'.join(
            tp_line(i, 100 + i, '257', 'ready_start', 0, 3000, 1500,
                    'cold')
            for i in range(20))

        result = X.check_tp_estimate(X.parse_log(log)['tp'])

        self.assertEqual('INSUFFICIENT_DATA', result['verdict'])

    def test_pass_when_intervals_contain_the_gate(self):
        # 12 calibrated fires, every interval reaches hi >= 1000:
        # 0 misses -> PASS
        log = '\n'.join(
            tp_line(i, 100 + i, '257', 'ready_start', 800, 1200 + i,
                    1050, 'calibrated')
            for i in range(12))

        result = X.check_tp_estimate(X.parse_log(log)['tp'])

        self.assertEqual('PASS', result['verdict'])
        self.assertEqual(0, result['interval_misses'])
        # best >= 1000 on every fire
        self.assertEqual(1.0, result['best_at_gate_rate'])

    def test_fail_when_intervals_undershoot(self):
        # 12 calibrated fires, 3 with hi < 1000 (25% > 10%) -> FAIL
        lines = [
            tp_line(i, 100 + i, '257', 'ready_start', 200,
                    700 if i < 3 else 1500, 600, 'calibrated')
            for i in range(12)
        ]

        result = X.check_tp_estimate(X.parse_log('\n'.join(lines))['tp'])

        self.assertEqual('FAIL', result['verdict'])
        self.assertEqual(3, result['interval_misses'])
        self.assertIn('undercounts', result['detail'])

    def test_tp_free_fires_excluded(self):
        # 12 calibrated misses that would FAIL - all tp_free -> the
        # gate does not apply, they never reach the verdict
        log = '\n'.join(
            tp_line(i, 100 + i, '600', 'ready_start', 0, 100, 50,
                    'calibrated', tp_free=True)
            for i in range(12))

        result = X.check_tp_estimate(X.parse_log(log)['tp'])

        self.assertEqual('INSUFFICIENT_DATA', result['verdict'])


class DurationTests(unittest.TestCase):
    def test_cast_time_pass_inside_tolerance(self):
        # 12 finishes at ratio 1.04 (inside +/-15%) -> PASS
        log = '\n'.join(
            bar_line(i, 'cast', 7, '159', 'Stone', 1.5, 1.56, 'finish')
            for i in range(12))

        result = X.check_cast_time(X.parse_log(log)['bars'])

        self.assertEqual('PASS', result['verdict'])

    def test_cast_time_fail_short_names_fast_cast(self):
        # every finish at half the table time: mean ratio 0.5 -> the
        # SHORT branch names server-side fast cast
        log = '\n'.join(
            bar_line(i, 'cast', 7, '159', 'Stone', 3.0, 1.5, 'finish')
            for i in range(12))

        result = X.check_cast_time(X.parse_log(log)['bars'])

        self.assertEqual('FAIL', result['verdict'])
        self.assertIn('SHORT', result['detail'])
        self.assertIn('fast-cast', result['detail'])

    def test_interrupts_carry_no_duration_truth(self):
        # interrupted bars must not pollute the timing verdict
        lines = [
            bar_line(i, 'cast', 7, '159', 'Stone', 3.0, 0.4,
                     'interrupt')
            for i in range(20)
        ]
        lines.extend(
            bar_line(100 + i, 'cast', 7, '159', 'Stone', 1.5, 1.5,
                     'finish')
            for i in range(12))

        result = X.check_cast_time(X.parse_log('\n'.join(lines))['bars'])

        self.assertEqual('PASS', result['verdict'])
        self.assertEqual(12, result['events'])

    def test_windup_judges_ready_bars_only(self):
        lines = [
            bar_line(i, 'ready', 9, '257', 'Wild Carrot', 3.0, 3.05,
                     'finish')
            for i in range(12)
        ]
        # cast noise that must not leak into WINDUP
        lines.extend(
            bar_line(50 + i, 'cast', 7, '159', 'Stone', 3.0, 0.5,
                     'finish')
            for i in range(12))

        result = X.check_windup(X.parse_log('\n'.join(lines))['bars'])

        self.assertEqual('PASS', result['verdict'])
        self.assertEqual(12, result['events'])

    def test_unknown_ids_without_table_time_excluded(self):
        # expected_s=n/a lines carry no truth to judge against
        log = '\n'.join(
            bar_line(i, 'cast', 7, '9999', 'casting (id 9999)', None,
                     2.0, 'finish')
            for i in range(20))

        result = X.check_cast_time(X.parse_log(log)['bars'])

        self.assertEqual('INSUFFICIENT_DATA', result['verdict'])


class OutcomeAccountingTests(unittest.TestCase):
    def test_high_replacement_rate_flags_missed_finishes(self):
        lines = [
            bar_line(i, 'cast', 7, '159', 'Stone', 1.5, 1.5,
                     'replaced')
            for i in range(5)
        ]
        lines.extend(
            bar_line(50 + i, 'cast', 7, '159', 'Stone', 1.5, 1.5,
                     'finish')
            for i in range(5))

        result = X.check_interrupt_accounting(
            X.parse_log('\n'.join(lines))['bars'])

        self.assertEqual('FAIL', result['verdict'])
        self.assertIn('missed', result['detail'])

    def test_normal_outcome_mix_passes(self):
        lines = [
            bar_line(i, 'ready', 9, '257', 'Wild Carrot', 3.0, 3.0,
                     'finish')
            for i in range(18)
        ]
        lines.append(bar_line(99, 'ready', 9, '257', 'Wild Carrot',
                              3.0, 1.0, 'interrupt'))

        result = X.check_interrupt_accounting(
            X.parse_log('\n'.join(lines))['bars'])

        self.assertEqual('PASS', result['verdict'])


class EndToEndTests(unittest.TestCase):
    def test_analyze_renders_all_four_checks(self):
        results = X.analyze('')

        self.assertEqual(['TP_ESTIMATE', 'CAST_TIME', 'WINDUP',
                          'BAR_OUTCOMES'],
                         [row['check'] for row in results])
        # an empty log is insufficient everywhere, never a crash
        for row in results:
            self.assertEqual('INSUFFICIENT_DATA', row['verdict'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
