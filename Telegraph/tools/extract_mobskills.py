#!/usr/bin/env python3
"""Telegraph mob skill table extractor.

Builds a Lua mob skill lookup (skill id -> name + windup + TP flags)
from a Phoenix (phoenixffxi/Phoenix) checkout:

  `sql/mob_skills.sql` columns consumed:
    mob_skill_id        the id carried in SkillStart result.param and
                        in the finish packet's cmd_arg
    mob_skill_name      display name (prettified; raw kept)
    mob_prepare_time    the READYING windup in milliseconds
                        (battleutils.cpp setActivationTime; skills
                        with 0 never emit a readying packet -
                        mobskill_state.cpp `if (m_castTime > 0s)`)
    mob_skill_flag      SKILLFLAG_NO_TP_COST (0x004) -> tp_free: the
                        ledger must NOT zero TP on these
                        (mobskill_state.cpp SpendCost / isTpFreeSkill)

No enabled Phoenix module touches mob_skills (audited - see
Telegraph/PROVENANCE.md), but module INSERT/UPDATE collection runs
anyway so a future module addition fails loudly instead of silently
diverging.

Per-mob zone scripts can override the windup at runtime
(luautils::OnMobSkillReadyTime) - not client-readable; the bar shows
the table value and the analyzer judges observed-vs-table.

Usage:
    python3 Telegraph/tools/extract_mobskills.py --server /path/to/Phoenix \
        --out Telegraph/data/mobskills.lua --source-label "phoenixffxi/Phoenix @ <commit>"
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent
                       / 'Whetstone' / 'tools'))

from extract_mobs import (ConservationError, collect_module_sql,  # noqa: E402
                          parse_sql_rows_checked)

from extract_spells import lua_string, pretty_name  # noqa: E402

# src/map/mobskill.h
SKILLFLAG_NO_TP_COST = 0x004

CONSUMED_COLUMNS = {'mob_skill_id', 'mob_skill_name',
                    'mob_prepare_time', 'mob_skill_flag'}

SET_VAR_RE = re.compile(r'^SET\s+(@\w+)\s*=\s*(\d+)\s*;', re.IGNORECASE)


def parse_set_variables(path: Path) -> dict:
    """MySQL SET @NAME = <int>; lines (mob_skills.sql defines the
    SKILLFLAG_* constants this way and uses them in the flag column)."""
    variables = {}

    with path.open(encoding='utf-8', errors='replace') as handle:
        for line in handle:
            match = SET_VAR_RE.match(line.strip())

            if match:
                variables[match.group(1)] = int(match.group(2))

    return variables


def resolve_flag(value, variables: dict, context: str) -> int:
    """A flag cell: int, @VARIABLE, or an OR of either ('@A | @B').
    Anything else fails loudly - a silently-misread NO_TP_COST flag
    would corrupt the TP ledger's spend logic."""
    if isinstance(value, int):
        return value

    total = 0

    for token in str(value).split('|'):
        token = token.strip()

        if re.fullmatch(r'\d+', token):
            total |= int(token)
        elif token in variables:
            total |= variables[token]
        else:
            raise ConservationError(
                '%s: unresolvable mob_skill_flag %r' % (context, value))

    return total


def extract(server_root: Path) -> tuple:
    """Returns (skills, accounting). skills: {id: {name, pretty,
    windup_ms, tp_free}}."""
    server_root = Path(server_root)

    module_inserts, module_updates = collect_module_sql(
        server_root, ('mob_skills',))

    for update in module_updates:
        touched = set(update['sets']) & CONSUMED_COLUMNS

        if touched:
            raise ConservationError(
                '%s: module UPDATE on mob_skills touches consumed '
                'columns %s - extractor must be taught to apply it'
                % (update['source'], sorted(touched)))

    sql_path = server_root / 'sql' / 'mob_skills.sql'
    variables = parse_set_variables(sql_path)
    rows = parse_sql_rows_checked(sql_path, 'mob_skills')
    rows.extend(module_inserts.get('mob_skills', []))

    skills = {}
    accounting = {
        'total': len(rows),
        'emitted': 0,
        'duplicate_id': 0,
        'sql_updates_ignored': len(module_updates),
    }

    for row in rows:
        # mob_skills columns: mob_skill_id 0, mob_anim_id 1,
        # mob_skill_name 2, mob_skill_aoe 3, mob_skill_aoe_radius 4,
        # mob_skill_distance 5, mob_anim_time 6, mob_prepare_time 7,
        # mob_valid_targets 8, mob_skill_flag 9, ...
        skill_id, name = row[0], row[2]
        windup_ms = row[7]
        flag = resolve_flag(row[9], variables,
                            'mob_skills id %s' % skill_id)

        if skill_id in skills:
            accounting['duplicate_id'] += 1
            continue

        skills[skill_id] = {
            'name': name,
            'pretty': pretty_name(name),
            'windup_ms': windup_ms,
            'tp_free': bool(flag & SKILLFLAG_NO_TP_COST),
        }
        accounting['emitted'] += 1

    accounted = accounting['emitted'] + accounting['duplicate_id']
    if accounted != accounting['total']:
        raise ConservationError(
            'mob_skills rows: %d total, %d accounted (%s)'
            % (accounting['total'], accounted, accounting))

    return skills, accounting


def emit_lua(skills: dict, source: str) -> str:
    lines = [
        '-- Generated by Telegraph tools/extract_mobskills.py - DO NOT EDIT',
        '-- Source: ' + source,
        '-- mob skill id -> name + readying windup (ms) + tp_free',
        '-- (SKILLFLAG_NO_TP_COST). windup 0 = instant: the server',
        '-- never emits a readying packet for these',
        'return {',
        "    vintage = %s," % lua_string(source),
    ]

    for skill_id in sorted(skills):
        info = skills[skill_id]

        lines.append(
            '    [%d] = { name = %s, raw = %s, windup_ms = %d%s },'
            % (skill_id, lua_string(info['pretty']),
               lua_string(info['name']), info['windup_ms'],
               ', tp_free = true' if info['tp_free'] else ''))

    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--server', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--source-label', default=None)
    args = parser.parse_args(argv)

    skills, accounting = extract(Path(args.server))

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        emit_lua(skills, args.source_label or str(args.server)),
        encoding='utf-8')

    with_windup = sum(1 for info in skills.values()
                      if info['windup_ms'] > 0)
    tp_free = sum(1 for info in skills.values() if info['tp_free'])

    print('wrote %s: %d mob skills (%d with windup, %d tp-free)'
          % (out_path, len(skills), with_windup, tp_free))
    print('conservation: %s' % ', '.join(
        '%s=%d' % kv for kv in sorted(accounting.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
