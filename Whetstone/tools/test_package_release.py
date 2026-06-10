#!/usr/bin/env python3
"""Tests for package_release.py (data-dir mode against the real addon
source tree, with a synthetic data directory).

Run: python3 Whetstone/tools/test_package_release.py
"""

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import package_release as X  # noqa: E402

ADDON_DIR = Path(__file__).resolve().parent.parent


def build_data_dir(root: Path):
    (root / 'mobs').mkdir(parents=True)
    (root / 'mobs' / 'index.lua').write_text(
        'return { total_entries = 1, zones = { [1] = '
        "{ file = 'zone_1', entries = 1 } } }\n")
    (root / 'mobs' / 'zone_1.lua').write_text("return { ['A'] = {} }\n")
    (root / 'weaponskills.lua').write_text('return {}\n')
    (root / 'items.lua').write_text('return {}\n')


class PackageReleaseTests(unittest.TestCase):
    def test_builds_complete_zip(self):
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp) / 'data'
            build_data_dir(data_dir)

            out = Path(tmp) / 'whetstone-v0.0.1-beta.zip'
            manifest = X.build_zip(ADDON_DIR, data_dir, out, '0.0.1',
                                   'fixture')

            self.assertTrue(out.exists())

            with zipfile.ZipFile(out) as bundle:
                names = set(bundle.namelist())

            # every addon file ships
            for name in X.ADDON_FILES:
                self.assertIn('whetstone/%s' % name, names)

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
                X.build_zip(ADDON_DIR, data_dir,
                            Path(tmp) / 'out.zip', '0.0.1', 'fixture')

            self.assertIn('without data tables', str(caught.exception))


if __name__ == '__main__':
    unittest.main(verbosity=2)
