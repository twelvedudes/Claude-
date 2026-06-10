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
    """All tables needed for the stat calculation, loaded from a checkout."""

    def __init__(self, root: Path):
        self.root = Path(root)
        sql = self.root / 'sql'

        # speciesID -> dict of ranks
        self.species = {}
        for row in parse_sql_rows(sql / 'mob_species_system.sql',
                                  'mob_species_system'):
            self.species[row[0]] = {
                'family': row[3],
                'vit_rank': row[11],
                'agi_rank': row[12],
                'def_rank': row[17],
            }

        # poolid -> pool info
        self.pools = {}
        for row in parse_sql_rows(sql / 'mob_pools.sql', 'mob_pools'):
            self.pools[row[0]] = {
                'name': row[1],
                'species': row[3],
                'mjob': row[5],
                'sjob': row[6],
                'mob_type': row[14],
            }

        # (zoneid, groupid) -> poolid
        self.groups = {}
        for row in parse_sql_rows(sql / 'mob_groups.sql', 'mob_groups'):
            self.groups[(row[2], row[0])] = row[1]

        # spawn points: (zone, name, groupid) -> (minLevel, maxLevel)
        self.spawns = {}
        for row in parse_sql_rows(sql / 'mob_spawn_points.sql',
                                  'mob_spawn_points'):
            mobid, _, mobname, _, groupid, min_lvl, max_lvl = row[:7]
            zone = (mobid >> 12) & 0xFFF
            self.spawns[(zone, mobname, groupid)] = (min_lvl, max_lvl)

        # flat DEF/EVA mods
        self.pool_mods = defaultdict(lambda: {'def': 0, 'eva': 0})
        for row in parse_sql_rows(sql / 'mob_pool_mods.sql', 'mob_pool_mods'):
            poolid, modid, value, is_mob_mod = row[:4]
            if not is_mob_mod:
                if modid == MOD_DEF:
                    self.pool_mods[poolid]['def'] += value
                elif modid == MOD_EVA:
                    self.pool_mods[poolid]['eva'] += value

        self.species_mods = defaultdict(lambda: {'def': 0, 'eva': 0})
        for row in parse_sql_rows(sql / 'mob_species_mods.sql',
                                  'mob_species_mods'):
            speciesid, modid, value, is_mob_mod = row[:4]
            if not is_mob_mod:
                if modid == MOD_DEF:
                    self.species_mods[speciesid]['def'] += value
                elif modid == MOD_EVA:
                    self.species_mods[speciesid]['eva'] += value

        # per-job evasion skill rank (skill_ranks row 'evasion';
        # job columns follow the JOBTYPE enum order, WAR..RUN)
        self.evasion_rank = {0: 11}  # NON: worse than every real rank
        for row in parse_sql_rows(sql / 'skill_ranks.sql', 'skill_ranks'):
            if str(row[1]).lower() == 'evasion':
                for job in range(1, min(23, len(row) - 1)):
                    self.evasion_rank[job] = row[1 + job]

        # traits: job -> traitid -> [(level, rank, modifier, value)]
        self.traits = defaultdict(lambda: defaultdict(list))
        traits_path = sql / 'traits.sql'
        if traits_path.exists():
            for row in parse_sql_rows(traits_path, 'traits'):
                traitid, _, job, level, rank, modifier, value = row[:7]
                if modifier in (MOD_DEF, MOD_EVA):
                    self.traits[job][traitid].append(
                        (level, rank, modifier, value))

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


def extract(data: ServerData, zones=None) -> dict:
    """zone -> display name -> [entry, ...], min/max stats per entry."""
    output = defaultdict(dict)
    seen = set()

    for (zone, mobname, groupid), (min_lvl, max_lvl) in sorted(
            data.spawns.items()):
        if zones and zone not in zones:
            continue
        if min_lvl == 0 and max_lvl == 0:
            continue

        poolid = data.groups.get((zone, groupid))
        if poolid is None or poolid not in data.pools:
            continue
        pool = data.pools[poolid]
        if pool['species'] not in data.species:
            continue

        key = (zone, mobname, min_lvl, max_lvl, poolid)
        if key in seen:
            continue
        seen.add(key)

        display = mobname.replace('_', ' ')
        entry = {
            'group': groupid,
            'pool': poolid,
            'min_level': min_lvl,
            'max_level': max_lvl,
            'mjob': JOB_NAMES[pool['mjob']],
            'sjob': JOB_NAMES[pool['sjob']],
            'family': data.species[pool['species']]['family'],
            'nm': bool(pool['mob_type'] & 0x02),
            'min': data.stats_at_level(zone, poolid, min_lvl),
            'max': data.stats_at_level(zone, poolid, max_lvl),
        }
        output[zone].setdefault(display, []).append(entry)

    return output


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
    mobs = extract(data, set(args.zone) if args.zone else None)

    label = args.source_label or str(args.server)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(emit_lua(mobs, label), encoding='utf-8')

    total = sum(len(entries) for zone in mobs.values()
                for entries in zone.values())
    print('wrote %s: %d zones, %d mob entries'
          % (out_path, len(mobs), total))
    return 0


if __name__ == '__main__':
    sys.exit(main())
