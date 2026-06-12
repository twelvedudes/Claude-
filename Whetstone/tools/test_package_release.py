#!/usr/bin/env python3
"""Tests for package_release.py (data-dir mode against the real addon
source trees, with synthetic data directories).

Run: python3 Whetstone/tools/test_package_release.py
"""

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import package_release as X  # noqa: E402

WHETSTONE_DIR = Path(__file__).resolve().parent.parent
TELEGRAPH_DIR = WHETSTONE_DIR.parent / 'Telegraph'


def build_whetstone_data(root: Path):
    (root / 'mobs').mkdir(parents=True)
    (root / 'mobs' / 'index.lua').write_text(
        'return { total_entries = 1, zones = { [1] = '
        "{ file = 'zone_1', entries = 1 } } }\n")
    (root / 'mobs' / 'zone_1.lua').write_text("return { ['A'] = {} }\n")
    (root / 'weaponskills.lua').write_text('return {}\n')
    (root / 'items.lua').write_text('return {}\n')


def build_telegraph_data(root: Path):
    root.mkdir(parents=True)
    (root / 'spells.lua').write_text('return {}\n')
    (root / 'mobskills.lua').write_text('return {}\n')
    (root / 'mobs').mkdir()
    (root / 'mobs' / 'index.lua').write_text(
        'return { total_entries = 0, zones = {} }\n')


class WhetstonePackageTests(unittest.TestCase):
    def test_builds_complete_zip(self):
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / 'data'
            build_whetstone_data(data_dir)

            out = Path(tmp) / 'whetstone-v0.0.1-beta.zip'
            manifest = X.build_zip(WHETSTONE_DIR, data_dir, out, '0.0.1',
                                   'fixture')

            self.assertTrue(out.exists())

            with zipfile.ZipFile(out) as bundle:
                names = set(bundle.namelist())

            # every addon file ships
            for name in X.ADDONS['whetstone']['files']:
                self.assertIn('whetstone/%s' % name, names)

            # the SHARED modules ship at the addon root: a standalone
            # install must satisfy require('actionpacket') /
            # require('selftest') without the repo layout
            self.assertIn('whetstone/actionpacket.lua', names)
            self.assertIn('whetstone/selftest.lua', names)

            # every data table ships, plus regeneration instructions
            self.assertIn('whetstone/data/weaponskills.lua', names)
            self.assertIn('whetstone/data/items.lua', names)
            self.assertIn('whetstone/data/mobs/index.lua', names)
            self.assertIn('whetstone/data/mobs/zone_1.lua', names)
            self.assertIn('whetstone/data/REGENERATE.txt', names)
            self.assertIn('whetstone/VERSION', names)
            self.assertEqual(len(names), len(manifest))

    def test_refuses_to_ship_without_data(self):
        # the launch-week failure mode: formula engine, no tables
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / 'data'
            data_dir.mkdir()
            (data_dir / 'items.lua').write_text('return {}\n')
            # weaponskills.lua and mobs/index.lua missing

            with self.assertRaises(SystemExit) as caught:
                X.build_zip(WHETSTONE_DIR, data_dir,
                            Path(tmp) / 'out.zip', '0.0.1', 'fixture')

            self.assertIn('without data tables', str(caught.exception))


class TelegraphPackageTests(unittest.TestCase):
    def test_builds_complete_zip(self):
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / 'data'
            build_telegraph_data(data_dir)

            out = Path(tmp) / 'telegraph-v0.0.1-beta.zip'
            manifest = X.build_zip(TELEGRAPH_DIR, data_dir, out, '0.0.1',
                                   'fixture', 'telegraph')

            with zipfile.ZipFile(out) as bundle:
                names = set(bundle.namelist())

            for name in X.ADDONS['telegraph']['files']:
                self.assertIn('telegraph/%s' % name, names)

            self.assertIn('telegraph/actionpacket.lua', names)
            self.assertIn('telegraph/selftest.lua', names)
            self.assertIn('telegraph/data/spells.lua', names)
            self.assertIn('telegraph/data/mobskills.lua', names)
            self.assertIn('telegraph/data/mobs/index.lua', names)
            self.assertIn('telegraph/data/REGENERATE.txt', names)
            self.assertIn('telegraph/VERSION', names)
            self.assertEqual(len(names), len(manifest))

    def test_refuses_to_ship_without_spell_table(self):
        # bars are blind without the spell/skill tables; the mobs/
        # directory however is OPTIONAL for telegraph
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / 'data'
            data_dir.mkdir()
            (data_dir / 'mobskills.lua').write_text('return {}\n')
            # spells.lua missing

            with self.assertRaises(SystemExit) as caught:
                X.build_zip(TELEGRAPH_DIR, data_dir,
                            Path(tmp) / 'out.zip', '0.0.1', 'fixture',
                            'telegraph')

            self.assertIn('without data tables', str(caught.exception))

    def test_mob_tables_optional_for_telegraph(self):
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / 'data'
            data_dir.mkdir()
            (data_dir / 'spells.lua').write_text('return {}\n')
            (data_dir / 'mobskills.lua').write_text('return {}\n')

            out = Path(tmp) / 'telegraph-v0.0.1-beta.zip'
            manifest = X.build_zip(TELEGRAPH_DIR, data_dir, out,
                                   '0.0.1', 'fixture', 'telegraph')

            self.assertTrue(out.exists())
            self.assertTrue(len(manifest) > 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
