#!/usr/bin/env python3
"""
Download everything Keystone Percentile needs and write ../Data.lua.

From Raider.IO (no key needed):
  rating cutoffs and population per region for overall, roles, classes, specs,
  plus exact ranks for characters in characters.json.

From Warcraft Logs (needs a free API client, see wcl.py):
  - every ranked M+ run of your characters, for the in-game run history
  - DPS benchmarks per dungeon, spec and key level, to rank live runs

Usage:
    python update_data.py                       # everything available
    python update_data.py --regions eu          # just your region
    python update_data.py --no-wcl              # Raider.IO only
    python update_data.py --levels 10-20        # key levels to benchmark
    python update_data.py --debug               # print raw API samples

characters.json:
    [ {"region": "eu", "realm": "silvermoon", "name": "Yourmain"} ]

No third-party packages needed.
"""
import argparse, datetime, json, os, re, sys, time, urllib.parse, urllib.request

import wcl

API = "https://raider.io/api/v1"
ALL_REGIONS = ["us", "eu", "kr", "tw"]
CATEGORIES = ["overall", "roles", "classes", "specs"]
PERCENTILES = "0.1,1,5,10,25,40"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Data.lua")
CACHE = os.path.join(HERE, "cache", "benchmarks.json")


def get(path, **params):
    url = f"{API}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": "KeystonePercentile-updater/3.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def parse_time(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def find_season(slug=None):
    """Season dict from Raider.IO static data: the requested slug, or the
    main season currently running in the US."""
    now = datetime.datetime.now(datetime.timezone.utc)
    best = None
    for exp in range(14, 8, -1):
        try:
            data = get("/mythic-plus/static-data", expansion_id=exp)
        except Exception:
            continue
        for s in data.get("seasons", []):
            if slug:
                if s.get("slug") == slug:
                    return s
                continue
            if not s.get("is_main_season", True):
                continue
            start = (s.get("starts") or {}).get("us")
            end = (s.get("ends") or {}).get("us")
            if not start or parse_time(start) > now or (end and parse_time(end) <= now):
                continue
            if best is None or parse_time(start) > parse_time(best["starts"]["us"]):
                best = s
        if best and not slug:
            return best
    if slug:
        return {"slug": slug, "name": slug, "dungeons": []}
    sys.exit("Could not detect the current season. Pass --season <slug>, e.g. season-mn-2.")


def fetch_cohorts(season, region, category):
    data = get("/mythic-plus/cutoff-analysis", season=season, region=region,
               category=category, percentiles=PERCENTILES)
    cohorts = {}
    for c in data.get("cohorts", []):
        points = [{"pct": float(p["percentile"]), "score": float(p["cutoffScore"])}
                  for p in c.get("percentiles", []) if p.get("cutoffScore") is not None]
        if not points:
            continue
        points.sort(key=lambda p: p["pct"])
        cohorts[c["key"]] = {"label": c.get("label"), "pop": c.get("population"), "cutoffs": points}
    return cohorts, data.get("updatedAt")


def ascii_lower(s):
    return "".join(ch.lower() if ch.isascii() else ch for ch in s)


def char_key(name, realm):
    # Same rule as Key() in Core.lua: realm without spaces, apostrophes or dashes.
    return ascii_lower(re.sub(r"\s", "", name) + "-" + re.sub(r"[\s'\-()]", "", realm))


def fetch_char(c):
    p = get("/characters/profile", region=c["region"], realm=c["realm"], name=c["name"],
            fields="mythic_plus_scores_by_season:current,mythic_plus_ranks")
    ranks = {k: v.get("region") for k, v in (p.get("mythic_plus_ranks") or {}).items()
             if isinstance(v, dict) and v.get("region")}
    seasons = p.get("mythic_plus_scores_by_season") or [{}]
    score = (seasons[0].get("scores") or {}).get("all")
    return char_key(p["name"], p["realm"]), {
        "score": score, "ranks": ranks, "date": datetime.date.today().isoformat(),
        "class": p.get("class"),
    }


def parse_levels(s):
    out = set()
    for part in s.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-")
            out.update(range(int(a), int(b) + 1))
        elif part:
            out.add(int(part))
    return sorted(out)


def load_cache():
    if not os.path.exists(CACHE):
        return {}
    raw = json.load(open(CACHE, encoding="utf-8"))
    # JSON turns numeric keys into strings; Lua needs numbers.
    return {int(m): {int(s): {int(l): v for l, v in lv.items()} for s, lv in sp.items()}
            for m, sp in raw.items()}


def save_cache(data):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    json.dump(data, open(CACHE, "w", encoding="utf-8"), separators=(",", ":"))


def lua(v, ind=0):
    pad = "  " * ind
    if v is None: return "nil"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, float): return repr(round(v, 2))
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "{\n" + "".join(f"{pad}  {lua(x, ind + 1)},\n" for x in v) + pad + "}"
    if isinstance(v, dict):
        return "{\n" + "".join(f"{pad}  [{json.dumps(k, ensure_ascii=False)}] = {lua(x, ind + 1)},\n"
                               for k, x in v.items() if x is not None) + pad + "}"
    raise TypeError(type(v))


PERSONAL_NAME = "Keystone_Percentile_Personal"
PERSONAL_DIR = os.path.normpath(os.path.join(HERE, "..", "..", PERSONAL_NAME))


def interface_line():
    toc = os.path.join(HERE, "..", "Keystone_Percentile.toc")
    if os.path.exists(toc):
        for line in open(toc, encoding="utf-8"):
            if line.startswith("## Interface:"):
                return line.strip()
    return "## Interface: 120100"


def setup_personal_dir():
    """Create the personal folder (a tiny addon WowUp never touches) and move
    any old settings files from tools/ into it."""
    os.makedirs(PERSONAL_DIR, exist_ok=True)
    toc = os.path.join(PERSONAL_DIR, PERSONAL_NAME + ".toc")
    with open(toc, "w", encoding="utf-8") as f:
        f.write(interface_line() + "\n"
                "## Title: Keystone Percentile (your data)\n"
                "## Notes: Your imported Warcraft Logs runs and exact ranks. Made by Keystone Percentile's update script.\n"
                "## Dependencies: Keystone_Percentile\n\n"
                "Personal.lua\n")
    for fname, example in (("characters.json", "characters.example.json"), ("wcl_key.json", "wcl_key.example.json")):
        target = os.path.join(PERSONAL_DIR, fname)
        old = os.path.join(HERE, fname)
        if not os.path.exists(target) and os.path.exists(old):
            import shutil
            shutil.copyfile(old, target)
            print(f"  Moved {fname} to {PERSONAL_DIR}")
        if not os.path.exists(target):
            src = os.path.join(HERE, example)
            if os.path.exists(src):
                import shutil
                shutil.copyfile(src, target)
                print(f"  Created {target}: edit it, then run this script again.")


def write_lua(path, var, data, header):
    with open(path, "w", encoding="utf-8") as f:
        f.write(header + "\n")
        f.write(var + " = " + lua(data) + "\n")


def is_example(entries):
    return any("YourMain" in json.dumps(c) or "YOUR-REALM" in json.dumps(c) for c in entries)


def import_wcl(api, char_list, chars, zones, zone, dungeon_map, spec_labels, season_name, cache):
    """cache: {char_key: {zone_id: [runs]}}, updated in place. Returns
    (imported, priority, rate_limited)."""
    imported, priority, limited = {}, set(), False
    for c in char_list:
        key = char_key(c["name"], c["realm"])
        char_cache = cache.setdefault(key, {})
        wanted = {str(z["id"]) for z in zones}
        if limited:
            runs = sorted((r for zid, zr in char_cache.items() if zid in wanted for r in zr), key=lambda x: x["t"])
        else:
            print(f"  Importing runs for {c['name']}...")
            try:
                runs = wcl.import_character_runs(api, c, zones, dungeon_map, char_cache)
            except wcl.RateLimited:
                limited = True
                runs = sorted((r for zid, zr in char_cache.items() if zid in wanted for r in zr), key=lambda x: x["t"])
        cls = (chars.get(key) or {}).get("class")
        for run in runs:
            if zone and run.get("zid") == zone["id"]:
                run["season"] = season_name  # same label as live runs
            if cls:
                run["className"] = cls
                run["classFile"] = cls.upper().replace(" ", "")
            if run.get("spec") and cls:
                want = wcl.norm(run["spec"] + cls)
                for sid, label in spec_labels.items():
                    if wcl.norm(label) == want:
                        run["specID"] = sid
                        run["role"] = wcl.role_for_spec(sid)
                        break
            if run.get("map") and run.get("level") and run.get("specID"):
                priority.add((run["map"], run["specID"], run["level"]))
        if runs:
            imported[key] = runs
        print(f"    {len(runs)} runs total")
    return imported, priority, limited


def main():
    ap = argparse.ArgumentParser(description="Update Keystone Percentile data.")
    ap.add_argument("--full", action="store_true",
                    help="build the shared Data.lua for releases (used by GitHub); default is your personal data only")
    ap.add_argument("--season")
    ap.add_argument("--regions", default=",".join(ALL_REGIONS), help="--full only: e.g. us,eu")
    ap.add_argument("--no-wcl", action="store_true", help="skip Warcraft Logs")
    ap.add_argument("--no-benchmarks", action="store_true", help="don't fetch DPS/HPS benchmarks")
    ap.add_argument("--all-seasons", action="store_true", help="also import your runs from past seasons")
    ap.add_argument("--levels", default="10-20", help="--full only: key levels to benchmark")
    ap.add_argument("--wcl-budget", type=int, default=2500, help="max Warcraft Logs points to spend")
    ap.add_argument("--debug", action="store_true")
    a = ap.parse_args()
    wcl.DEBUG = a.debug

    season = find_season(a.season)
    slug, name = season["slug"], season.get("name", season["slug"])
    print(f"Season: {name} ({slug})")
    dungeons = {d["challenge_mode_id"]: d["name"] for d in season.get("dungeons", [])
                if d.get("challenge_mode_id")}
    dungeon_map = {wcl.norm(n): i for i, n in dungeons.items()}
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = {"season": name, "updatedAt": now.strftime("%Y-%m-%d %H:%M UTC"), "updatedEpoch": int(now.timestamp())}

    if a.full:
        # ---------------- Shared release data ----------------
        regions, spec_labels = {}, {}
        for r in [x.strip().lower() for x in a.regions.split(",") if x.strip()]:
            cohorts, updated = {}, None
            for cat in CATEGORIES:
                try:
                    got, updated = fetch_cohorts(slug, r, cat)
                    cohorts.update(got)
                except Exception as e:
                    print(f"  {r.upper()} {cat}: failed ({e})")
                time.sleep(0.5)
            if cohorts:
                regions[r] = {"cohorts": cohorts, "sourceUpdated": updated}
                for k, c in cohorts.items():
                    if k.startswith("spec:") and c.get("label"):
                        spec_labels[int(k[5:])] = c["label"]
                ov = cohorts.get("overall")
                extra = (f"top 1% = {ov['cutoffs'][1]['score']:.0f}, {ov['pop']:,} players"
                         if ov and len(ov["cutoffs"]) > 1 else "")
                print(f"  {r.upper()}: {len(cohorts)} groups  {extra}")
        if not regions:
            sys.exit("No cutoff data received. Keeping the existing Data.lua.")

        benchmarks = load_cache()
        cid, sec = wcl.load_credentials()
        if not a.no_wcl and not a.no_benchmarks and cid and sec:
            try:
                api = wcl.WCL(cid, sec, point_budget=a.wcl_budget)
                zone = wcl.current_zone(wcl.mythic_plus_zones(api))
                if zone and dungeon_map and spec_labels:
                    print(f"  Benchmarks for key levels {a.levels} (budget {a.wcl_budget} points)...")
                    benchmarks = wcl.fetch_benchmarks(api, zone, dungeon_map, spec_labels,
                                                      parse_levels(a.levels), benchmarks)
                    save_cache(benchmarks)
            except Exception as e:
                print(f"Warcraft Logs: stopped ({e}). Keeping what was fetched.")
        elif not a.no_wcl:
            print("Warcraft Logs: no API key, skipping benchmarks.")

        data = dict(stamp, version=3, regions=regions, dungeons=dungeons, dps=benchmarks,
                    characters={}, imported={})
        write_lua(OUT, "KP_DATA", data, "-- AUTO-GENERATED by tools/update_data.py --full. Do not edit by hand.")
        nb = sum(len(lv) for sp in benchmarks.values() for lv in sp.values())
        print(f"Wrote {os.path.normpath(OUT)} ({nb} DPS benchmarks).")
        return

    # ---------------- Personal data (default) ----------------
    print(f"Your data folder: {PERSONAL_DIR}")
    setup_personal_dir()
    chars_file = os.path.join(PERSONAL_DIR, "characters.json")
    char_list = json.load(open(chars_file, encoding="utf-8-sig")) if os.path.exists(chars_file) else []
    if not char_list or is_example(char_list):
        sys.exit(f"Add your characters to {chars_file} first, then run this again.")

    # Spec names (for matching Warcraft Logs runs) from your own region.
    spec_labels = {}
    region0 = char_list[0]["region"].lower()
    try:
        got, _ = fetch_cohorts(slug, region0, "specs")
        spec_labels = {int(k[5:]): c["label"] for k, c in got.items() if k.startswith("spec:") and c.get("label")}
    except Exception as e:
        print(f"  Spec list failed ({e}); runs will import without spec matching.")

    chars = {}
    for c in char_list:
        try:
            k, v = fetch_char(c)
            chars[k] = v
            print(f"  {c['name']}: Raider.IO #{v['ranks'].get('overall')} overall in {c['region'].upper()}")
        except Exception as e:
            print(f"  {c.get('name')}: Raider.IO lookup failed ({e})")
        time.sleep(0.5)

    imported, dps = {}, {}
    cache_file = os.path.join(PERSONAL_DIR, "benchmarks_cache.json")
    runs_cache_file = os.path.join(PERSONAL_DIR, "runs_cache.json")
    runs_cache = json.load(open(runs_cache_file, encoding="utf-8")) if os.path.exists(runs_cache_file) else {}
    if os.path.exists(cache_file):
        raw = json.load(open(cache_file, encoding="utf-8"))
        dps = {int(m): {int(sp): {int(l): v for l, v in lv.items()} for sp, lv in spd.items()}
               for m, spd in raw.items()}
    cid, sec = wcl.load_credentials([PERSONAL_DIR, HERE])
    if a.no_wcl:
        pass
    elif not (cid and sec):
        print(f"Warcraft Logs: add your API key to {os.path.join(PERSONAL_DIR, 'wcl_key.json')} to import your runs.")
    else:
        api, limited = None, False
        try:
            api = wcl.WCL(cid, sec, point_budget=a.wcl_budget)
            if api.budget_left() < 20:
                raise wcl.RateLimited("no points left")
            zones = wcl.mythic_plus_zones(api)
            zone = wcl.current_zone(zones)
            print(f"Warcraft Logs: current zone {zone['name'] if zone else '?'}")
            # Only the current season unless asked for more.
            import_zones = zones if a.all_seasons else ([zone] if zone else [])
            imported, priority, limited = import_wcl(api, char_list, chars, import_zones, zone, dungeon_map,
                                                     spec_labels, name, runs_cache)
            if zone and priority and not a.no_benchmarks and not limited:
                levels = sorted({lv for _, _, lv in priority})
                print(f"  Benchmarks for your {len(priority)} dungeon/spec/level combinations...")
                dps = wcl.fetch_benchmarks(api, zone, dungeon_map, spec_labels, levels, dps,
                                           priority, only_priority=True)
        except wcl.RateLimited:
            limited = True
        except Exception as e:
            print(f"Warcraft Logs: stopped ({e}). Keeping what was fetched.")
        if limited:
            wait = api.reset_minutes() if api else None
            print("Warcraft Logs: this API key has used up its points for the hour"
                  + (f"; they refill in about {wait} minutes." if wait else ".")
                  + " Everything fetched so far is saved; run this again later to continue.")
            if not imported:
                keep = None if a.all_seasons else {str(zone["id"])} if zone else set()
                for key, zones_cached in runs_cache.items():
                    zones_cached = {z: r for z, r in zones_cached.items() if keep is None or z in keep}
                    runs = sorted((r for zr in zones_cached.values() for r in zr), key=lambda x: x["t"])
                    if runs:
                        imported[key] = runs
        json.dump(runs_cache, open(runs_cache_file, "w", encoding="utf-8"), separators=(",", ":"))
        json.dump(dps, open(cache_file, "w", encoding="utf-8"), separators=(",", ":"))

    data = dict(stamp, characters=chars, imported=imported, dps=dps)
    out = os.path.join(PERSONAL_DIR, "Personal.lua")
    write_lua(out, "KP_PERSONAL", data, "-- Your Keystone Percentile data. Made by tools/update_data.py.")
    n = sum(len(v) for v in imported.values())
    print(f"Wrote {out} ({n} imported runs). Type /reload in game to load it.")


if __name__ == "__main__":
    main()
