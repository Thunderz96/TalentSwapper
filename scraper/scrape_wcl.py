#!/usr/bin/env python3
"""
scrape_wcl.py  —  Fetch top talent builds from WarcraftLogs API v2
Outputs TalentSwapper_Recommended.lua for the TalentSwapper addon.

Setup:
  1. Create a WarcraftLogs API client at https://www.warcraftlogs.com/api/clients/
  2. Copy your Client ID and Client Secret
  3. Set environment variables (or create a .env file in this folder):
       WCL_CLIENT_ID=your_client_id
       WCL_CLIENT_SECRET=your_client_secret
  4. pip install -r requirements.txt
  5. python scrape_wcl.py --spec "Beast Mastery" --class "Hunter"

Usage:
  python scrape_wcl.py --class Hunter --spec "Beast Mastery"
  python scrape_wcl.py --class Hunter --spec "Beast Mastery" --zone 42 --difficulty 5
  python scrape_wcl.py --config builds.json   (batch mode)
"""

import argparse
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path

import requests

# ── Constants ─────────────────────────────────────────────────

TOKEN_URL = "https://www.warcraftlogs.com/oauth/token"
API_URL = "https://www.warcraftlogs.com/api/v2/client"

# Midnight raid/dungeon zone IDs — update these as new content releases
# These are looked up dynamically if not provided
DEFAULT_DIFFICULTY = 5  # 5 = Mythic raid, 4 = Heroic, 3 = Normal
TOP_N_REPORTS = 15      # How many top reports to pull per encounter
TOP_N_BUILDS = 3        # How many top builds to output per encounter
MAX_RETRIES = 3
RATE_LIMIT_DELAY = 1.5  # seconds between API calls

SCRIPT_DIR = Path(__file__).parent
ADDON_DIR = SCRIPT_DIR.parent
OUTPUT_FILE = ADDON_DIR / "TalentSwapper_Recommended.lua"
ENV_FILE = SCRIPT_DIR / ".env"


# ── Auth ──────────────────────────────────────────────────────

def load_env():
    """Load .env file if it exists."""
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, val = line.split("=", 1)
                os.environ.setdefault(key.strip(), val.strip())


def get_access_token(client_id: str, client_secret: str) -> str:
    """Get OAuth2 bearer token via client credentials flow."""
    resp = requests.post(TOKEN_URL, data={
        "grant_type": "client_credentials",
    }, auth=(client_id, client_secret), timeout=15)
    resp.raise_for_status()
    token = resp.json().get("access_token")
    if not token:
        print("ERROR: No access_token in response.")
        sys.exit(1)
    return token


# ── GraphQL helpers ───────────────────────────────────────────

def gql_query(token: str, query: str, variables: dict | None = None) -> dict:
    """Execute a GraphQL query against the WCL v2 API."""
    headers = {"Authorization": f"Bearer {token}"}
    payload = {"query": query}
    if variables:
        payload["variables"] = variables

    for attempt in range(MAX_RETRIES):
        try:
            resp = requests.post(API_URL, json=payload, headers=headers, timeout=30)
            if resp.status_code == 429:
                wait = int(resp.headers.get("Retry-After", 5))
                print(f"  Rate limited, waiting {wait}s...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            data = resp.json()
            if "errors" in data:
                print(f"  GraphQL errors: {data['errors']}")
                return {}
            return data.get("data", {})
        except requests.RequestException as e:
            print(f"  Request error (attempt {attempt+1}): {e}")
            time.sleep(2)
    return {}


# ── Zone / Encounter discovery ────────────────────────────────

def get_current_zones(token: str) -> list[dict]:
    """Fetch current expansion zones (raids + dungeons)."""
    query = """
    {
        worldData {
            expansions {
                id
                name
                zones {
                    id
                    name
                    encounters {
                        id
                        name
                    }
                }
            }
        }
    }
    """
    data = gql_query(token, query)
    expansions = data.get("worldData", {}).get("expansions", [])
    if not expansions:
        return []
    # Pick the expansion with the highest ID (newest)
    latest = max(expansions, key=lambda e: e.get("id", 0))
    print(f"Expansion: {latest['name']} (ID: {latest['id']})")
    return latest.get("zones", [])


def get_zone_encounters(token: str, zone_id: int) -> list[dict]:
    """Fetch encounters for a specific zone."""
    query = """
    query ($id: Int!) {
        worldData {
            zone(id: $id) {
                id
                name
                encounters {
                    id
                    name
                }
            }
        }
    }
    """
    data = gql_query(token, query, {"id": zone_id})
    zone = data.get("worldData", {}).get("zone")
    if not zone:
        return []
    print(f"Zone: {zone['name']} ({len(zone['encounters'])} encounters)")
    return zone["encounters"]


# ── Rankings + Talent data ────────────────────────────────────

def get_encounter_rankings(
    token: str,
    encounter_id: int,
    class_name: str,
    spec_name: str,
    difficulty: int = DEFAULT_DIFFICULTY,
    metric: str = "dps",
    page: int = 1,
) -> list[dict]:
    """Fetch top character rankings for an encounter/spec."""
    query = """
    query ($encounterID: Int!, $className: String!, $specName: String!,
           $difficulty: Int!, $metric: CharacterRankingMetricType, $page: Int!) {
        worldData {
            encounter(id: $encounterID) {
                name
                characterRankings(
                    className: $className
                    specName: $specName
                    difficulty: $difficulty
                    metric: $metric
                    page: $page
                )
            }
        }
    }
    """
    data = gql_query(token, query, {
        "encounterID": encounter_id,
        "className": class_name,
        "specName": spec_name,
        "difficulty": difficulty,
        "metric": metric,
        "page": page,
    })
    encounter = data.get("worldData", {}).get("encounter")
    if not encounter:
        return []
    rankings_data = encounter.get("characterRankings")
    if not rankings_data:
        return []
    # characterRankings returns a JSON object with "rankings" array
    if isinstance(rankings_data, dict):
        return rankings_data.get("rankings", [])
    return []


_debug_dumped = False  # dump first successful response for debugging


def get_report_combatant_info(
    token: str,
    report_code: str,
    fight_id: int,
    encounter_id: int,
) -> list[dict]:
    """Fetch combatant talent info from a report's fight summary."""
    global _debug_dumped
    query = """
    query ($code: String!, $encounterID: Int!, $fightIDs: [Int!]) {
        reportData {
            report(code: $code) {
                table(dataType: Summary, encounterID: $encounterID, fightIDs: $fightIDs)
                masterData {
                    actors(type: "Player") {
                        id
                        name
                        type
                        subType
                    }
                }
            }
        }
    }
    """
    data = gql_query(token, query, {
        "code": report_code,
        "encounterID": encounter_id,
        "fightIDs": [fight_id],
    })
    report = data.get("reportData", {}).get("report")
    if not report:
        return []

    table_data = report.get("table", {})

    # Debug: dump the first successful table response so we can inspect structure
    if not _debug_dumped and table_data:
        _debug_dumped = True
        debug_path = SCRIPT_DIR / "debug_response.json"
        debug_path.write_text(json.dumps(table_data, indent=2, default=str), encoding="utf-8")
        print(f"\n  [DEBUG] Wrote first table response to {debug_path}")

    if isinstance(table_data, dict):
        tdata = table_data.get("data", {})
        if not isinstance(tdata, dict):
            return []

        # Try composition array
        composition = tdata.get("composition", [])
        if composition:
            return composition

        # Try playerDetails (grouped by role)
        players = tdata.get("playerDetails", {})
        if isinstance(players, dict):
            all_players = []
            for role_list in players.values():
                if isinstance(role_list, list):
                    all_players.extend(role_list)
            return all_players

        # Try combatantInfo directly
        combatant_info = tdata.get("combatantInfo", [])
        if combatant_info:
            return combatant_info

    return []


def extract_talent_string_from_combatant(combatant: dict) -> str | None:
    """Extract a usable talent import string from combatant data.

    Searches through all known field names the WCL API might use.
    """
    # Check top-level fields
    for key in ("talentImport", "talentCode", "talentExport", "talentString"):
        if combatant.get(key):
            return combatant[key]

    # Check nested combatantInfo
    info = combatant.get("combatantInfo", {})
    if isinstance(info, dict):
        for key in ("talentImport", "talentCode", "talentExport", "talentString"):
            if info.get(key):
                return info[key]

    # Check nested specs/talents structures
    specs = combatant.get("specs", [])
    if isinstance(specs, list):
        for spec in specs:
            if isinstance(spec, dict):
                for key in ("talentImport", "talentCode", "talentExport"):
                    if spec.get(key):
                        return spec[key]

    return None


# ── Build aggregation ─────────────────────────────────────────

def fetch_top_builds(
    token: str,
    encounter_id: int,
    encounter_name: str,
    class_name: str,
    spec_name: str,
    difficulty: int = DEFAULT_DIFFICULTY,
    top_n_reports: int = TOP_N_REPORTS,
    top_n_builds: int = TOP_N_BUILDS,
) -> list[dict]:
    """Fetch and aggregate the most popular talent builds for an encounter."""
    print(f"\n  Encounter: {encounter_name} (ID: {encounter_id})")
    print(f"  Fetching top {top_n_reports} rankings for {spec_name} {class_name}...")

    rankings = get_encounter_rankings(
        token, encounter_id, class_name, spec_name, difficulty
    )

    if not rankings:
        print("  No rankings found.")
        return []

    # Limit to top N
    rankings = rankings[:top_n_reports]
    print(f"  Got {len(rankings)} rankings. Pulling talent data from reports...")

    talent_strings = []
    for rank in rankings:
        report_code = rank.get("report", {}).get("code") if isinstance(rank.get("report"), dict) else None
        fight_id = rank.get("report", {}).get("fightID") if isinstance(rank.get("report"), dict) else None
        player_name = rank.get("name", "Unknown")

        if not report_code or not fight_id:
            continue

        time.sleep(RATE_LIMIT_DELAY)

        combatants = get_report_combatant_info(
            token, report_code, fight_id, encounter_id
        )

        # Find the ranked player in combatants
        for combatant in combatants:
            cname = combatant.get("name", "")
            if cname.lower() == player_name.lower():
                ts = extract_talent_string_from_combatant(combatant)
                if ts:
                    talent_strings.append(ts)
                break

        sys.stdout.write(f"\r  Processed {len(talent_strings)}/{len(rankings)} reports...")
        sys.stdout.flush()

    print()

    if not talent_strings:
        print("  Could not extract talent strings from reports.")
        print("  (The WCL API may not expose import strings for this content.)")
        return []

    # Count and rank builds
    counter = Counter(talent_strings)
    top_builds = counter.most_common(top_n_builds)

    results = []
    for i, (talent_str, count) in enumerate(top_builds, 1):
        pct = count / len(talent_strings) * 100
        results.append({
            "rank": i,
            "talentString": talent_str,
            "popularity": round(pct, 1),
            "sampleSize": count,
        })
        print(f"  #{i}: {pct:.1f}% ({count}/{len(talent_strings)} players)")

    return results


# ── Lua output ────────────────────────────────────────────────

def escape_lua_string(s: str) -> str:
    """Escape a string for Lua."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write_lua_output(all_data: list[dict], class_name: str, spec_name: str):
    """Write the recommended builds to a Lua data file."""
    lines = [
        "-- ============================================================",
        "-- TalentSwapper_Recommended.lua  —  Auto-generated",
        "-- DO NOT EDIT — regenerate with: python scraper/scrape_wcl.py",
        "-- ============================================================",
        "",
        "TalentSwapperRecommended = TalentSwapperRecommended or {}",
        "",
        f'TalentSwapperRecommended.class = "{escape_lua_string(class_name)}"',
        f'TalentSwapperRecommended.spec = "{escape_lua_string(spec_name)}"',
        f'TalentSwapperRecommended.generatedAt = "{time.strftime("%Y-%m-%d %H:%M:%S")}"',
        "",
        "TalentSwapperRecommended.encounters = {",
    ]

    for entry in all_data:
        enc_name = escape_lua_string(entry["encounterName"])
        lines.append(f'    ["{enc_name}"] = {{')
        lines.append(f'        encounterID = {entry["encounterID"]},')
        lines.append(f'        zone = "{escape_lua_string(entry.get("zoneName", ""))}",')
        lines.append(f'        difficulty = {entry.get("difficulty", DEFAULT_DIFFICULTY)},')
        lines.append(f'        builds = {{')

        for build in entry.get("builds", []):
            ts = escape_lua_string(build["talentString"])
            lines.append(f'            {{')
            lines.append(f'                rank = {build["rank"]},')
            lines.append(f'                talentString = "{ts}",')
            lines.append(f'                popularity = {build["popularity"]},')
            lines.append(f'                sampleSize = {build["sampleSize"]},')
            lines.append(f'            }},')

        lines.append(f'        }},')
        lines.append(f'    }},')

    lines.append("}")
    lines.append("")

    OUTPUT_FILE.write_text("\n".join(lines), encoding="utf-8")
    print(f"\nWrote {OUTPUT_FILE}")


# ── Main ──────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Fetch top WarcraftLogs talent builds for TalentSwapper"
    )
    parser.add_argument("--class", dest="class_name", required=True,
                        help='WoW class name (e.g. "Hunter", "Mage")')
    parser.add_argument("--spec", dest="spec_name", required=True,
                        help='Spec name (e.g. "Beast Mastery", "Frost")')
    parser.add_argument("--zone", type=int, default=None,
                        help="WCL zone ID (auto-detected if omitted)")
    parser.add_argument("--difficulty", type=int, default=DEFAULT_DIFFICULTY,
                        help=f"Difficulty (3=Normal, 4=Heroic, 5=Mythic, default={DEFAULT_DIFFICULTY})")
    parser.add_argument("--metric", default="dps",
                        help='Ranking metric (dps, hps, bossdps, default=dps)')
    parser.add_argument("--top-reports", type=int, default=TOP_N_REPORTS,
                        help=f"Number of top reports to sample (default={TOP_N_REPORTS})")
    parser.add_argument("--top-builds", type=int, default=TOP_N_BUILDS,
                        help=f"Number of top builds to output per encounter (default={TOP_N_BUILDS})")
    parser.add_argument("--encounters", type=str, default=None,
                        help='Comma-separated encounter IDs to fetch (default: all in zone)')
    parser.add_argument("--config", type=str, default=None,
                        help="Path to a JSON config file for batch mode")
    args = parser.parse_args()

    load_env()
    client_id = os.environ.get("WCL_CLIENT_ID", "")
    client_secret = os.environ.get("WCL_CLIENT_SECRET", "")

    if not client_id or not client_secret:
        print("ERROR: Set WCL_CLIENT_ID and WCL_CLIENT_SECRET environment variables.")
        print("       Or create a .env file in the scraper/ folder:")
        print("         WCL_CLIENT_ID=your_id")
        print("         WCL_CLIENT_SECRET=your_secret")
        print()
        print("Get API credentials at: https://www.warcraftlogs.com/api/clients/")
        sys.exit(1)

    print("Authenticating with WarcraftLogs API...")
    token = get_access_token(client_id, client_secret)
    print("Authenticated!\n")

    # Determine encounters to process
    encounters = []
    zone_name = ""

    if args.zone:
        enc_list = get_zone_encounters(token, args.zone)
        zone_data = gql_query(token, """
            query ($id: Int!) { worldData { zone(id: $id) { name } } }
        """, {"id": args.zone})
        zone_name = zone_data.get("worldData", {}).get("zone", {}).get("name", "")
        encounters = enc_list
    else:
        # Auto-detect: get latest expansion zones
        zones = get_current_zones(token)
        if not zones:
            print("ERROR: Could not fetch zone data.")
            sys.exit(1)
        # Pick raid zones by default
        print("\nAvailable zones:")
        for z in zones:
            enc_count = len(z.get("encounters", []))
            print(f"  [{z['id']}] {z['name']} ({enc_count} encounters)")
        print()
        # Auto-select: prefer raid zones (skip Beta, Complete Raids, M+ zones)
        skip_keywords = ("beta", "complete raids", "mythic+")
        for z in zones:
            zname_lower = z["name"].lower()
            if any(kw in zname_lower for kw in skip_keywords):
                continue
            if z.get("encounters"):
                encounters = z["encounters"]
                zone_name = z["name"]
                print(f"Auto-selected zone: {zone_name} (ID: {z['id']})")
                break
        # Fallback: first zone with encounters
        if not encounters:
            for z in zones:
                if z.get("encounters"):
                    encounters = z["encounters"]
                    zone_name = z["name"]
                    print(f"Fallback zone: {zone_name} (ID: {z['id']})")
                    break

    if args.encounters:
        enc_ids = [int(x.strip()) for x in args.encounters.split(",")]
        encounters = [e for e in encounters if e["id"] in enc_ids]

    if not encounters:
        print("No encounters found.")
        sys.exit(1)

    print(f"\nFetching talent data for {args.spec_name} {args.class_name}")
    print(f"Zone: {zone_name} | Difficulty: {args.difficulty} | Metric: {args.metric}")
    print(f"Encounters: {len(encounters)} | Top reports: {args.top_reports}")
    print("=" * 60)

    all_data = []
    for enc in encounters:
        time.sleep(RATE_LIMIT_DELAY)
        builds = fetch_top_builds(
            token=token,
            encounter_id=enc["id"],
            encounter_name=enc["name"],
            class_name=args.class_name,
            spec_name=args.spec_name,
            difficulty=args.difficulty,
            top_n_reports=args.top_reports,
            top_n_builds=args.top_builds,
        )
        all_data.append({
            "encounterID": enc["id"],
            "encounterName": enc["name"],
            "zoneName": zone_name,
            "difficulty": args.difficulty,
            "builds": builds,
        })

    write_lua_output(all_data, args.class_name, args.spec_name)
    print("\nDone! Restart WoW or /reload to load recommended builds.")


if __name__ == "__main__":
    main()
