#!/usr/bin/env python3
"""Telegraph spell table extractor.

Builds a Lua spell lookup (spell id -> name + cast time) from a
Phoenix (phoenixffxi/Phoenix) checkout for the cast bars:

  1. `sql/spell_list.sql` - spellid, name, castTime (milliseconds:
     spell.cpp loads the column with std::chrono::milliseconds).
  2. Enabled-module SQL (modules/init.txt) UPDATEs - Phoenix's era
     modules adjust cast times directly (soa/magic_adjustments.sql,
     wotg/job_adjustments.sql, abyssea/job_adjustments.sql). Any
     module UPDATE touching a consumed column must be applied or
     extraction fails (ConservationError); updates limited to columns
     we do not consume (CE/VE enmity, jobs, mpCost...) are counted and
     ignored.

Display names are prettified from the SQL snake_case ('cure_ii' ->
'Cure II'); the raw name travels too so logs stay greppable against
the server source.

Server-side cast time MODIFIERS (fast cast, Slow, mob mods, Quick
Magic - battleutils.cpp CalculateSpellCastTime) are deliberately NOT
modeled: they are not client-readable. The cast bar displays the
table value and /tele debug logs observed-vs-table for the analyzer.

Usage:
    python3 Telegraph/tools/extract_spells.py --server /path/to/Phoenix \
        --out Telegraph/data/spells.lua --source-label "phoenixffxi/Phoenix @ <commit>"
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# The SQL plumbing (checked INSERT parser, module collection,
# conservation) is Whetstone's - one implementation, shared by every
# extractor in the repo.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent
                       / 'Whetstone' / 'tools'))

from extract_mobs import (ConservationError, collect_module_sql,  # noqa: E402
                          parse_sql_rows_checked)

# Columns of spell_list the emitted table depends on. A module UPDATE
# touching any of these must be applied (or extraction fails).
CONSUMED_COLUMNS = {'spellid', 'name', 'castTime'}

# Roman numerals and japanese tier words used by spell names; kept
# uppercase / capitalized in display names.
UPPER_WORDS = {'ii', 'iii', 'iv', 'v', 'vi'}


def pretty_name(raw: str) -> str:
    """'cure_ii' -> 'Cure II'; 'utsusemi_ichi' -> 'Utsusemi Ichi'."""
    words = []

    for word in str(raw).split('_'):
        if word in UPPER_WORDS:
            words.append(word.upper())
        else:
            words.append(word.capitalize())

    return ' '.join(words)


def apply_spell_updates(spells: dict, updates: list) -> tuple:
    """Apply module UPDATE statements to the spell table.

    Only `WHERE name = '...'` / `WHERE name IN (...)` forms are needed
    by Phoenix's enabled modules; anything else touching consumed
    columns raises. Name matching is case-insensitive (MySQL default
    collation; abyssea files write capitalized names). An update that
    touches consumed columns but matches NO spell raises too - a
    silently-missed castTime override would be invisible forever.

    Returns (applied_count, ignored_count).
    """
    applied = 0
    ignored = 0

    by_lower = {info['name'].lower(): spell_id
                for spell_id, info in spells.items()}

    for update in updates:
        touched = set(update['sets']) & CONSUMED_COLUMNS

        if not touched:
            ignored += 1
            continue

        if update['where'] is None or 'name' not in update['where']:
            raise ConservationError(
                '%s: unsupported spell_list UPDATE (where=%s, sets=%s)'
                % (update['source'], update['where'],
                   sorted(update['sets'])))

        matched = 0

        for name in update['where']['name']:
            spell_id = by_lower.get(str(name).lower())

            if spell_id is None:
                continue

            if 'castTime' in update['sets']:
                spells[spell_id]['cast_ms'] = update['sets']['castTime']

            matched += 1
            applied += 1

        if matched == 0:
            raise ConservationError(
                '%s: spell_list UPDATE touching %s matched no spell '
                '(WHERE name IN %s)'
                % (update['source'], sorted(touched),
                   update['where']['name']))

    return applied, ignored


def extract(server_root: Path) -> tuple:
    """Returns (spells, accounting). spells: {id: {name, pretty,
    cast_ms}}."""
    server_root = Path(server_root)

    module_inserts, module_updates = collect_module_sql(
        server_root, ('spell_list',))

    rows = parse_sql_rows_checked(
        server_root / 'sql' / 'spell_list.sql', 'spell_list')
    rows.extend(module_inserts.get('spell_list', []))

    spells = {}
    accounting = {
        'total': len(rows),
        'emitted': 0,
        'duplicate_id': 0,
    }

    for row in rows:
        # spell_list columns: spellid 0, name 1, jobs 2, group 3,
        # family 4, element 5, zonemisc 6, validTargets 7, skill 8,
        # mpCost 9, castTime 10 (ms), ...
        spell_id, name = row[0], row[1]
        cast_ms = row[10]

        if spell_id in spells:
            accounting['duplicate_id'] += 1
            continue

        spells[spell_id] = {
            'name': name,
            'pretty': pretty_name(name),
            'cast_ms': cast_ms,
        }
        accounting['emitted'] += 1

    accounted = accounting['emitted'] + accounting['duplicate_id']
    if accounted != accounting['total']:
        raise ConservationError(
            'spell_list rows: %d total, %d accounted (%s)'
            % (accounting['total'], accounted, accounting))

    applied, ignored = apply_spell_updates(spells, module_updates)
    accounting['sql_updates_applied'] = applied
    accounting['sql_updates_ignored'] = ignored

    return spells, accounting


def lua_string(value: str) -> str:
    return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'") + "'"


def emit_lua(spells: dict, source: str) -> str:
    lines = [
        '-- Generated by Telegraph tools/extract_spells.py - DO NOT EDIT',
        '-- Source: ' + source,
        '-- spell id -> name + base cast time (ms); server-side cast',
        '-- modifiers (fast cast, Slow, Quick Magic) are NOT modeled -',
        '-- the bar shows the table value, /tele debug logs observed',
        'return {',
        "    vintage = %s," % lua_string(source),
    ]

    for spell_id in sorted(spells):
        info = spells[spell_id]

        lines.append('    [%d] = { name = %s, raw = %s, cast_ms = %d },'
                     % (spell_id, lua_string(info['pretty']),
                        lua_string(info['name']), info['cast_ms']))

    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--server', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--source-label', default=None)
    args = parser.parse_args(argv)

    spells, accounting = extract(Path(args.server))

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        emit_lua(spells, args.source_label or str(args.server)),
        encoding='utf-8')

    print('wrote %s: %d spells' % (out_path, len(spells)))
    print('conservation: %s' % ', '.join(
        '%s=%d' % kv for kv in sorted(accounting.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
