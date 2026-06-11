#!/usr/bin/env python3
"""Tests for extract_mobskills.py.

Run: python3 Telegraph/tools/test_extract_mobskills.py
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract_mobskills as X  # noqa: E402
from extract_mobs import ConservationError  # noqa: E402

# mob_skills columns: id, anim, name, aoe, radius, distance, anim_time,
# prepare_time, valid_targets, flag, param, knockback, sc1, sc2, sc3.
# The real dump defines SET @SKILLFLAG_* variables and uses them in
# the flag column - the fixture mirrors that.
SKILL_SQL = "\n".join([
    "SET @SKILLFLAG_NO_TP_COST     = 4;",
    "SET @SKILLFLAG_ALWAYS_ANIMATE = 256;",
    # instant skill (prepare 0): never emits a readying packet
    "INSERT INTO `mob_skills` VALUES "
    "(1,16,'combo',0,0.0,7.0,2000,0,4,0,0,0,8,0,0);",
    # windup skill
    "INSERT INTO `mob_skills` VALUES "
    "(257,184,'wild_carrot',0,0.0,9.0,2000,3000,1,0,0,0,0,0,0);",
    # TP-free skill: SKILLFLAG_NO_TP_COST = 0x004
    "INSERT INTO `mob_skills` VALUES "
    "(600,99,'free_move',0,0.0,7.0,2000,1500,4,4,0,0,0,0,0);",
    # flag with NO_TP_COST set among other bits (0x004 | 0x010 = 20)
    "INSERT INTO `mob_skills` VALUES "
    "(601,99,'silent_free_move',0,0.0,7.0,2000,1500,4,20,0,0,0,0,0);",
    # @variable flag (the real dump's ALWAYS_ANIMATE rows): not tp-free
    "INSERT INTO `mob_skills` VALUES "
    "(602,99,'animated_move',0,0.0,7.0,2000,1500,4,"
    "@SKILLFLAG_ALWAYS_ANIMATE,0,0,0,0,0);",
    # OR-combined variable flag including NO_TP_COST
    "INSERT INTO `mob_skills` VALUES "
    "(603,99,'animated_free_move',0,0.0,7.0,2000,1500,4,"
    "@SKILLFLAG_NO_TP_COST | @SKILLFLAG_ALWAYS_ANIMATE,0,0,0,0,0);",
])


def build_fixture(root: Path, module_sql: str = None):
    (root / 'sql').mkdir(parents=True)
    (root / 'sql' / 'mob_skills.sql').write_text(SKILL_SQL + '\n')

    if module_sql is not None:
        module_dir = root / 'modules' / 'soa' / 'sql'
        module_dir.mkdir(parents=True)
        (module_dir / 'skills.sql').write_text(module_sql + '\n')
        (root / 'modules' / 'init.txt').write_text('soa/\n')


class ExtractMobSkillsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        build_fixture(root)
        cls.skills, cls.accounting = X.extract(root)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_windup_in_milliseconds(self):
        # mob_prepare_time -> setActivationTime(ms), battleutils.cpp
        self.assertEqual(3000, self.skills[257]['windup_ms'])
        self.assertEqual('Wild Carrot', self.skills[257]['pretty'])
        self.assertEqual('wild_carrot', self.skills[257]['name'])

    def test_instant_skills_carry_zero_windup(self):
        # prepare 0: mobskill_state.cpp only pushes the readying when
        # m_castTime > 0s - the ledger spends these on the FINISH
        self.assertEqual(0, self.skills[1]['windup_ms'])

    def test_tp_free_flag(self):
        # SKILLFLAG_NO_TP_COST = 0x004 (mobskill.h isTpFreeSkill)
        self.assertFalse(self.skills[257]['tp_free'])
        self.assertTrue(self.skills[600]['tp_free'])
        # flag 20 = 0x004 | 0x010 (NO_START_MSG): bitmask, not equality
        self.assertTrue(self.skills[601]['tp_free'])

    def test_set_variable_flags_resolve(self):
        # the dump writes @SKILLFLAG_* references in the flag column
        self.assertFalse(self.skills[602]['tp_free'])
        # '@A | @B' OR-composition with NO_TP_COST present
        self.assertTrue(self.skills[603]['tp_free'])

    def test_unresolvable_flag_raises(self):
        with self.assertRaises(ConservationError):
            X.resolve_flag('@NO_SUCH_FLAG', {}, 'test')

    def test_conservation_books_balance(self):
        self.assertEqual(6, self.accounting['total'])
        self.assertEqual(6, self.accounting['emitted'])

    def test_emission_shape(self):
        text = X.emit_lua(self.skills, 'fixture @ abc1234')

        self.assertTrue(text.startswith('-- Generated'))
        self.assertIn("vintage = 'fixture @ abc1234'", text)
        self.assertIn(
            "[257] = { name = 'Wild Carrot', raw = 'wild_carrot', "
            "windup_ms = 3000 }", text)
        self.assertIn(
            "[600] = { name = 'Free Move', raw = 'free_move', "
            "windup_ms = 1500, tp_free = true }", text)
        # non-tp-free entries stay lean
        self.assertNotIn('tp_free = false', text)


class ConservationTests(unittest.TestCase):
    def test_module_update_on_consumed_column_raises(self):
        # no enabled Phoenix module touches mob_skills today; if one
        # appears, extraction must fail until taught to apply it
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_fixture(root, "UPDATE mob_skills SET "
                                "mob_prepare_time = 1 WHERE "
                                "mob_skill_id = 257;")

            with self.assertRaises(ConservationError):
                X.extract(root)

    def test_module_update_on_other_columns_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_fixture(root, "UPDATE mob_skills SET knockback = 1 "
                                "WHERE mob_skill_id = 257;")

            skills, accounting = X.extract(root)

            self.assertEqual(3000, skills[257]['windup_ms'])
            self.assertEqual(1, accounting['sql_updates_ignored'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
