#!/usr/bin/env python3
"""Tests for extract_spells.py.

Fixture rows mirror sql/spell_list.sql shapes (including @SET
variables in non-consumed columns and capitalized module WHERE
names); expected values are read straight off the fixture, not from
the extractor.

Run: python3 Telegraph/tools/test_extract_spells.py
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract_spells as X  # noqa: E402
from extract_mobs import ConservationError  # noqa: E402

# spell_list columns: spellid, name, jobs, group, family, element,
# zonemisc, validTargets, skill, mpCost, castTime, recastTime, ...
SPELL_SQL = "\n".join([
    "INSERT INTO `spell_list` VALUES (1,'cure',"
    "0x00000100030005000000000000000000000000050000,6,1,@ELEMENT_LIGHT,"
    "0,95,@SKILL_HEALING,8,2000,5000,7,7,1,2000,4,0,1.00,0,0,0,200,0,NULL);",
    "INSERT INTO `spell_list` VALUES (159,'stone',"
    "0x00000000000300000000000000000000000000030000,2,2,@ELEMENT_EARTH,"
    "0,32,@SKILL_ELEMENTAL_MAGIC,4,1000,2000,2,252,222,2000,4,10,1.00,"
    "0,0,0,200,0,NULL);",
    "INSERT INTO `spell_list` VALUES (231,'poisona',"
    "0x00000300000000000000000000000000000000030000,6,1,@ELEMENT_LIGHT,"
    "0,95,@SKILL_HEALING,8,3000,10000,7,7,1,2000,4,0,1.00,0,0,0,200,0,NULL);",
    "INSERT INTO `spell_list` VALUES (338,'utsusemi_ichi',"
    "0x00000000000000000000000000250000000000250000,4,0,@ELEMENT_WIND,"
    "0,1,@SKILL_NINJUTSU,0,1500,30000,7,7,1,2000,4,0,1.00,0,0,0,200,0,NULL);",
])

# Enabled-module updates: an era castTime change (lowercase name), a
# CE/VE-only change with a CAPITALIZED name (must be ignored without
# erroring), and a jobs-only change (ignored).
MODULE_SQL = "\n".join([
    "UPDATE spell_list SET mpCost = 9, castTime = 1500, "
    "recastTime = 6500 WHERE name = 'stone';",
    "UPDATE `spell_list` SET CE = 1, VE = 300 WHERE `name` = 'Poisona';",
    "UPDATE spell_list SET jobs = 0x0001 WHERE name = 'cure';",
])

MODULE_INIT = "soa/\n"


def build_fixture(root: Path, module_sql: str = MODULE_SQL):
    (root / 'sql').mkdir(parents=True)
    (root / 'sql' / 'spell_list.sql').write_text(SPELL_SQL + '\n')

    module_dir = root / 'modules' / 'soa' / 'sql'
    module_dir.mkdir(parents=True)
    (module_dir / 'magic_adjustments.sql').write_text(module_sql + '\n')
    (root / 'modules' / 'init.txt').write_text(MODULE_INIT)


class ExtractSpellsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        build_fixture(root)
        cls.spells, cls.accounting = X.extract(root)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_base_rows_extracted(self):
        # castTime is column 10, milliseconds (spell.cpp loads it with
        # std::chrono::milliseconds)
        self.assertEqual(2000, self.spells[1]['cast_ms'])
        self.assertEqual('cure', self.spells[1]['name'])
        self.assertEqual('Cure', self.spells[1]['pretty'])

    def test_module_cast_time_applied(self):
        # soa/magic_adjustments.sql: stone castTime 1000 -> 1500
        self.assertEqual(1500, self.spells[159]['cast_ms'])

    def test_non_consumed_updates_ignored_case_insensitively(self):
        # the CE/VE row targets 'Poisona' (capitalized) - ignored
        # because CE/VE are not consumed, NOT because the name missed
        self.assertEqual(3000, self.spells[231]['cast_ms'])
        # 2 ignored: the CE/VE row and the jobs row
        self.assertEqual(2, self.accounting['sql_updates_ignored'])
        self.assertEqual(1, self.accounting['sql_updates_applied'])

    def test_conservation_books_balance(self):
        self.assertEqual(4, self.accounting['total'])
        self.assertEqual(4, self.accounting['emitted'])

    def test_pretty_names(self):
        self.assertEqual('Cure II', X.pretty_name('cure_ii'))
        self.assertEqual('Stonega III', X.pretty_name('stonega_iii'))
        self.assertEqual('Utsusemi Ichi', X.pretty_name('utsusemi_ichi'))
        self.assertEqual('Cure IV', X.pretty_name('cure_iv'))

    def test_emission_shape(self):
        text = X.emit_lua(self.spells, 'fixture @ abc1234')

        self.assertTrue(text.startswith('-- Generated'))
        self.assertIn("vintage = 'fixture @ abc1234'", text)
        self.assertIn(
            "[159] = { name = 'Stone', raw = 'stone', cast_ms = 1500 }",
            text)


class ConservationTests(unittest.TestCase):
    def test_consumed_update_matching_nothing_raises(self):
        # a castTime override whose WHERE name misses every spell must
        # fail loudly - a silently-missed era cast time would be
        # invisible forever
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_fixture(root, "UPDATE spell_list SET castTime = 1 "
                                "WHERE name = 'no_such_spell';")

            with self.assertRaises(ConservationError):
                X.extract(root)

    def test_unsupported_where_on_consumed_column_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_fixture(root, "UPDATE spell_list SET castTime = 1 "
                                "WHERE skill = 32;")

            with self.assertRaises(ConservationError):
                X.extract(root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
