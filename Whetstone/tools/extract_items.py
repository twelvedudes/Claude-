#!/usr/bin/env python3
"""Whetstone item database extractor.

Parses a Phoenix (phoenixffxi/Phoenix) checkout into a Lua lookup of
equippable items and the modifiers the advisor cares about - most
importantly EXACT gear haste (Mod 384, 10000-based on LSB), plus
attack/accuracy/stats for "swap X for Y" advice and weapon base
damage/delay/skill for fSTR ranks, pDIF caps and TP feed.

Sources:
    sql/item_equipment.sql  itemId, name, level, jobs mask, slot mask
    sql/item_weapon.sql     skill, dmg, delay, damage type
    sql/item_mods.sql       (itemId, modId, value) - whitelisted below

Phoenix's era item SQL (modules/phoenix/sql/pxi_item_basic.sql) only
adjusts flags (sale/mail), not stats, so the base tables are
authoritative for stats.

Emitted mod keys (src/map/modifier.h ids):
    str dex vit agi int mnd chr        8-14
    att ratt acc racc                  23-26
    attp                               62
    eva                                68
    store_tp                           73
    crit_rate                          165
    delay_flat                         171   (flat delay add, weapons)
    martial_arts                       173
    dual_wield                         259
    double_attack                      288
    subtle_blow                        289
    triple_attack                      302
    delay_p                            380
    haste                              384   (10000-based: 375 = 3.75%)

Usage:
    python3 tools/extract_items.py --server /path/to/Phoenix \
        --out data/items.lua [--all-mods]
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

from extract_mobs import (ConservationError, collect_module_sql,
                          parse_sql_rows_checked)
from extract_ws import SKILL_NAMES

# Columns the emitted database depends on; module UPDATEs touching
# these must be applied or extraction fails loudly.
CONSUMED_EQUIPMENT_COLUMNS = {'itemId', 'name', 'level', 'jobs', 'slot',
                              'shieldSize'}

MOD_KEYS = {
    8: 'str', 9: 'dex', 10: 'vit', 11: 'agi', 12: 'int', 13: 'mnd',
    14: 'chr',
    23: 'att', 24: 'ratt', 25: 'acc', 26: 'racc',
    62: 'attp',
    68: 'eva',
    73: 'store_tp',
    165: 'crit_rate',
    171: 'delay_flat',
    173: 'martial_arts',
    259: 'dual_wield',
    288: 'double_attack',
    289: 'subtle_blow',
    302: 'triple_attack',
    380: 'delay_p',
    384: 'haste',
}

# item_equipment.slot bitmask positions (client equip slot ids)
SLOT_NAMES = [
    'main', 'sub', 'ranged', 'ammo', 'head', 'body', 'hands', 'legs',
    'feet', 'neck', 'waist', 'ear1', 'ear2', 'ring1', 'ring2', 'back',
]


def decode_slots(mask: int) -> list:
    return [name for bit, name in enumerate(SLOT_NAMES) if mask & (1 << bit)]


def decode_jobs(mask: int) -> list:
    """item_equipment.jobs: bit (jobId - 1) per job, WAR = bit 0."""
    from extract_mobs import JOB_NAMES

    return [JOB_NAMES[job] for job in range(1, 23) if mask & (1 << (job - 1))]


def extract(server_root: Path, all_mods: bool = False) -> tuple:
    """Returns (items, accounting)."""
    server_root = Path(server_root)
    sql = server_root / 'sql'

    tables = ('item_equipment', 'item_weapon', 'item_mods')
    module_inserts, module_updates = collect_module_sql(server_root, tables)

    def rows(table):
        result = parse_sql_rows_checked(sql / (table + '.sql'), table)
        result.extend(module_inserts.get(table, []))
        return result

    items = {}
    by_name = defaultdict(list)

    for row in rows('item_equipment'):
        item_id, name, level, ilevel, jobs, _mid, shield_size, \
            _script_type, slot = row[:9]

        items[item_id] = {
            'name': name,
            'level': level,
            'jobs': jobs,
            'slots': slot,
            'shield_size': shield_size or 0,
            'mods': {},
        }
        by_name[name].append(item_id)

    accounting = {
        'equipment_rows': len(items),
        'sql_updates_applied': 0,
        'sql_updates_ignored': 0,
        'mods_kept': 0,
        'mods_dropped_whitelist': 0,
        'mods_non_equipment': 0,
        'weapon_rows_matched': 0,
        'weapon_rows_non_equipment': 0,
    }

    # Module UPDATEs (abyssea job_adjustments fixes pet food levels via
    # `WHERE name = '...'`). Anything touching consumed columns that
    # cannot be applied raises.
    for update in module_updates:
        if update['table'] != 'item_equipment':
            accounting['sql_updates_ignored'] += 1
            continue

        touched = set(update['sets']) & CONSUMED_EQUIPMENT_COLUMNS

        if not touched:
            accounting['sql_updates_ignored'] += 1
            continue

        if update['where'] is None:
            raise ConservationError(
                '%s: unsupported item_equipment UPDATE (sets=%s)'
                % (update['source'], sorted(update['sets'])))

        targets = []
        if 'name' in update['where']:
            for name in update['where']['name']:
                targets.extend(by_name.get(name, []))
        elif 'itemId' in update['where']:
            targets = [item_id for item_id in update['where']['itemId']
                       if item_id in items]
        else:
            raise ConservationError(
                '%s: item_equipment UPDATE with unsupported WHERE %s'
                % (update['source'], update['where']))

        for item_id in targets:
            for column, value in update['sets'].items():
                if column == 'level':
                    items[item_id]['level'] = value
                elif column == 'jobs':
                    items[item_id]['jobs'] = value
                elif column == 'slot':
                    items[item_id]['slots'] = value
                elif column == 'name':
                    items[item_id]['name'] = value
                elif column == 'shieldSize':
                    items[item_id]['shield_size'] = value

            accounting['sql_updates_applied'] += 1

    for row in rows('item_weapon'):
        item_id, _name, skill, _subskill, _is, _ip, _im, dmg_type, hit, \
            delay, dmg = row[:11]

        if item_id in items:
            accounting['weapon_rows_matched'] += 1
            items[item_id]['weapon'] = {
                'skill': SKILL_NAMES.get(skill, 'none'),
                'dmg': dmg,
                'delay': delay,
                'dmg_type': dmg_type,
                'hit_count': hit,
            }
        else:
            # ammo/"weapons" with no equipment row (fish, pebbles...)
            accounting['weapon_rows_non_equipment'] += 1

    for row in rows('item_mods'):
        item_id, mod_id, value = row[:3]

        if item_id not in items:
            accounting['mods_non_equipment'] += 1
            continue

        if mod_id in MOD_KEYS:
            key = MOD_KEYS[mod_id]
            items[item_id]['mods'][key] = \
                items[item_id]['mods'].get(key, 0) + value
            accounting['mods_kept'] += 1
        elif all_mods:
            items[item_id]['mods']['mod%d' % mod_id] = value
            accounting['mods_kept'] += 1
        else:
            accounting['mods_dropped_whitelist'] += 1

    return items, accounting


def emit_lua(items: dict, source: str) -> str:
    lines = [
        '-- Generated by Whetstone tools/extract_items.py - DO NOT EDIT',
        '-- Source: ' + source,
        '-- itemId -> equipment stats; haste is 10000-based (375 = 3.75%)',
        'return {',
    ]

    for item_id in sorted(items):
        item = items[item_id]
        parts = [
            "name = '%s'" % str(item['name']).replace("'", "\\'"),
            'level = %d' % item['level'],
            'jobs = %d' % item['jobs'],
            'slots = %d' % item['slots'],
        ]

        if item['shield_size']:
            parts.append('shield_size = %d' % item['shield_size'])

        weapon = item.get('weapon')
        if weapon:
            parts.append(
                "weapon = { skill = '%s', dmg = %d, delay = %d, "
                'dmg_type = %d, hit_count = %d }'
                % (weapon['skill'], weapon['dmg'], weapon['delay'],
                   weapon['dmg_type'], weapon['hit_count']))

        if item['mods']:
            mods = ', '.join('%s = %d' % (key, value) for key, value
                             in sorted(item['mods'].items()))
            parts.append('mods = { %s }' % mods)

        lines.append('    [%d] = { %s },' % (item_id, ', '.join(parts)))

    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--server', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--all-mods', action='store_true',
                        help='emit every item mod, not just the whitelist')
    parser.add_argument('--source-label', default=None)
    args = parser.parse_args(argv)

    items, accounting = extract(Path(args.server), all_mods=args.all_mods)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        emit_lua(items, args.source_label or str(args.server)),
        encoding='utf-8')

    with_haste = sum(1 for item in items.values()
                     if item['mods'].get('haste'))
    weapons = sum(1 for item in items.values() if 'weapon' in item)

    print('wrote %s: %d items (%d weapons, %d with gear haste)'
          % (out_path, len(items), weapons, with_haste))
    print('conservation: %s' % ', '.join(
        '%s=%d' % kv for kv in sorted(accounting.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
