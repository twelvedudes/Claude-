#!/usr/bin/env python3
"""Whetstone release packager.

Builds whetstone-v<version>-beta.zip containing the addon, all three
GENERATED data tables (the formula engine must never ship without its
data), README, PROVENANCE and the regeneration commands.

Two modes:
    --server PATH    regenerate every table from a Phoenix checkout
                     (conservation checks run as part of generation
                     and abort packaging on any imbalance)
    --data-dir PATH  bundle pre-generated tables (CI / offline tests)

Usage:
    python3 tools/package_release.py --version 0.1.0 \
        --server /path/to/Phoenix [--out dist/]
"""

from __future__ import annotations

import argparse
import sys
import zipfile
from pathlib import Path

ADDON_FILES = [
    'whetstone.lua', 'formulas.lua', 'player.lua', 'advisor.lua',
    'ui.lua', 'swinglog.lua', 'selftest.lua',
    'README.md', 'PROVENANCE.md',
]

REGEN_NOTE = """\
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


def generate_tables(server: Path, data_dir: Path, label: str) -> None:
    """Run all three extractors; their ConservationErrors propagate."""
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


def validate_data_dir(data_dir: Path) -> list:
    """The zip must never ship a formula engine without its data."""
    required = [
        data_dir / 'weaponskills.lua',
        data_dir / 'items.lua',
        data_dir / 'mobs' / 'index.lua',
    ]

    missing = [str(path) for path in required if not path.exists()]

    if missing:
        raise SystemExit('refusing to package without data tables: '
                         + ', '.join(missing))

    return sorted(data_dir.rglob('*.lua'))


def build_zip(addon_dir: Path, data_dir: Path, out_path: Path,
              version: str, label: str) -> list:
    data_files = validate_data_dir(data_dir)

    missing_addon = [name for name in ADDON_FILES
                     if not (addon_dir / name).exists()]
    if missing_addon:
        raise SystemExit('missing addon files: ' + ', '.join(missing_addon))

    manifest = []

    out_path.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(out_path, 'w', zipfile.ZIP_DEFLATED) as bundle:
        for name in ADDON_FILES:
            arcname = 'whetstone/%s' % name
            bundle.write(addon_dir / name, arcname)
            manifest.append(arcname)

        for path in data_files:
            arcname = 'whetstone/data/%s' % path.relative_to(data_dir)
            bundle.write(path, arcname)
            manifest.append(arcname)

        bundle.writestr('whetstone/data/REGENERATE.txt',
                        REGEN_NOTE.format(label=label))
        manifest.append('whetstone/data/REGENERATE.txt')

        bundle.writestr('whetstone/VERSION',
                        'whetstone v%s-beta\nsource: %s\n'
                        % (version, label))
        manifest.append('whetstone/VERSION')

    return manifest


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--version', required=True)
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
        else Path(__file__).resolve().parent.parent
    label = args.source_label or (args.server or args.data_dir or '?')

    if args.server:
        data_dir = Path(args.out) / 'data_build'
        data_dir.mkdir(parents=True, exist_ok=True)
        generate_tables(Path(args.server), data_dir, label)
    elif args.data_dir:
        data_dir = Path(args.data_dir)
    else:
        raise SystemExit('need --server or --data-dir')

    out_path = Path(args.out) / ('whetstone-v%s-beta.zip' % args.version)
    manifest = build_zip(addon_dir, data_dir, out_path, args.version,
                         label)

    size_mb = out_path.stat().st_size / (1024 * 1024)
    print('wrote %s: %d files, %.1f MB' % (out_path, len(manifest),
                                           size_mb))
    return 0


if __name__ == '__main__':
    sys.exit(main())
