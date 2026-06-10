#!/usr/bin/env python3
"""Whetstone weapon skill database extractor.

Builds a Lua WS database from a Phoenix (phoenixffxi/Phoenix) checkout,
preferring the server's own dated era parameters over any wiki table:

  1. `modules/wotg/lua/weaponskills/*.lua` - Phoenix's pre-WotG
     (2007-11-19) overrides, the era ground truth. Used when present.
  2. `scripts/actions/weaponskills/*.lua` - upstream baseline scripts,
     used for anything not overridden. Only UNCONDITIONAL `params.X = `
     assignments are taken, which automatically excludes the
     `if xi.settings.main.USE_ADOULIN_WEAPON_SKILL_CHANGES` blocks
     (Phoenix is a 75-cap era server).
  3. `sql/weapon_skills.sql` - metadata: WS id, weapon skill type,
     required combat skill level, element, skillchain properties, jobs.

Params are emitted VERBATIM (numHits, ftpMod, str_wsc, atkVaries,
critVaries, ...) so the generated table is a faithful transcript of the
server scripts; the advisor maps them onto formulas.ws_damage inputs.
`xi.skill.X` / `xi.element.X` / `xi.mod.X` references are translated to
lowercase strings.

Special weapon skills that bypass the damage pipeline entirely (Energy
Steal/Drain style) are emitted with kind = 'special' and no params.

Usage:
    python3 tools/extract_ws.py --server /path/to/Phoenix \
        --out data/weaponskills.lua
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from extract_mobs import parse_sql_rows

# src/common/mmo.h SKILLTYPE
SKILL_NAMES = {
    1: 'hand_to_hand', 2: 'dagger', 3: 'sword', 4: 'great_sword',
    5: 'axe', 6: 'great_axe', 7: 'scythe', 8: 'polearm', 9: 'katana',
    10: 'great_katana', 11: 'club', 12: 'staff',
    25: 'archery', 26: 'marksmanship', 27: 'throwing',
}

JOB_NAMES = [
    'NON', 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK',
    'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR',
    'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
]

KIND_BY_CALL = {
    'doPhysicalWeaponskill': 'physical',
    'doRangedWeaponskill': 'ranged',
    'doMagicWeaponskill': 'magic',
}

# ---------------------------------------------------------------------
# Lua block scanning
# ---------------------------------------------------------------------

OPENERS = re.compile(r'\b(?:then|do|function)\b')
CLOSERS = re.compile(r'\bend\b')
ASSIGNMENT = re.compile(r'params\.(\w+)\s*=\s*')

XI_REF = re.compile(r'^xi\.(skill|element|mod)\.(\w+)$')
SAFE_VALUE = re.compile(r'^[-+*/%() \t\d.]+$')


def strip_comment(line: str) -> str:
    index = line.find('--')
    return line if index < 0 else line[:index]


def translate_value(raw: str):
    """Translate one captured RHS to an emit-ready Lua literal."""
    raw = raw.strip().rstrip(',')

    if raw in ('true', 'false'):
        return raw

    match = XI_REF.match(raw)
    if match:
        return "'" + match.group(2).lower() + "'"

    if raw.startswith('{'):
        inner = raw[1:-1]
        parts = [translate_value(part) for part in inner.split(',')
                 if part.strip()]
        return '{ ' + ', '.join(parts) + ' }'

    if SAFE_VALUE.match(raw):
        return raw

    # Unresolvable expression (player state etc.) - keep as a string so
    # nothing silently evaluates, and so it is visible in review.
    return "'<dynamic: " + raw.replace("'", '"') + ">'"


def capture_value(text: str, start: int) -> tuple:
    """Capture the RHS of an assignment starting at `start`.

    Returns (raw_value, end_index). Handles brace-balanced tables and
    plain expressions terminated by the next `params.` assignment or
    end of line.
    """
    if text[start] == '{':
        depth = 0
        for index in range(start, len(text)):
            if text[index] == '{':
                depth += 1
            elif text[index] == '}':
                depth -= 1
                if depth == 0:
                    return text[start:index + 1], index + 1
        return text[start:], len(text)

    next_assignment = ASSIGNMENT.search(text, start)
    end = next_assignment.start() if next_assignment else len(text)
    return text[start:end].strip(), end


def parse_ws_function(lines) -> tuple:
    """Parse one onUseWeaponSkill function body.

    `lines` start at the line containing `function(` (depth 1 after it).
    Returns (params dict {name: lua_literal}, kind, consumed_line_count).
    Only assignments at the function's top level (depth 1) are taken:
    anything inside an if/for block - including the Adoulin settings
    block - is conditional and excluded from the era table.
    """
    params = {}
    kind = 'special'
    depth = 0
    consumed = 0

    for consumed, line in enumerate(lines):
        code = strip_comment(line)

        # `elseif ... then` re-uses its if's block: its `then` must not
        # count as a new opener or depth would drift upward.
        opens = (len(OPENERS.findall(code))
                 - len(re.findall(r'\belseif\b', code)))
        closes = len(CLOSERS.findall(code))

        # Assignments count at the depth BEFORE this line's tokens when
        # the line itself doesn't open a block before the assignment;
        # machine-formatted sources never mix `if ... then params.x =`
        # on one line, so evaluating at entry depth is correct.
        if depth == 1 and opens == 0:
            position = 0
            while True:
                match = ASSIGNMENT.search(code, position)
                if not match:
                    break
                value, position = capture_value(code, match.end())
                params[match.group(1)] = translate_value(value)

        for call, name in KIND_BY_CALL.items():
            if call in code:
                kind = name

        depth += opens - closes

        if consumed > 0 and depth <= 0:
            break

    return params, kind, consumed + 1


# ---------------------------------------------------------------------
# Source file parsing
# ---------------------------------------------------------------------

UPSTREAM_HEAD = re.compile(r'onUseWeaponSkill\s*=\s*function\s*\(')
OVERRIDE_HEAD = re.compile(
    r"addOverride\('xi\.actions\.weaponskills\.(\w+)\.onUseWeaponSkill'")


def parse_upstream_script(path: Path):
    """scripts/actions/weaponskills/<name>.lua -> (params, kind) or None."""
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()

    for index, line in enumerate(lines):
        if UPSTREAM_HEAD.search(strip_comment(line)):
            params, kind, _ = parse_ws_function(lines[index:])
            return params, kind

    return None


def parse_module_file(path: Path) -> dict:
    """modules/.../weaponskills/<weapon>.lua -> { ws_name: (params, kind) }."""
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    overrides = {}
    index = 0

    while index < len(lines):
        match = OVERRIDE_HEAD.search(strip_comment(lines[index]))
        if match:
            params, kind, consumed = parse_ws_function(lines[index:])
            overrides[match.group(1)] = (params, kind)
            index += consumed
        else:
            index += 1

    return overrides


def parse_ws_metadata(sql_path: Path) -> dict:
    """sql/weapon_skills.sql -> { name: meta dict }."""
    meta = {}

    for row in parse_sql_rows(sql_path, 'weapon_skills'):
        (wsid, name, jobs_blob, ws_type, skilllevel, element, _anim,
         _animtime, ws_range, aoe, _radius, primary_sc, secondary_sc,
         tertiary_sc, main_only, unlock_id) = row[:16]

        jobs = []
        if isinstance(jobs_blob, str) and jobs_blob.startswith('0x'):
            raw = bytes.fromhex(jobs_blob[2:])
            jobs = [JOB_NAMES[i + 1] for i in range(min(len(raw), 22))
                    if raw[i] > 0]

        meta[name] = {
            'id': wsid,
            'skill': SKILL_NAMES.get(ws_type, 'none'),
            'skill_level': skilllevel,
            'element': element,
            'range': ws_range,
            'aoe': aoe,
            'sc': [sc for sc in (primary_sc, secondary_sc, tertiary_sc)
                   if sc],
            'main_only': bool(main_only),
            'unlock_id': unlock_id,
            'jobs': jobs,
        }

    return meta


# ---------------------------------------------------------------------
# Extraction + emission
# ---------------------------------------------------------------------


def extract(server_root: Path) -> dict:
    server_root = Path(server_root)

    meta = parse_ws_metadata(server_root / 'sql' / 'weapon_skills.sql')

    upstream_dir = server_root / 'scripts' / 'actions' / 'weaponskills'
    module_dir = (server_root / 'modules' / 'wotg' / 'lua' / 'weaponskills')

    overrides = {}
    if module_dir.is_dir():
        for path in sorted(module_dir.glob('*.lua')):
            overrides.update(parse_module_file(path))

    database = {}

    for name, info in meta.items():
        entry = dict(info)

        if name in overrides:
            params, kind = overrides[name]
            entry['source'] = 'wotg_module'
        else:
            script = upstream_dir / (name + '.lua')
            if not script.exists():
                continue
            parsed = parse_upstream_script(script)
            if parsed is None:
                continue
            params, kind = parsed
            entry['source'] = 'base_script'

        entry['kind'] = kind
        entry['params'] = params
        database[name] = entry

    return database


def emit_lua(database: dict, source: str) -> str:
    lines = [
        '-- Generated by Whetstone tools/extract_ws.py - DO NOT EDIT',
        '-- Source: ' + source,
        '-- Era WS parameters; params are verbatim from the server scripts',
        'return {',
    ]

    for name in sorted(database):
        entry = database[name]

        jobs = ', '.join("'%s'" % job for job in entry['jobs'])
        sc = ', '.join(str(x) for x in entry['sc'])

        lines.append("    ['%s'] = {" % name)
        lines.append(
            '        id = %d, skill = %r, skill_level = %d, element = %d,'
            % (entry['id'], entry['skill'], entry['skill_level'],
               entry['element']))
        lines.append(
            '        kind = %r, source = %r, main_only = %s, unlock_id = %d,'
            % (entry['kind'], entry['source'],
               'true' if entry['main_only'] else 'false',
               entry['unlock_id']))
        lines.append('        jobs = { %s }, sc = { %s },' % (jobs, sc))

        if entry['params']:
            assignments = ', '.join(
                '%s = %s' % (key, value)
                for key, value in sorted(entry['params'].items()))
            lines.append('        params = { %s },' % assignments)
        else:
            lines.append('        params = {},')

        lines.append('    },')

    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--server', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--source-label', default=None)
    args = parser.parse_args(argv)

    database = extract(Path(args.server))

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        emit_lua(database, args.source_label or str(args.server)),
        encoding='utf-8')

    by_source = {}
    for entry in database.values():
        by_source[entry['source']] = by_source.get(entry['source'], 0) + 1

    print('wrote %s: %d weapon skills (%s)' % (
        out_path, len(database),
        ', '.join('%s: %d' % kv for kv in sorted(by_source.items()))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
