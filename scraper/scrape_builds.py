#!/usr/bin/env python3
"""
scrape_builds.py  --  Fetch recommended talent builds from Archon.gg
Outputs TalentSwapper_Recommended.lua for the TalentSwapper addon.

No API key needed -- Archon provides public talent build pages.

Usage:
  python scrape_builds.py --class warlock --spec demonology
  python scrape_builds.py --class warlock --spec demonology --content raid
  python scrape_builds.py --all
  python scrape_builds.py --all --content mythic-plus
"""

import argparse
import re
import sys
import time
from pathlib import Path

import requests

# ── Constants ─────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent
ADDON_DIR = SCRIPT_DIR.parent
OUTPUT_FILE = ADDON_DIR / "TalentSwapper_Recommended.lua"

# Archon URL patterns
ARCHON_RAID_URL = (
    "https://www.archon.gg/wow/builds/{spec}/{cls}/raid/talents/mythic/{boss}"
)
ARCHON_MPLUS_URL = (
    "https://www.archon.gg/wow/builds/{spec}/{cls}/mythic-plus/talents/10/{dungeon}/this-week"
)

# Current Midnight raid bosses (Archon slug -> (display name, raid instance))
RAID_BOSSES = {
    "all-bosses":      ("All Bosses",                 "All Raids"),
    "imperator":       ("Imperator Averzian",          "Voidspire"),
    "vorasius":        ("Vorasius",                    "Voidspire"),
    "salhadaar":       ("Fallen-King Salhadaar",       "Voidspire"),
    "vaelgor-ezzorak": ("Vaelgor & Ezzorak",          "Voidspire"),
    "vanguard":        ("Lightblinded Vanguard",       "Voidspire"),
    "crown":           ("Crown of the Cosmos",         "Voidspire"),
    "chimaerus":       ("Chimaerus, the Undreamt God", "Dreamrift"),
    "beloren":         ("Belo'ren, Child of Al'ar",    "March of the Queldalans"),
    "midnight-falls":  ("Midnight Falls",              "March of the Queldalans"),
}

# Current Midnight Season 1 M+ dungeons (Archon slug -> display name)
MPLUS_DUNGEONS = {
    "all-dungeons":      "All Dungeons",
    "algethar-academy":  "Algeth'ar Academy",
    "magisters":         "Magisters' Terrace",
    "maisara-caverns":   "Maisara Caverns",
    "nexus-point-xenas": "Nexus-Point Xenas",
    "pit-of-saron":      "Pit of Saron",
    "seat":              "Seat of the Triumvirate",
    "skyreach":          "Skyreach",
    "windrunner-spire":  "Windrunner Spire",
}

# All WoW classes and specs (Archon URL slugs)
ALL_SPECS = {
    "death-knight": ["blood", "frost", "unholy"],
    "demon-hunter": ["havoc", "vengeance"],
    "druid":        ["balance", "feral", "guardian", "restoration"],
    "evoker":       ["augmentation", "devastation", "preservation"],
    "hunter":       ["beast-mastery", "marksmanship", "survival"],
    "mage":         ["arcane", "fire", "frost"],
    "monk":         ["brewmaster", "mistweaver", "windwalker"],
    "paladin":      ["holy", "protection", "retribution"],
    "priest":       ["discipline", "holy", "shadow"],
    "rogue":        ["assassination", "outlaw", "subtlety"],
    "shaman":       ["elemental", "enhancement", "restoration"],
    "warlock":      ["affliction", "demonology", "destruction"],
    "warrior":      ["arms", "fury", "protection"],
}

RATE_LIMIT_DELAY = 1.5  # seconds between requests

# Talent import string pattern -- WoW talent export strings
# They start with 'C' followed by a specific pattern (e.g. CoQ, CkQ, CeQ)
# and contain only base64 chars. They are NOT images (GIF/PNG/JPEG).
TALENT_STRING_PATTERN = re.compile(
    r'C[a-z][A-Z][A-Za-z0-9+/]{50,200}={0,2}'
)

# Known non-talent base64 prefixes to filter out
IMAGE_PREFIXES = (
    "R0lGOD",   # GIF
    "iVBOR",    # PNG
    "VBORw",    # PNG variant
    "/9j/",     # JPEG
    "BDAY",     # other media
)

HEADERS = {
    "User-Agent": "TalentSwapper-Addon/1.0 (WoW Addon Helper)",
    "Accept": "text/html,application/xhtml+xml",
}


# ── Scraping ──────────────────────────────────────────────────

def is_talent_string(s: str) -> bool:
    """Filter out non-talent base64 strings (images, etc)."""
    for prefix in IMAGE_PREFIXES:
        if s.startswith(prefix):
            return False
    if len(s) < 50 or len(s) > 200:
        return False
    return True


def try_fetch_with_popularity(url: str) -> list[dict]:
    """Fetch talent builds and try to extract popularity data too."""
    try:
        resp = requests.get(url, headers=HEADERS, timeout=15)
        if resp.status_code != 200:
            return []
        text = resp.text
    except requests.RequestException:
        return []

    matches = TALENT_STRING_PATTERN.findall(text)
    matches = [m for m in matches if is_talent_string(m)]
    if not matches:
        return []

    seen = set()
    unique = []
    for m in matches:
        if m not in seen:
            seen.add(m)
            unique.append(m)

    pct_pattern = re.compile(r'(\d{1,3}\.\d)%')
    pcts = pct_pattern.findall(text)
    pcts = [float(p) for p in pcts if 1.0 <= float(p) <= 100.0]

    results = []
    for i, ts in enumerate(unique[:3], 1):
        pop = pcts[i - 1] if i - 1 < len(pcts) else 0
        results.append({
            "rank": i,
            "talentString": ts,
            "popularity": pop,
            "sampleSize": 0,
        })

    return results


def scrape_spec(cls: str, spec: str, content: str) -> list[dict]:
    """Scrape all encounters for a single class/spec. Returns list of encounter dicts."""
    all_data = []

    if content in ("raid", "all"):
        for slug, (display_name, raid_instance) in RAID_BOSSES.items():
            url = ARCHON_RAID_URL.format(spec=spec, cls=cls, boss=slug)
            time.sleep(RATE_LIMIT_DELAY)

            builds = try_fetch_with_popularity(url)
            status = f"{len(builds)} build(s)" if builds else "no data"
            print(f"    {display_name}: {status}")

            all_data.append({
                "name": display_name,
                "category": "Raid",
                "raid": raid_instance,
                "difficulty": "Mythic",
                "builds": builds,
            })

    if content in ("mythic-plus", "all"):
        for slug, display_name in MPLUS_DUNGEONS.items():
            url = ARCHON_MPLUS_URL.format(spec=spec, cls=cls, dungeon=slug)
            time.sleep(RATE_LIMIT_DELAY)

            builds = try_fetch_with_popularity(url)
            status = f"{len(builds)} build(s)" if builds else "no data"
            print(f"    {display_name}: {status}")

            all_data.append({
                "name": display_name,
                "category": "Mythic+",
                "difficulty": "M+",
                "builds": builds,
            })

    return all_data


# ── Lua output ────────────────────────────────────────────────

def escape_lua_string(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def format_display_name(slug: str) -> str:
    """Convert 'beast-mastery' -> 'Beast Mastery', 'death-knight' -> 'Death Knight'."""
    return slug.replace("-", " ").title()


def write_lua_output(all_specs_data: dict, timestamp: str):
    """
    all_specs_data = {
        "class_slug:spec_slug": {
            "class": "Death Knight",
            "spec": "Blood",
            "encounters": [ ... ]
        },
        ...
    }
    """
    lines = [
        "-- ============================================================",
        "-- TalentSwapper_Recommended.lua  --  Auto-generated from Archon.gg",
        "-- DO NOT EDIT -- regenerate with: python scraper/scrape_builds.py --all",
        "-- ============================================================",
        "",
        "TalentSwapperRecommended = TalentSwapperRecommended or {}",
        f'TalentSwapperRecommended.generatedAt = "{timestamp}"',
        "",
        "TalentSwapperRecommended.specs = {",
    ]

    for key, spec_data in sorted(all_specs_data.items()):
        cls_display = escape_lua_string(spec_data["class"])
        spec_display = escape_lua_string(spec_data["spec"])
        lines.append(f'    ["{escape_lua_string(key)}"] = {{')
        lines.append(f'        class = "{cls_display}",')
        lines.append(f'        spec = "{spec_display}",')
        lines.append(f'        encounters = {{')

        for entry in spec_data["encounters"]:
            enc_name = escape_lua_string(entry["name"])
            lines.append(f'            ["{enc_name}"] = {{')
            lines.append(f'                category = "{escape_lua_string(entry.get("category", "Raid"))}",')
            if entry.get("raid"):
                lines.append(f'                raid = "{escape_lua_string(entry["raid"])}",')
            lines.append(f'                difficulty = "{escape_lua_string(entry.get("difficulty", "Mythic"))}",')
            lines.append(f'                builds = {{')

            for build in entry.get("builds", []):
                ts = escape_lua_string(build["talentString"])
                lines.append(f'                    {{')
                lines.append(f'                        rank = {build["rank"]},')
                lines.append(f'                        talentString = "{ts}",')
                lines.append(f'                        popularity = {build["popularity"]},')
                lines.append(f'                    }},')

            lines.append(f'                }},')
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
        description="Fetch top talent builds from Archon.gg for TalentSwapper"
    )
    parser.add_argument("--class", dest="class_name", default=None,
                        help='WoW class name, lowercase (e.g. "warlock", "hunter")')
    parser.add_argument("--spec", dest="spec_name", default=None,
                        help='Spec name, lowercase (e.g. "demonology", "beast-mastery")')
    parser.add_argument("--content", default="all",
                        choices=["raid", "mythic-plus", "all"],
                        help="Content type to fetch (default: all)")
    parser.add_argument("--all", dest="scrape_all", action="store_true",
                        help="Scrape ALL classes and specs")
    args = parser.parse_args()

    if not args.scrape_all and (not args.class_name or not args.spec_name):
        parser.error("Either --all or both --class and --spec are required")

    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

    # Build the list of (class_slug, spec_slug) pairs to scrape
    spec_list = []
    if args.scrape_all:
        for cls, specs in ALL_SPECS.items():
            for spec in specs:
                spec_list.append((cls, spec))
    else:
        cls = args.class_name.lower().replace(" ", "-")
        spec = args.spec_name.lower().replace(" ", "-")
        spec_list.append((cls, spec))

    total = len(spec_list)
    print(f"Scraping {total} spec(s), content: {args.content}")
    print("=" * 60)

    all_specs_data = {}

    for idx, (cls, spec) in enumerate(spec_list, 1):
        key = f"{cls}:{spec}"
        display = f"{format_display_name(spec)} {format_display_name(cls)}"
        print(f"\n[{idx}/{total}] {display}")

        encounters = scrape_spec(cls, spec, args.content)
        has_builds = any(e["builds"] for e in encounters)

        if has_builds:
            all_specs_data[key] = {
                "class": format_display_name(cls),
                "spec": format_display_name(spec),
                "encounters": encounters,
            }
            build_count = sum(len(e["builds"]) for e in encounters)
            print(f"  -> {build_count} total builds")
        else:
            print(f"  -> No builds found, skipping")

    if not all_specs_data:
        print("\nNo talent data found for any spec.")
        sys.exit(1)

    write_lua_output(all_specs_data, timestamp)

    specs_with_data = len(all_specs_data)
    total_builds = sum(
        sum(len(e["builds"]) for e in sd["encounters"])
        for sd in all_specs_data.values()
    )
    print(f"\nDone! {specs_with_data} specs, {total_builds} total builds.")
    print("Restart WoW or /reload to load recommended builds.")


if __name__ == "__main__":
    main()
