#!/usr/bin/env python3
"""Tests for extract_ws.py.

Run: python3 Whetstone/tools/test_extract_ws.py
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract_ws as X  # noqa: E402

UPSTREAM_SCRIPT = """
-----------------------------------
-- Test Strike
-----------------------------------
local weaponskillObject = {}

weaponskillObject.onUseWeaponSkill = function(player, target, wsID, tp, primary, action, taChar)
    local params = {}
    params.numHits = 2
    params.ftpMod = { 1.0, 1.5, 2.0 }
    params.str_wsc = 0.3 params.vit_wsc = 0.2
    params.atkVaries = { 1.0, 2.0, 3.5 }

    if xi.settings.main.USE_ADOULIN_WEAPON_SKILL_CHANGES then
        params.str_wsc = 0.6
        params.ftpMod = { 9.0, 9.0, 9.0 }
    end

    if tp >= 2000 then
        params.numHits = 9 -- conditional: must not leak into the table
    elseif tp >= 1000 then
        params.numHits = 7
    end

    local damage, criticalHit, tpHits, extraHits = xi.weaponskills.doPhysicalWeaponskill(player, target, wsID, params, tp, action, primary, taChar)
    return tpHits, extraHits, criticalHit, damage
end

return weaponskillObject
"""

MODULE_FILE = """
require('modules/module_utils')
local m = Module:new('test_era_ws')

m:addOverride('xi.actions.weaponskills.era_strike.onUseWeaponSkill', function(player, target, wsID, tp, primary, action, taChar)
    local params = {}
    params.numHits = 3
    params.ftpMod = { 1.25, 1.25, 1.25 }
    params.dex_wsc = 0.4
    params.critVaries = { 0.1, 0.25, 0.5 }
    params.skill = xi.skill.DAGGER

    local damage, criticalHit, tpHits, extraHits = xi.weaponskills.doPhysicalWeaponskill(player, target, wsID, params, tp, action, primary, taChar)
    return tpHits, extraHits, criticalHit, damage
end)

m:addOverride('xi.actions.weaponskills.era_drain.onUseWeaponSkill', function(player, target, wsID, tp, primary, action, taChar)
    local drained = target:delMP(50)
    if target:isUndead() then
        drained = 0
    end
    return 1, 0, false, drained
end)

return m
"""

# weapon_skills columns: id, name, jobs blob, type, skilllevel, element,
# animation, animationTime, range, aoe, radius, primary/secondary/
# tertiary sc, main_only, unlock_id
WS_SQL = "\n".join([
    "INSERT INTO `weapon_skills` VALUES (40,'test_strike',"
    "0x0200000000000000000000000000000000000000000000,6,70,0,16,2000,5,0,0,"
    "6,1,0,0,0);",
    "INSERT INTO `weapon_skills` VALUES (41,'era_strike',"
    "0x0002000000020000000000000200000000000000000000,2,200,0,16,2000,5,0,0,"
    "3,0,0,1,2);",
    "INSERT INTO `weapon_skills` VALUES (42,'era_drain',"
    "0x0002000000000000000000000000000000000000000000,2,100,0,16,2000,5,0,0,"
    "0,0,0,0,0);",
])


def build_fixture(root: Path):
    upstream = root / 'scripts' / 'actions' / 'weaponskills'
    module = root / 'modules' / 'wotg' / 'lua' / 'weaponskills'
    sql = root / 'sql'

    upstream.mkdir(parents=True)
    module.mkdir(parents=True)
    sql.mkdir(parents=True)

    (upstream / 'test_strike.lua').write_text(UPSTREAM_SCRIPT)
    (module / 'dagger.lua').write_text(MODULE_FILE)
    (sql / 'weapon_skills.sql').write_text(WS_SQL + '\n')


class ExtractWsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        build_fixture(root)
        cls.db = X.extract(root)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_upstream_baseline_excludes_conditionals(self):
        ws = self.db['test_strike']

        self.assertEqual('base_script', ws['source'])
        self.assertEqual('physical', ws['kind'])
        # era values kept, Adoulin block and tp-conditionals excluded
        self.assertEqual('2', ws['params']['numHits'])
        self.assertEqual('0.3', ws['params']['str_wsc'])
        self.assertEqual('{ 1.0, 1.5, 2.0 }', ws['params']['ftpMod'])

    def test_multiple_assignments_per_line(self):
        # `params.str_wsc = 0.3 params.vit_wsc = 0.2` on one line
        self.assertEqual('0.2', self.db['test_strike']['params']['vit_wsc'])

    def test_module_override_wins(self):
        ws = self.db['era_strike']

        self.assertEqual('wotg_module', ws['source'])
        self.assertEqual('3', ws['params']['numHits'])
        self.assertEqual('{ 0.1, 0.25, 0.5 }', ws['params']['critVaries'])

    def test_xi_references_translated(self):
        self.assertEqual("'dagger'",
                         self.db['era_strike']['params']['skill'])

    def test_special_ws_has_no_params(self):
        ws = self.db['era_drain']

        self.assertEqual('special', ws['kind'])
        self.assertEqual({}, ws['params'])

    def test_metadata_from_sql(self):
        ws = self.db['test_strike']

        self.assertEqual(40, ws['id'])
        self.assertEqual('great_axe', ws['skill'])
        self.assertEqual(70, ws['skill_level'])
        self.assertEqual([6, 1], ws['sc'])
        self.assertEqual(['WAR'], ws['jobs'])
        self.assertFalse(ws['main_only'])

        era = self.db['era_strike']

        # jobs blob bytes 1, 5, 12 -> jobs 2, 6, 13 -> MNK, THF, NIN
        self.assertEqual(['MNK', 'THF', 'NIN'], era['jobs'])
        self.assertTrue(era['main_only'])
        self.assertEqual(2, era['unlock_id'])

    def test_emission_shape(self):
        text = X.emit_lua(self.db, 'fixture')

        self.assertIn("['test_strike']", text)
        self.assertIn('params = { atkVaries = { 1.0, 2.0, 3.5 }', text)
        self.assertTrue(text.startswith('-- Generated'))


class ValueTranslationTests(unittest.TestCase):
    def test_literals(self):
        self.assertEqual('true', X.translate_value('true'))
        self.assertEqual('0.5', X.translate_value('0.5'))
        self.assertEqual('{ 1, 2, 3 }', X.translate_value('{ 1, 2, 3 }'))

    def test_xi_enums(self):
        self.assertEqual("'fire'", X.translate_value('xi.element.FIRE'))
        self.assertEqual("'great_katana'",
                         X.translate_value('xi.skill.GREAT_KATANA'))
        self.assertEqual("'int'", X.translate_value('xi.mod.INT'))

    def test_dynamic_expressions_quarantined(self):
        result = X.translate_value('player:getMod(xi.mod.WSACC)')

        self.assertTrue(result.startswith("'<dynamic:"))


if __name__ == '__main__':
    unittest.main(verbosity=2)
