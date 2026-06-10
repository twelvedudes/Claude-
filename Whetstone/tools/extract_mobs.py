#!/usr/bin/env python3
"""Whetstone mob stat extractor.

Parses a Phoenix (phoenixffxi/Phoenix, LandSandBoat-based) server
checkout and emits a generated Lua lookup table:

    zone ID + mob name -> level range + VIT / AGI / DEF / EVA

Stats are computed at BOTH the minimum and maximum spawn level of each
mob, replicating the server's CalculateMobStats pipeline
(src/map/utils/mobutils.cpp @ 0f3f8fc):

    stat  = familyStat(rank, lvl) + mainJobStat(grade, lvl) + subJobStat
    DEF   = max(1, 8 + VIT // 2 + GetBaseDefEva(defRank, lvl)
                  + trait DEF + pool/species DEF mods)
    EVA   = max(1, GetBaseDefEva(evaRank(mJob, sJob), lvl) + AGI // 2
                  + trait EVA + pool/species EVA mods)

where the subjob contribution uses GetSubJobStats in original/RoZ zones
below sub level 50 and a flat /2 elsewhere, sub level == main level
(map.INCLUDE_MOB_SJ default), and evaRank picks the better evasion
skill rank of the two jobs (JobSkillRankToBaseEvaRank).

Deliberately ignored (defaults / not stat-relevant at 75):
    MOB_STAT_MULTIPLIER / NM_STAT_MULTIPLIER (1.0 by default), HP/MP,
    mob_spawn_mods, dynamic mods applied by scripts at spawn time.

Data sources (all parsed with a self-contained INSERT parser, one
tuple per line as dumped by LSB):
    sql/mob_spawn_points.sql   mob name + groupid + minLevel/maxLevel
    sql/mob_groups.sql         (zoneid, groupid) -> poolid
    sql/mob_pools.sql          poolid -> speciesid, mJob, sJob
    sql/mob_species_system.sql speciesID -> family stat/def ranks
    sql/mob_pool_mods.sql      flat DEF/EVA modifier overrides
    sql/mob_species_mods.sql   flat DEF/EVA modifier overrides
    sql/skill_ranks.sql        per-job evasion skill ranks
    sql/traits.sql             job traits carrying DEF/EVA modifiers
    src/map/zone.h             ZONEID enum (subjob-zone list)

Usage:
    python3 tools/extract_mobs.py --server /path/to/Phoenix \
        --out data/mobs.lua [--zone 100 --zone 101 ...]
"""

from __future__ import annotations

import argparse
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------
# Constants lifted from the server source
# ---------------------------------------------------------------------

# src/map/grades.cpp JobGrades: [job][HP, MP, STR, DEX, VIT, AGI, INT, MND, CHR]
JOB_GRADES = [
    [0, 0, 0, 0, 0, 0, 0, 0, 0],  # NON
    [2, 0, 1, 3, 4, 3, 6, 6, 5],  # WAR
    [1, 0, 3, 2, 1, 6, 7, 4, 5],  # MNK
    [5, 3, 4, 6, 4, 5, 5, 1, 3],  # WHM
    [6, 2, 6, 3, 6, 3, 1, 5, 4],  # BLM
    [4, 4, 4, 4, 5, 5, 3, 3, 4],  # RDM
    [4, 0, 4, 1, 4, 2, 3, 7, 7],  # THF
    [3, 6, 2, 5, 1, 7, 7, 3, 3],  # PLD
    [3, 6, 1, 3, 3, 4, 3, 7, 7],  # DRK
    [3, 0, 4, 3, 4, 6, 5, 5, 1],  # BST
    [4, 0, 4, 4, 4, 6, 4, 4, 2],  # BRD
    [5, 0, 5, 4, 4, 1, 5, 4, 5],  # RNG
    [2, 0, 3, 3, 3, 4, 5, 5, 4],  # SAM
    [4, 0, 3, 2, 3, 2, 4, 7, 6],  # NIN
    [3, 0, 2, 4, 3, 4, 6, 5, 3],  # DRG
    [7, 1, 6, 5, 6, 4, 2, 2, 2],  # SMN
    [4, 4, 5, 5, 5, 5, 5, 5, 5],  # BLU
    [4, 0, 5, 3, 5, 2, 3, 5, 5],  # COR
    [4, 0, 5, 2, 4, 3, 5, 6, 3],  # PUP
    [4, 0, 4, 3, 5, 2, 6, 6, 2],  # DNC
    [5, 4, 6, 4, 5, 4, 3, 4, 3],  # SCH
    [3, 2, 6, 4, 5, 4, 3, 3, 4],  # GEO
    [3, 6, 3, 4, 5, 2, 4, 4, 6],  # RUN
]

GRADE_VIT = 4  # index into JOB_GRADES rows
GRADE_AGI = 5

JOB_NAMES = [
    'NON', 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK',
    'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR',
    'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
]

MOD_DEF = 1   # src/map/modifier.h Mod::DEF
MOD_EVA = 68  # src/map/modifier.h Mod::EVA

# mobutils.cpp CheckSubJobZone: original + RoZ zones where mob subjobs
# contribute via GetSubJobStats below sub level 50 (flat /2 elsewhere).
SUBJOB_ZONE_NAMES = [
    'WEST_RONFAURE', 'EAST_RONFAURE', 'LA_THEINE_PLATEAU', 'VALKURM_DUNES',
    'JUGNER_FOREST', 'BATALLIA_DOWNS', 'NORTH_GUSTABERG', 'SOUTH_GUSTABERG',
    'KONSCHTAT_HIGHLANDS', 'PASHHOW_MARSHLANDS', 'ROLANBERRY_FIELDS',
    'BEAUCEDINE_GLACIER', 'XARCABARD', 'CAPE_TERIGGAN', 'EASTERN_ALTEPA_DESERT',
    'WEST_SARUTABARUTA', 'EAST_SARUTABARUTA', 'TAHRONGI_CANYON',
    'BUBURIMU_PENINSULA', 'MERIPHATAUD_MOUNTAINS', 'SAUROMUGUE_CHAMPAIGN',
    'THE_SANCTUARY_OF_ZITAH', 'ROMAEVE', 'YUHTUNGA_JUNGLE', 'YHOATOR_JUNGLE',
    'WESTERN_ALTEPA_DESERT', 'QUFIM_ISLAND', 'BEHEMOTHS_DOMINION',
    'VALLEY_OF_SORROWS', 'HORLAIS_PEAK', 'GHELSBA_OUTPOST', 'FORT_GHELSBA',
    'YUGHOTT_GROTTO', 'PALBOROUGH_MINES', 'WAUGHROON_SHRINE', 'GIDDEUS',
    'BALGAS_DAIS', 'BEADEAUX', 'QULUN_DOME', 'DAVOI', 'MONASTIC_CAVERN',
    'CASTLE_OZTROJA', 'ALTAR_ROOM', 'THE_BOYAHDA_TREE', 'DRAGONS_AERY',
    'MIDDLE_DELKFUTTS_TOWER', 'UPPER_DELKFUTTS_TOWER', 'TEMPLE_OF_UGGALEPIH',
    'DEN_OF_RANCOR', 'CASTLE_ZVAHL_BAILEYS', 'CASTLE_ZVAHL_KEEP',
    'SACRIFICIAL_CHAMBER', 'THRONE_ROOM', 'RANGUEMONT_PASS',
    'BOSTAUNIEUX_OUBLIETTE', 'CHAMBER_OF_ORACLES', 'TORAIMARAI_CANAL',
    'FULL_MOON_FOUNTAIN', 'ZERUHN_MINES', 'KORROLOKA_TUNNEL', 'KUFTAL_TUNNEL',
    'SEA_SERPENT_GROTTO', 'VELUGANNON_PALACE', 'THE_SHRINE_OF_RUAVITAU',
    'STELLAR_FULCRUM', 'LALOFF_AMPHITHEATER', 'THE_CELESTIAL_NEXUS',
    'LOWER_DELKFUTTS_TOWER', 'KING_RANPERRES_TOMB', 'DANGRUF_WADI',
    'INNER_HORUTOTO_RUINS', 'ORDELLES_CAVES', 'OUTER_HORUTOTO_RUINS',
    'THE_ELDIEME_NECROPOLIS', 'GUSGEN_MINES', 'CRAWLERS_NEST',
    'MAZE_OF_SHAKHRAMI', 'GARLAIGE_CITADEL', 'CLOISTER_OF_GALES',
    'CLOISTER_OF_STORMS', 'CLOISTER_OF_FROST', 'FEIYIN', 'IFRITS_CAULDRON',
    'QUBIA_ARENA', 'CLOISTER_OF_FLAMES', 'QUICKSAND_CAVES',
    'CLOISTER_OF_TREMORS', 'CLOISTER_OF_TIDES', 'GUSTAV_TUNNEL',
    'LABYRINTH_OF_ONZOZO', 'SHIP_BOUND_FOR_SELBINA', 'SHIP_BOUND_FOR_MHAURA',
    'SHIP_BOUND_FOR_SELBINA_PIRATES', 'SHIP_BOUND_FOR_MHAURA_PIRATES',
]

# ---------------------------------------------------------------------
# Server stat formulas (mobutils.cpp)
# ---------------------------------------------------------------------


def base_to_rank(rank: int, lvl: int) -> int:
    """GetBaseToRank: family/job base stat for a grade A(1)..G(7)."""
    table = {
        1: (5, 50), 2: (4, 45), 3: (4, 40), 4: (3, 35),
        5: (3, 30), 6: (2, 25), 7: (2, 20),
    }

    if rank not in table:
        return 0

    base, scale = table[rank]
    return base + ((lvl - 1) * scale) // 100


def base_def_eva(rank: int, lvl: int) -> int:
    """GetBaseDefEva: f(level, rank) term of mob defense/evasion."""
    if lvl > 50:
        table = {1: (153, 5.0), 2: (147, 4.9), 3: (142, 4.8),
                 4: (136, 4.7), 5: (126, 4.5)}
        if rank not in table:
            return 0
        base, slope = table[rank]
        return math.floor(base + (lvl - 50) * slope)

    table = {1: (6, 3.0), 2: (5, 2.9), 3: (5, 2.8),
             4: (4, 2.7), 5: (4, 2.5)}
    if rank not in table:
        return 0
    base, slope = table[rank]
    return math.floor(base + (lvl - 1) * slope)


def sub_job_stats(rank: int, level: int, stat: int) -> int:
    """GetSubJobStats: subjob stat contribution in original/RoZ zones."""
    if rank == 1:  # A
        if level <= 30:
            return int(max(math.floor(stat / (4.0 - 0.225 * (level - 30))), 2.0))
        if level <= 40:
            return int(math.floor(stat / (3.25 - 0.073 * (level - 30))))
        if level <= 46:
            return int(math.floor(stat / (2.55 - 0.001 * (level - 41))))
        return int(math.floor(stat / (2.7 - 0.001 * (level - 45))))

    if rank == 2:  # B
        if level <= 30:
            return int(max(math.floor(stat / (3.1 - 0.075 * (level - 32))), 2.0))
        if level <= 40:
            return int(math.floor(stat / (3.1 - 0.075 * (level - 32))))
        if level <= 45:
            return int(math.floor(stat / (2.5 - 0.025 * (level - 40))))
        return int(math.floor(stat / (2.35 - 0.04 * (level - 44))))

    if rank == 3:  # C
        if level <= 30:
            return int(max(math.floor(stat / (4.5 - 0.15 * (level - 26))), 2.0))
        if level <= 40:
            return int(math.floor(stat / (3.28 - 0.001 * (level - 30))))
        if level <= 45:
            return int(math.floor(stat / (2.6 - 0.025 * (level - 40))))
        return int(math.floor(stat / (2.1 - 0.2 * (level - 49))))

    if rank == 4:  # D
        if level <= 30:
            return int(max(math.floor(stat / (5.0 - 0.05 * (level - 21))), 1.0))
        if level <= 40:
            return int(math.floor(stat / (3.2 - 0.001 * (level - 29))))
        if level <= 45:
            return int(math.floor(stat / (3.5 - 0.08 * (level - 32))))
        return int(math.floor(stat / (3.25 - 0.045 * (level - 32))))

    if rank == 5:  # E
        if level <= 30:
            return int(max(math.floor(stat / (3.8 - 0.1 * (level - 32))), 1.0))
        if level <= 40:
            return int(math.floor(stat / (3.8 - 0.15 * (level - 32))))
        if level <= 45:
            return int(math.floor(stat / (2.7 - 0.075 * (level - 40))))
        return int(math.floor(stat / (2.7 - 0.05 * (level - 45))))

    if rank == 6:  # F
        if level <= 30:
            return int(max(math.floor(stat / (4.0 - 0.15 * (level - 35))), 1.0))
        if level <= 40:
            return int(math.floor(stat / (4.0 - 0.15 * (level - 30))))
        if level <= 46:
            return int(math.floor(stat / (3.0 - 0.1125 * (level - 40))))
        return int(math.floor(stat / (3.0 - 0.07 * (level - 40))))

    if rank == 7:  # G
        if level <= 30:
            return int(max(math.floor(stat / (4.0 - 0.15 * (level - 35))), 1.0))
        if level <= 40:
            return int(math.floor(stat / (4.0 - 0.2 * (level - 31))))
        if level <= 46:
            return int(math.floor(stat / (2.5 - 0.09 * (level - 40))))
        return int(math.floor(stat / 2))

    return int(stat / 2)


def eva_rank_from_skill_ranks(main_rank: int, sub_rank: int) -> int:
    """JobSkillRankToBaseEvaRank: better (lower) skill rank wins."""
    best = min(main_rank, sub_rank)

    if best in (1, 2):
        return 1
    if best in (3, 4, 5):
        return 2
    if best in (6, 7, 8):
        return 3
    if best == 9:
        return 4
    if best == 10:
        return 5

    return 3  # server fallback


# ---------------------------------------------------------------------
# SQL dump parsing (one INSERT tuple per line, as dumped by LSB)
# ---------------------------------------------------------------------

INSERT_RE = re.compile(
    r"INSERT INTO `?(\w+)`?\s+VALUES\s*\((.*)\);\s*(?:--.*)?$",
    re.IGNORECASE)

# Independent of INSERT_RE on purpose: this only looks at the statement
# PREFIX, so any tail format the full regex chokes on (trailing
# comments, multi-line statements, ...) produces a count mismatch and a
# loud ConservationError instead of silently dropped rows.
INSERT_PREFIX_RE = re.compile(r"INSERT INTO `?(\w+)`?", re.IGNORECASE)


class ConservationError(RuntimeError):
    """Rows were encountered but neither parsed nor explicitly skipped."""


def count_insert_lines(path: Path, table: str) -> int:
    """Prefix-only count of INSERT statements for `table` in a dump."""
    count = 0

    with path.open(encoding='utf-8', errors='replace') as handle:
        for line in handle:
            stripped = line.strip()
            if stripped.upper().startswith('INSERT INTO'):
                match = INSERT_PREFIX_RE.match(stripped)
                if match and match.group(1) == table:
                    count += 1

    return count


def parse_sql_rows_checked(path: Path, table: str) -> list:
    """parse_sql_rows + conservation check.

    Every INSERT line for `table` (counted by prefix only) must be
    parsed by the full-line regex; a mismatch means the dump uses a
    format the parser doesn't understand, and that must never be
    silent again.
    """
    rows = list(parse_sql_rows(path, table))
    expected = count_insert_lines(path, table)

    if len(rows) != expected:
        raise ConservationError(
            '%s: %d INSERT lines for `%s` but only %d parsed - '
            'parser does not understand this dump format'
            % (path, expected, table, len(rows)))

    return rows


# ---------------------------------------------------------------------
# Enabled-module SQL (modules/init.txt)
# ---------------------------------------------------------------------


def enabled_module_sql_files(server_root: Path) -> list:
    """All *.sql files belonging to modules enabled in modules/init.txt."""
    init_path = Path(server_root) / 'modules' / 'init.txt'

    if not init_path.exists():
        return []

    files = []

    for raw_line in init_path.read_text(encoding='utf-8',
                                        errors='replace').splitlines():
        entry = raw_line.split('#', 1)[0].strip().rstrip('/')
        if not entry:
            continue

        path = Path(server_root) / 'modules' / entry

        if path.is_dir():
            files.extend(sorted(path.rglob('*.sql')))
        elif path.suffix == '.sql' and path.exists():
            files.append(path)

    return files


UPDATE_RE = re.compile(
    r"UPDATE\s+`?(\w+)`?\s+SET\s+(.+?)\s+WHERE\s+(.+)",
    re.IGNORECASE | re.DOTALL)
SET_PAIR_RE = re.compile(r"`?(\w+)`?\s*=\s*('[^']*'|-?\d+)")
WHERE_EQ_RE = re.compile(r"^`?(\w+)`?\s*=\s*('[^']*'|-?\d+)$")
WHERE_IN_RE = re.compile(r"^`?(\w+)`?\s+IN\s*\((.+)\)$",
                         re.IGNORECASE | re.DOTALL)


def _sql_literal(token: str):
    token = token.strip()

    if token.startswith("'"):
        return token[1:-1]

    return int(token)


def parse_module_updates(path: Path, tables=None) -> list:
    """Parse UPDATE statements from a module SQL file.

    Handles the forms Phoenix's enabled modules actually use:
        UPDATE t SET a = 1, b = 'x' WHERE name = 'y' [AND col = z];
        UPDATE t SET a = 1 WHERE name IN ('x', 'y', ...);
    Returns dicts: { table, sets {col: value}, where {col: [values]} }

    When `tables` is given, only statements targeting those tables are
    returned - and for THOSE, an unparseable statement raises
    ConservationError (an update to a consumed table must never be
    silently ignored). Statements for other tables are skipped freely.
    """
    text = path.read_text(encoding='utf-8', errors='replace')
    # strip line comments, then split statements
    text = re.sub(r'--[^\n]*', '', text)

    updates = []

    for statement in text.split(';'):
        statement = statement.strip()
        if not statement.upper().startswith('UPDATE'):
            continue

        prefix = re.match(r"UPDATE\s+`?(\w+)`?", statement, re.IGNORECASE)
        if tables is not None and (not prefix
                                   or prefix.group(1) not in tables):
            continue

        match = UPDATE_RE.match(statement)
        if not match:
            raise ConservationError(
                '%s: unsupported UPDATE form: %.120s' % (path, statement))

        table, set_clause, where_clause = match.groups()

        sets = {column: _sql_literal(value)
                for column, value in SET_PAIR_RE.findall(set_clause)}

        # WHERE is parsed best-effort: an unsupported form (LIKE etc.)
        # yields where = None. Callers MUST treat (consumed SET column +
        # where None) as a ConservationError; updates whose SET columns
        # are not consumed may ignore the WHERE entirely.
        where = {}
        for condition in re.split(r'\bAND\b', where_clause,
                                  flags=re.IGNORECASE):
            condition = condition.strip()

            eq_match = WHERE_EQ_RE.match(condition)
            in_match = WHERE_IN_RE.match(condition)

            if eq_match:
                where[eq_match.group(1)] = [_sql_literal(eq_match.group(2))]
            elif in_match:
                values = [_sql_literal(token) for token
                          in in_match.group(2).replace('"', "'").split(',')]
                where[in_match.group(1)] = values
            else:
                where = None
                break

        updates.append({'table': table, 'sets': sets, 'where': where,
                        'source': str(path)})

    return updates


def collect_module_sql(server_root: Path, tables) -> tuple:
    """Gather INSERT rows and UPDATE statements for `tables` from every
    enabled module SQL file.

    Returns (inserts: {table: [rows]}, updates: [update dicts]).
    UPDATE parsing failures only matter for consumed tables - files
    that contain no statements touching `tables` are skipped wholesale.
    """
    inserts = defaultdict(list)
    updates = []

    for path in enabled_module_sql_files(server_root):
        text = path.read_text(encoding='utf-8', errors='replace')

        touched = [table for table in tables
                   if re.search(r"\b%s\b" % table, text)]
        if not touched:
            continue

        for table in touched:
            inserts[table].extend(parse_sql_rows_checked(path, table))

        updates.extend(parse_module_updates(path, set(tables)))

    return inserts, updates


def split_values(raw: str) -> list:
    """Split a VALUES(...) body into python values.

    Handles single-quoted strings (with backslash and '' escapes),
    NULL, integers, floats and 0x... hex blobs (kept as strings).
    """
    values = []
    current = []
    in_string = False
    i, length = 0, len(raw)

    def push():
        token = ''.join(current).strip()
        if token.upper() == 'NULL':
            values.append(None)
        elif re.fullmatch(r'-?\d+', token):
            values.append(int(token))
        elif re.fullmatch(r'-?\d*\.\d+', token):
            values.append(float(token))
        else:
            values.append(token)
        current.clear()

    while i < length:
        char = raw[i]

        if in_string:
            if char == '\\' and i + 1 < length:
                current.append(raw[i + 1])
                i += 2
                continue
            if char == "'":
                if i + 1 < length and raw[i + 1] == "'":
                    current.append("'")
                    i += 2
                    continue
                in_string = False
                values.append(''.join(current))
                current.clear()
                # skip to next comma
                while i + 1 < length and raw[i + 1] != ',':
                    i += 1
                i += 2
                continue
            current.append(char)
            i += 1
            continue

        if char == "'":
            in_string = True
            current = []
            i += 1
            continue
        if char == ',':
            push()
            i += 1
            continue

        current.append(char)
        i += 1

    if current or raw.strip().endswith(','):
        push()

    return values


def parse_sql_rows(path: Path, table: str):
    """Yield value tuples for every INSERT into `table` in the file."""
    with path.open(encoding='utf-8', errors='replace') as handle:
        for line in handle:
            match = INSERT_RE.match(line.strip())
            if match and match.group(1) == table:
                yield split_values(match.group(2))


def parse_zone_ids(zone_h: Path) -> dict:
    """Parse the ZONEID enum from src/map/zone.h -> { 'NAME': id }."""
    zones = {}
    pattern = re.compile(r'^\s*ZONE_(\w+)\s*=\s*(\d+)\s*,')

    with zone_h.open(encoding='utf-8', errors='replace') as handle:
        for line in handle:
            match = pattern.match(line)
            if match:
                zones[match.group(1)] = int(match.group(2))

    return zones


# ---------------------------------------------------------------------
# Server data model
# ---------------------------------------------------------------------

class ServerData:
    """All tables needed for the stat calculation, loaded from a checkout.

    Reads the base sql/ dumps AND any enabled module SQL
    (modules/init.txt): Phoenix ships e.g. all Dynamis spawns in
    modules/phoenix/dynamis/sql/dyna_spawn.sql. Module UPDATE
    statements touching columns we consume raise ConservationError;
    updates limited to columns we do not consume (spawntype etc.) are
    counted and ignored.
    """

    TABLES = (
        'mob_species_system', 'mob_pools', 'mob_groups',
        'mob_spawn_points', 'mob_pool_mods', 'mob_species_mods',
        'skill_ranks', 'traits',
    )

    CONSUMED_COLUMNS = {
        'mob_species_system': {'speciesID', 'VIT', 'AGI', 'DEF', 'family'},
        'mob_pools': {'poolid', 'speciesid', 'mJob', 'sJob', 'mobType'},
        'mob_groups': {'groupid', 'poolid', 'zoneid'},
        'mob_spawn_points': {'mobid', 'mobname', 'groupid',
                             'minLevel', 'maxLevel'},
        'mob_pool_mods': {'poolid', 'modid', 'value', 'is_mob_mod'},
        'mob_species_mods': {'speciesid', 'modid', 'value', 'is_mob_mod'},
        'skill_ranks': {'skillid', 'name', 'war', 'mnk', 'whm', 'blm',
                        'rdm', 'thf', 'pld', 'drk', 'bst', 'brd', 'rng',
                        'sam', 'nin', 'drg', 'smn', 'blu', 'cor', 'pup',
                        'dnc', 'sch', 'geo', 'run'},
        'traits': {'traitid', 'job', 'level', 'rank', 'modifier', 'value'},
    }

    def __init__(self, root: Path, include_modules: bool = True):
        self.root = Path(root)
        sql = self.root / 'sql'

        module_inserts, module_updates = ({}, [])
        if include_modules:
            module_inserts, module_updates = collect_module_sql(
                self.root, self.TABLES)

        self.ignored_updates = 0
        self.applied_updates = 0
        trait_updates = []

        for update in module_updates:
            touched = (set(update['sets'])
                       & self.CONSUMED_COLUMNS[update['table']])

            if not touched:
                self.ignored_updates += 1
                continue

            # traits and skill_ranks are the consumed tables Phoenix's
            # enabled modules UPDATE today; both applied row-wise below.
            if (update['table'] in ('traits', 'skill_ranks')
                    and update['where'] is not None):
                trait_updates.append(update)
                continue

            raise ConservationError(
                '%s: module UPDATE on %s touches consumed columns %s '
                '- extractor must be taught to apply it'
                % (update['source'], update['table'], sorted(touched)))

        def rows(table):
            result = parse_sql_rows_checked(sql / (table + '.sql'), table)
            result.extend(module_inserts.get(table, []))
            return result

        # speciesID -> dict of ranks
        self.species = {}
        for row in rows('mob_species_system'):
            self.species[row[0]] = {
                'family': row[3],
                'vit_rank': row[11],
                'agi_rank': row[12],
                'def_rank': row[17],
            }

        # poolid -> pool info
        self.pools = {}
        for row in rows('mob_pools'):
            self.pools[row[0]] = {
                'name': row[1],
                'species': row[3],
                'mjob': row[5],
                'sjob': row[6],
                'mob_type': row[14],
            }

        # (zoneid, groupid) -> poolid
        self.groups = {}
        for row in rows('mob_groups'):
            self.groups[(row[2], row[0])] = row[1]

        # spawn point rows (kept raw for conservation accounting)
        self.spawn_rows = []
        for row in rows('mob_spawn_points'):
            mobid, _, mobname, _, groupid, min_lvl, max_lvl = row[:7]
            self.spawn_rows.append({
                'zone': (mobid >> 12) & 0xFFF,
                'name': mobname,
                'group': groupid,
                'min_level': min_lvl,
                'max_level': max_lvl,
            })

        # flat DEF/EVA mods
        self.pool_mods = defaultdict(lambda: {'def': 0, 'eva': 0})
        for row in rows('mob_pool_mods'):
            poolid, modid, value, is_mob_mod = row[:4]
            if not is_mob_mod:
                if modid == MOD_DEF:
                    self.pool_mods[poolid]['def'] += value
                elif modid == MOD_EVA:
                    self.pool_mods[poolid]['eva'] += value

        self.species_mods = defaultdict(lambda: {'def': 0, 'eva': 0})
        for row in rows('mob_species_mods'):
            speciesid, modid, value, is_mob_mod = row[:4]
            if not is_mob_mod:
                if modid == MOD_DEF:
                    self.species_mods[speciesid]['def'] += value
                elif modid == MOD_EVA:
                    self.species_mods[speciesid]['eva'] += value

        # per-job evasion skill rank (skill_ranks row 'evasion';
        # job columns follow the JOBTYPE enum order, WAR..RUN).
        # Loaded as named rows so module UPDATEs (pre_2014_skill_ranks)
        # can be applied row-wise before the evasion row is read.
        skill_rank_columns = [
            'skillid', 'name', 'war', 'mnk', 'whm', 'blm', 'rdm', 'thf',
            'pld', 'drk', 'bst', 'brd', 'rng', 'sam', 'nin', 'drg',
            'smn', 'blu', 'cor', 'pup', 'dnc', 'sch', 'geo', 'run',
        ]

        skill_rank_rows = []
        for row in rows('skill_ranks'):
            skill_rank_rows.append(
                dict(zip(skill_rank_columns, row[:len(skill_rank_columns)])))

        for update in trait_updates:
            if update['table'] != 'skill_ranks':
                continue
            for rank_row in skill_rank_rows:
                if all(rank_row.get(column) in values
                       for column, values in update['where'].items()):
                    for column, value in update['sets'].items():
                        if column in rank_row:
                            rank_row[column] = value
                    self.applied_updates += 1

        self.evasion_rank = {0: 11}  # NON: worse than every real rank
        for rank_row in skill_rank_rows:
            if str(rank_row['name']).lower() == 'evasion':
                for job in range(1, 23):
                    self.evasion_rank[job] = rank_row[skill_rank_columns[1 + job]]

        # traits: load as named rows, apply module UPDATEs row-wise,
        # then index job -> traitid -> [(level, rank, modifier, value)]
        self.traits = defaultdict(lambda: defaultdict(list))
        if (sql / 'traits.sql').exists():
            trait_rows = []
            for row in rows('traits'):
                trait_rows.append({
                    'traitid': row[0], 'name': row[1], 'job': row[2],
                    'level': row[3], 'rank': row[4], 'modifier': row[5],
                    'value': row[6],
                })

            for update in trait_updates:
                if update['table'] != 'traits':
                    continue
                for trait_row in trait_rows:
                    if all(trait_row.get(column) in values
                           for column, values in update['where'].items()):
                        for column, value in update['sets'].items():
                            if column in trait_row:
                                trait_row[column] = value
                        self.applied_updates += 1

            for trait_row in trait_rows:
                if trait_row['modifier'] in (MOD_DEF, MOD_EVA):
                    self.traits[trait_row['job']][trait_row['traitid']].append(
                        (trait_row['level'], trait_row['rank'],
                         trait_row['modifier'], trait_row['value']))

        # subjob zone ids from zone.h
        zone_ids = parse_zone_ids(self.root / 'src' / 'map' / 'zone.h')
        self.subjob_zones = {
            zone_ids[name] for name in SUBJOB_ZONE_NAMES if name in zone_ids
        }

    # -----------------------------------------------------------------

    def trait_mods(self, mjob: int, mlvl: int, sjob: int, slvl: int) -> dict:
        """DEF/EVA from job traits: per traitid, the highest qualifying
        rank across both jobs counts once (battleutils::AddTraits)."""
        chosen = {}  # traitid -> (rank, [(modifier, value)])

        for job, level in ((mjob, mlvl), (sjob, slvl)):
            for traitid, rows in self.traits.get(job, {}).items():
                qualifying = [r for r in rows if 0 < r[0] <= level]
                if not qualifying:
                    continue

                best_rank = max(r[1] for r in qualifying)
                mods = [(r[2], r[3]) for r in qualifying if r[1] == best_rank]

                if traitid not in chosen or chosen[traitid][0] < best_rank:
                    chosen[traitid] = (best_rank, mods)

        result = {'def': 0, 'eva': 0}
        for _, mods in chosen.values():
            for modifier, value in mods:
                if modifier == MOD_DEF:
                    result['def'] += value
                elif modifier == MOD_EVA:
                    result['eva'] += value

        return result

    def stats_at_level(self, zone: int, poolid: int, lvl: int) -> dict:
        """Replicates CalculateMobStats + DEF()/EVA() for one level."""
        pool = self.pools[poolid]
        spec = self.species[pool['species']]
        mjob, sjob = pool['mjob'], pool['sjob']
        slvl = lvl  # map.INCLUDE_MOB_SJ default: sub level == main level

        def stat(family_rank: int, grade_index: int) -> int:
            family = base_to_rank(family_rank, lvl)
            main = base_to_rank(JOB_GRADES[mjob][grade_index], lvl)
            sub_full = base_to_rank(JOB_GRADES[sjob][grade_index], slvl)

            if zone in self.subjob_zones and slvl < 50:
                sub = sub_job_stats(JOB_GRADES[sjob][grade_index],
                                    slvl, sub_full)
            else:
                sub = sub_full // 2

            return family + main + sub

        vit = stat(spec['vit_rank'], GRADE_VIT)
        agi = stat(spec['agi_rank'], GRADE_AGI)

        traits = self.trait_mods(mjob, lvl, sjob, slvl)
        pool_mods = self.pool_mods[poolid]
        species_mods = self.species_mods[pool['species']]

        defense = max(1, 8 + vit // 2 + base_def_eva(spec['def_rank'], lvl)
                      + traits['def'] + pool_mods['def'] + species_mods['def'])

        eva_rank = eva_rank_from_skill_ranks(
            self.evasion_rank.get(mjob, 11),
            self.evasion_rank.get(sjob, 11) if sjob else
            self.evasion_rank.get(mjob, 11))
        evasion = max(1, base_def_eva(eva_rank, lvl) + agi // 2
                      + traits['eva'] + pool_mods['eva'] + species_mods['eva'])

        return {'vit': vit, 'agi': agi, 'def': defense, 'eva': evasion}


# ---------------------------------------------------------------------
# Extraction + Lua emission
# ---------------------------------------------------------------------


def extract(data: ServerData, zones=None) -> tuple:
    """zone -> display name -> [entry, ...], min/max stats per entry.

    Returns (output, accounting). Every spawn row is either emitted or
    counted under an explicit skip reason; any imbalance raises
    ConservationError so silent row loss is impossible.
    """
    output = defaultdict(dict)
    seen = set()

    accounting = {
        'total': len(data.spawn_rows),
        'emitted': 0,
        'duplicate_spawn_point': 0,
        'zone_filtered': 0,
        'zero_level': 0,
        'missing_group': 0,
        'missing_pool': 0,
        'missing_species': 0,
    }

    def sort_key(row):
        return (row['zone'], row['name'], row['group'],
                row['min_level'], row['max_level'])

    for row in sorted(data.spawn_rows, key=sort_key):
        zone = row['zone']

        if zones and zone not in zones:
            accounting['zone_filtered'] += 1
            continue

        if row['min_level'] == 0 and row['max_level'] == 0:
            accounting['zero_level'] += 1
            continue

        poolid = data.groups.get((zone, row['group']))
        if poolid is None:
            accounting['missing_group'] += 1
            continue

        pool = data.pools.get(poolid)
        if pool is None:
            accounting['missing_pool'] += 1
            continue

        if pool['species'] not in data.species:
            accounting['missing_species'] += 1
            continue

        key = (zone, row['name'], row['min_level'], row['max_level'], poolid)
        if key in seen:
            accounting['duplicate_spawn_point'] += 1
            continue
        seen.add(key)

        accounting['emitted'] += 1

        entry = {
            'group': row['group'],
            'pool': poolid,
            'min_level': row['min_level'],
            'max_level': row['max_level'],
            'mjob': JOB_NAMES[pool['mjob']],
            'sjob': JOB_NAMES[pool['sjob']],
            'family': data.species[pool['species']]['family'],
            'nm': bool(pool['mob_type'] & 0x02),
            'min': data.stats_at_level(zone, poolid, row['min_level']),
            'max': data.stats_at_level(zone, poolid, row['max_level']),
        }
        output[zone].setdefault(row['name'].replace('_', ' '),
                                []).append(entry)

    accounted = sum(value for key, value in accounting.items()
                    if key != 'total')
    if accounted != accounting['total']:
        raise ConservationError(
            'spawn rows: %d total but only %d accounted for (%s)'
            % (accounting['total'], accounted, accounting))

    return output, accounting


def lua_string(value: str) -> str:
    return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'") + "'"


def emit_lua(mobs: dict, source: str) -> str:
    lines = [
        '-- Generated by Whetstone tools/extract_mobs.py - DO NOT EDIT',
        '-- Source: ' + source,
        '-- zone ID -> mob name -> { level range + stats at min/max level }',
        'return {',
    ]

    for zone in sorted(mobs):
        lines.append('    [%d] = {' % zone)

        for name in sorted(mobs[zone]):
            lines.append('        [%s] = {' % lua_string(name))

            for e in mobs[zone][name]:
                stats = []
                for which in ('min', 'max'):
                    s = e[which]
                    stats.append(
                        '%s = { vit = %d, agi = %d, def = %d, eva = %d }'
                        % (which, s['vit'], s['agi'], s['def'], s['eva']))

                lines.append(
                    '            { min_level = %d, max_level = %d, '
                    'mjob = %s, sjob = %s, family = %s, nm = %s, '
                    'group = %d, %s, %s },'
                    % (e['min_level'], e['max_level'],
                       lua_string(e['mjob']), lua_string(e['sjob']),
                       lua_string(e['family']),
                       'true' if e['nm'] else 'false',
                       e['group'], stats[0], stats[1]))

            lines.append('        },')

        lines.append('    },')

    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--server', required=True,
                        help='path to a Phoenix/LSB server checkout')
    parser.add_argument('--out', required=True, help='output Lua file')
    parser.add_argument('--zone', action='append', type=int, default=None,
                        help='restrict to zone id (repeatable)')
    parser.add_argument('--source-label', default=None,
                        help='provenance line for the generated header')
    args = parser.parse_args(argv)

    data = ServerData(Path(args.server))
    mobs, accounting = extract(data, set(args.zone) if args.zone else None)

    label = args.source_label or str(args.server)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(emit_lua(mobs, label), encoding='utf-8')

    total = sum(len(entries) for zone in mobs.values()
                for entries in zone.values())
    print('wrote %s: %d zones, %d mob entries' % (out_path, len(mobs), total))
    print('conservation: %s; %d module updates ignored (non-consumed columns)'
          % (', '.join('%s=%d' % kv for kv in sorted(accounting.items())),
             data.ignored_updates))
    return 0


if __name__ == '__main__':
    sys.exit(main())
