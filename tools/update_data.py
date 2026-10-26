#!/usr/bin/env python3
"""
Download everything M+ Percentile needs and write ../Data.lua.

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
    req = urllib.request.Request(url, headers={"User-Agent": "MPlusPercentile-updater/3.0"})
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--season")
    ap.add_argument("--regions", default=",".join(ALL_REGIONS), help="e.g. eu or us,eu")
    ap.add_argument("--chars", default=os.path.join(HERE, "characters.json"))
    ap.add_argument("--no-wcl", action="store_true", help="skip Warcraft Logs")
    ap.add_argument("--no-benchmarks", action="store_true", help="import your runs only (no DPS/HPS benchmarks)")
    ap.add_argument("--levels", default="10-20", help="key levels to benchmark, e.g. 10-20 or 12,14,16")
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

    # ---------------- Raider.IO ----------------
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

    char_list = json.load(open(a.chars, encoding="utf-8")) if os.path.exists(a.chars) else []
    chars = {}
    for c in char_list:
        try:
            k, v = fetch_char(c)
            chars[k] = v
            print(f"  {c['name']}: #{v['ranks'].get('overall')} overall in {c['region'].upper()}")
        except Exception as e:
            print(f"  {c.get('name')}: Raider.IO lookup failed ({e})")
        time.sleep(0.5)

    # ---------------- Warcraft Logs ----------------
    benchmarks = load_cache()
    imported = {}
    cid, sec = wcl.load_credentials()
    if a.no_wcl:
        pass
    elif not (cid and sec):
        print("Warcraft Logs: no API key found (see tools/wcl.py). Skipping DPS data.")
    else:
        try:
            api = wcl.WCL(cid, sec, point_budget=a.wcl_budget)
            zones = wcl.mythic_plus_zones(api)
            zone = wcl.current_zone(zones)
            print(f"Warcraft Logs: current zone {zone['name'] if zone else '?'}")

            priority = set()
            for c in char_list:
                print(f"  Importing runs for {c['name']}...")
                runs = wcl.import_character_runs(api, c, zones, dungeon_map)
                key = char_key(c["name"], c["realm"])
                cls = (chars.get(key) or {}).get("class")
                for run in runs:
                    if zone and run["season"] == zone["name"]:
                        run["season"] = name  # same label as live runs
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

            if zone and not a.no_benchmarks and dungeon_map and spec_labels:
                print(f"  Benchmarks for key levels {a.levels} (budget {a.wcl_budget} points)...")
                benchmarks = wcl.fetch_benchmarks(api, zone, dungeon_map, spec_labels,
                                                  parse_levels(a.levels), benchmarks, priority)
                save_cache(benchmarks)
        except Exception as e:
            print(f"Warcraft Logs: stopped ({e}). Keeping what was fetched.")

    # ---------------- Write Data.lua ----------------
    now = datetime.datetime.now(datetime.timezone.utc)
    data = {"version": 3, "season": name, "updatedAt": now.strftime("%Y-%m-%d %H:%M UTC"),
            "updatedEpoch": int(now.timestamp()), "regions": regions, "characters": chars,
            "dungeons": dungeons, "dps": benchmarks, "imported": imported}
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("-- AUTO-GENERATED by tools/update_data.py. Do not edit by hand.\n")
        f.write("MPP_DATA = " + lua(data) + "\n")
    nb = sum(len(lv) for sp in benchmarks.values() for lv in sp.values())
    print(f"Wrote {os.path.normpath(OUT)} ({nb} DPS benchmarks). Type /reload in game to load it.")


if __name__ == "__main__":
    main()
