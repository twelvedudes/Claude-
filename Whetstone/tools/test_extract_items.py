#!/usr/bin/env python3
"""Tests for extract_items.py.

Run: python3 Whetstone/tools/test_extract_items.py
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract_items as X  # noqa: E402

FIXTURE_SQL = {
    # itemId, name, level, ilevel, jobs, MId, shieldSize, scriptType,
    # slot, rslot, rslotlook, su_level
    'item_equipment.sql': [
        # belt: slot bit 10 (waist), all jobs
        "INSERT INTO `item_equipment` VALUES "
        "(15457,'swift_belt',50,0,4194303,0,0,0,1024,0,0,0);",
        # axe: slot bits 0+1 (main/sub), WAR(bit0)+DRK(bit7) only
        "INSERT INTO `item_equipment` VALUES "
        "(17559,'fixture_axe',60,0,129,0,0,0,3,0,0,0);",
        # shield with size 3
        "INSERT INTO `item_equipment` VALUES "
        "(12295,'fixture_shield',55,0,4194303,0,3,0,2,0,0,0);",
    ],
    'item_weapon.sql': [
        # itemId, name, skill, subskill, ilvl_skill, ilvl_parry,
        # ilvl_macc, dmgType, hit, delay, dmg
        "INSERT INTO `item_weapon` VALUES "
        "(17559,'fixture_axe',5,0,0,0,0,3,1,276,48,0);",
        # weapon row without an equipment row: must be ignored
        "INSERT INTO `item_weapon` VALUES "
        "(60000,'ghost_weapon',5,0,0,0,0,3,1,240,40,0);",
    ],
    'item_mods.sql': [
        "INSERT INTO `item_mods` VALUES (15457,384,400); -- Haste: 4%",
        "INSERT INTO `item_mods` VALUES (15457,25,3);    -- ACC: 3",
        "INSERT INTO `item_mods` VALUES (15457,23,-5);   -- ATT: -5",
        "INSERT INTO `item_mods` VALUES (17559,8,4);     -- STR: 4",
        "INSERT INTO `item_mods` VALUES (17559,288,5);   -- DA: 5",
        "INSERT INTO `item_mods` VALUES (17559,421,3);   -- Crit dmg +3%",
        # not in whitelist (Mod 311 = COUNTER) -> dropped by default
        "INSERT INTO `item_mods` VALUES (17559,311,10);",
        # mods for an item with no equipment row -> ignored
        "INSERT INTO `item_mods` VALUES (60000,23,10);",
    ],
    # itemId, modId, value, latentId, latentParam
    'item_latents.sql': [
        # conditional ACC (whitelisted mod) -> flags the item
        "INSERT INTO `item_latents` VALUES (15457,25,50,50,31);",
        # conditional REGEN (mod 370, not whitelisted) -> outside model
        "INSERT INTO `item_latents` VALUES (15457,370,1,26,0);",
        # latent for an item with no equipment row -> ignored
        "INSERT INTO `item_latents` VALUES (60000,25,10,50,31);",
    ],
}


def build_fixture(root: Path):
    (root / 'sql').mkdir(parents=True)

    for name, rows in FIXTURE_SQL.items():
        (root / 'sql' / name).write_text('\n'.join(rows) + '\n')


class ExtractItemsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        build_fixture(cls.root)
        cls.items, cls.accounting = X.extract(cls.root)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_gear_haste_is_exact_raw_value(self):
        belt = self.items[15457]

        # 10000-based, exactly as stored: 400 = 4%
        self.assertEqual(400, belt['mods']['haste'])
        self.assertEqual(3, belt['mods']['acc'])
        self.assertEqual(-5, belt['mods']['att'])

    def test_weapon_join(self):
        axe = self.items[17559]

        self.assertEqual('axe', axe['weapon']['skill'])
        self.assertEqual(48, axe['weapon']['dmg'])
        self.assertEqual(276, axe['weapon']['delay'])
        self.assertEqual(4, axe['mods']['str'])
        self.assertEqual(5, axe['mods']['double_attack'])
        self.assertEqual(3, axe['mods']['crit_dmg'])

    def test_whitelist_drops_unlisted_mods(self):
        self.assertNotIn('mod311', self.items[17559]['mods'])

    def test_all_mods_flag_keeps_everything(self):
        items, _ = X.extract(self.root, all_mods=True)

        self.assertEqual(10, items[17559]['mods']['mod311'])

    def test_items_without_equipment_rows_ignored(self):
        self.assertNotIn(60000, self.items)

    def test_shield_size(self):
        self.assertEqual(3, self.items[12295]['shield_size'])

    def test_slot_and_job_decoding(self):
        self.assertEqual(['waist'], X.decode_slots(1024))
        self.assertEqual(['main', 'sub'], X.decode_slots(3))
        self.assertEqual(['WAR', 'DRK'], X.decode_jobs(129))

    def test_latent_mods_flagged_never_summed(self):
        belt = self.items[15457]

        # the conditional +50 acc flags the item...
        self.assertEqual({'acc'}, belt['latent_mods'])
        # ...but is NEVER added to the unconditional mods
        self.assertEqual(3, belt['mods']['acc'])
        # items without latent rows carry no flag
        self.assertNotIn('latent_mods', self.items[17559])

    def test_latent_conservation(self):
        self.assertEqual(1, self.accounting['latents_flagged'])
        self.assertEqual(1, self.accounting['latents_outside_model'])
        self.assertEqual(1, self.accounting['latents_non_equipment'])

    def test_emission_loadable_shape(self):
        text = X.emit_lua(self.items, 'fixture')

        self.assertIn("[15457] = { name = 'swift_belt'", text)
        self.assertIn('haste = 400', text)
        self.assertIn("weapon = { skill = 'axe', dmg = 48, delay = 276",
                      text)
        self.assertIn("latent_mods = { 'acc' }", text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
