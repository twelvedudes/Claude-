#!/usr/bin/env python3
"""Whetstone/Telegraph release packager.

Builds <addon>-v<version>-beta.zip containing the addon, the SHARED
modules (shared/actionpacket.lua, shared/selftest.lua - bundled into
the addon root so require('actionpacket') / require('selftest')
resolve in a standalone install), all GENERATED data tables (an addon
must never ship without its data), README, PROVENANCE and the
regeneration commands.

Two modes:
    --server PATH    regenerate every table from a Phoenix checkout
                     (conservation checks run as part of generation
                     and abort packaging on any imbalance)
    --data-dir PATH  bundle pre-generated tables (CI / offline tests)

Usage:
    python3 tools/package_release.py --version 0.1.0 \
        --server /path/to/Phoenix [--addon whetstone|telegraph] [--out dist/]
"""

from __future__ import annotations

import argparse
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# Shared modules bundled into EVERY addon zip at the addon root: the
# require name stays canonical ('actionpacket', 'selftest') and a
# standalone install needs no repo layout.
SHARED_FILES = ['actionpacket.lua', 'selftest.lua']

WHETSTONE_REGEN = """\
This data/ directory was generated from {label}.

To regenerate against a different server commit:

    python3 tools/extract_mobs.py  --server <checkout> \\
        --out data/mobs --split --source-label "<label>"
    python3 tools/extract_ws.py    --server <checkout> \\
        --out data/weaponskills.lua --source-label "<label>"
    python3 tools/extract_items.py --server <checkout> \\
        --out data/items.lua --source-label "<label>"

All extractors carry conservation checks and fail loudly rather than
emit incomplete tables.
"""

TELEGRAPH_REGEN = """\
This data/ directory was generated from {label}.

To regenerate against a different server commit:

    python3 Telegraph/tools/extract_spells.py    --server <checkout> \\
        --out data/spells.lua --source-label "<label>"
    python3 Telegraph/tools/extract_mobskills.py --server <checkout> \\
        --out data/mobskills.lua --source-label "<label>"
    python3 Whetstone/tools/extract_mobs.py      --server <checkout> \\
        --out data/mobs --split --source-label "<label>"

All extractors carry conservation checks and fail loudly rather than
emit incomplete tables. The mobs/ tables are OPTIONAL for Telegraph
(the TP ledger widens its bounds without them) but ship by default.
"""

ADDONS = {
    'whetstone': {
        'dir': REPO_ROOT / 'Whetstone',
        'files': [
            'whetstone.lua', 'formulas.lua', 'player.lua', 'advisor.lua',
            'ui.lua', 'swinglog.lua', 'config.lua', 'narrow.lua',
            'README.md', 'PROVENANCE.md',
        ],
        # the zip must never ship a formula engine without its data
        'required_data': [
            'weaponskills.lua', 'items.lua', 'mobs/index.lua',
        ],
        'regen': WHETSTONE_REGEN,
    },
    'telegraph': {
        'dir': REPO_ROOT / 'Telegraph',
        'files': [
            'telegraph.lua', 'tpledger.lua', 'castbar.lua', 'ui.lua',
            'config.lua',
            'README.md', 'PROVENANCE.md',
        ],
        # bars are blind without the spell/skill tables; mobs/ is the
        # optional precision layer
        'required_data': [
            'spells.lua', 'mobskills.lua',
        ],
        'regen': TELEGRAPH_REGEN,
    },
}

# Backwards-compatible alias (older tooling/tests import ADDON_FILES)
ADDON_FILES = ADDONS['whetstone']['files']


def generate_tables(server: Path, data_dir: Path, label: str,
                    addon: str) -> None:
    """Run the addon's extractors; ConservationErrors propagate."""
    if addon == 'whetstone':
        import extract_items
        import extract_mobs
        import extract_ws

        mob_data = extract_mobs.ServerData(server)
        mobs, accounting = extract_mobs.extract(mob_data)
        extract_mobs.emit_split(mobs, accounting, data_dir / 'mobs', label)

        ws_db, _ = extract_ws.extract(server)
        (data_dir / 'weaponskills.lua').write_text(
            extract_ws.emit_lua(ws_db, label), encoding='utf-8')

        items, _ = extract_items.extract(server)
        (data_dir / 'items.lua').write_text(
            extract_items.emit_lua(items, label), encoding='utf-8')
        return

    sys.path.insert(0, str(REPO_ROOT / 'Telegraph' / 'tools'))

    import extract_mobs
    import extract_mobskills
    import extract_spells

    spells, _ = extract_spells.extract(server)
    (data_dir / 'spells.lua').write_text(
        extract_spells.emit_lua(spells, label), encoding='utf-8')

    skills, _ = extract_mobskills.extract(server)
    (data_dir / 'mobskills.lua').write_text(
        extract_mobskills.emit_lua(skills, label), encoding='utf-8')

    mob_data = extract_mobs.ServerData(server)
    mobs, accounting = extract_mobs.extract(mob_data)
    extract_mobs.emit_split(mobs, accounting, data_dir / 'mobs', label)


def validate_data_dir(data_dir: Path, addon: str) -> list:
    required = [data_dir / name for name in ADDONS[addon]['required_data']]
    missing = [str(path) for path in required if not path.exists()]

    if missing:
        raise SystemExit('refusing to package without data tables: '
                         + ', '.join(missing))

    return sorted(data_dir.rglob('*.lua'))


def build_zip(addon_dir: Path, data_dir: Path, out_path: Path,
              version: str, label: str, addon: str = 'whetstone',
              shared_dir: Path = None) -> list:
    info = ADDONS[addon]
    data_files = validate_data_dir(data_dir, addon)
    shared_dir = shared_dir or (REPO_ROOT / 'shared')

    missing_addon = [name for name in info['files']
                     if not (addon_dir / name).exists()]
    if missing_addon:
        raise SystemExit('missing addon files: ' + ', '.join(missing_addon))

    missing_shared = [name for name in SHARED_FILES
                      if not (shared_dir / name).exists()]
    if missing_shared:
        raise SystemExit('missing shared modules: '
                         + ', '.join(missing_shared))

    manifest = []

    out_path.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(out_path, 'w', zipfile.ZIP_DEFLATED) as bundle:
        for name in info['files']:
            arcname = '%s/%s' % (addon, name)
            bundle.write(addon_dir / name, arcname)
            manifest.append(arcname)

        # shared modules land at the addon ROOT: the canonical require
        # names resolve through the addon's own package.path entry
        for name in SHARED_FILES:
            arcname = '%s/%s' % (addon, name)
            bundle.write(shared_dir / name, arcname)
            manifest.append(arcname)

        for path in data_files:
            arcname = '%s/data/%s' % (addon, path.relative_to(data_dir))
            bundle.write(path, arcname)
            manifest.append(arcname)

        bundle.writestr('%s/data/REGENERATE.txt' % addon,
                        info['regen'].format(label=label))
        manifest.append('%s/data/REGENERATE.txt' % addon)

        bundle.writestr('%s/VERSION' % addon,
                        '%s v%s-beta\nsource: %s\n'
                        % (addon, version, label))
        manifest.append('%s/VERSION' % addon)

    return manifest


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--version', required=True)
    parser.add_argument('--addon', default='whetstone',
                        choices=sorted(ADDONS))
    parser.add_argument('--server', default=None,
                        help='Phoenix checkout to regenerate tables from')
    parser.add_argument('--data-dir', default=None,
                        help='pre-generated data directory (alternative)')
    parser.add_argument('--addon-dir', default=None,
                        help='addon source directory (default: repo)')
    parser.add_argument('--out', default='dist')
    parser.add_argument('--source-label', default=None)
    args = parser.parse_args(argv)

    addon_dir = Path(args.addon_dir) if args.addon_dir \
        else ADDONS[args.addon]['dir']
    label = args.source_label or (args.server or args.data_dir or '?')

    if args.server:
        data_dir = Path(args.out) / ('data_build_%s' % args.addon)
        data_dir.mkdir(parents=True, exist_ok=True)
        generate_tables(Path(args.server), data_dir, label, args.addon)
    elif args.data_dir:
        data_dir = Path(args.data_dir)
    else:
        raise SystemExit('need --server or --data-dir')

    out_path = Path(args.out) / ('%s-v%s-beta.zip'
                                 % (args.addon, args.version))
    manifest = build_zip(addon_dir, data_dir, out_path, args.version,
                         label, args.addon)

    size_mb = out_path.stat().st_size / (1024 * 1024)
    print('wrote %s: %d files, %.1f MB' % (out_path, len(manifest),
                                           size_mb))
    return 0


if __name__ == '__main__':
    sys.exit(main())
