#!/usr/bin/env python3
"""
Fetch Mythic+ rating cutoffs from the public Raider.IO API and write ../Data.lua.

For each region it downloads cutoffs (top 0.1/1/5/10/25/40%) and population for:
  overall, every role (tank/healer/dps), every class and every spec.

Optionally, for characters listed in characters.json it also stores their exact
Raider.IO ranks, so the addon can show exact percentiles instead of estimates.

Usage:
    python update_data.py                     # all regions, auto-detected season
    python update_data.py --regions eu        # just your region (faster)
    python update_data.py --season season-mn-2
    python update_data.py --chars characters.json

characters.json:
    [ {"region": "eu", "realm": "silvermoon", "name": "Yourmain"} ]

No third-party packages needed.
"""
import argparse, datetime, json, os, re, sys, time, urllib.parse, urllib.request

API = "https://raider.io/api/v1"
ALL_REGIONS = ["us", "eu", "kr", "tw"]
CATEGORIES = ["overall", "roles", "classes", "specs"]
PERCENTILES = "0.1,1,5,10,25,40"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Data.lua")


def get(path, **params):
    url = f"{API}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": "MPlusPercentile-updater/2.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def parse_time(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def detect_season():
    """The main season currently running in the US."""
    now = datetime.datetime.now(datetime.timezone.utc)
    best = None
    for exp in range(14, 8, -1):
        try:
            data = get("/mythic-plus/static-data", expansion_id=exp)
        except Exception:
            continue
        for s in data.get("seasons", []):
            if not s.get("is_main_season", True):
                continue
            start = (s.get("starts") or {}).get("us")
            end = (s.get("ends") or {}).get("us")
            if not start or parse_time(start) > now:
                continue
            if end and parse_time(end) <= now:
                continue
            if best is None or parse_time(start) > parse_time(best["starts"]["us"]):
                best = s
        if best:
            return best["slug"], best.get("name", best["slug"])
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
    return ascii_lower(re.sub(r"[\s']", "", f"{name}-{realm}"))


def fetch_char(c):
    p = get("/characters/profile", region=c["region"], realm=c["realm"], name=c["name"],
            fields="mythic_plus_scores_by_season:current,mythic_plus_ranks")
    ranks = {k: v.get("region") for k, v in (p.get("mythic_plus_ranks") or {}).items()
             if isinstance(v, dict) and v.get("region")}
    seasons = p.get("mythic_plus_scores_by_season") or [{}]
    score = (seasons[0].get("scores") or {}).get("all")
    return char_key(p["name"], p["realm"]), {
        "score": score, "ranks": ranks, "date": datetime.date.today().isoformat(),
    }


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
    ap.add_argument("--regions", default=",".join(ALL_REGIONS),
                    help="comma-separated, e.g. eu or us,eu")
    ap.add_argument("--chars", default=os.path.join(HERE, "characters.json"))
    a = ap.parse_args()

    slug, name = (a.season, a.season) if a.season else detect_season()
    print(f"Season: {name} ({slug})")

    regions = {}
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
            ov = cohorts.get("overall")
            extra = f"top 1% = {ov['cutoffs'][1]['score']:.0f}, {ov['pop']:,} players" if ov and len(ov["cutoffs"]) > 1 else ""
            print(f"  {r.upper()}: {len(cohorts)} groups  {extra}")

    if not regions:
        sys.exit("No cutoff data received. Keeping the existing Data.lua.")

    chars = {}
    if os.path.exists(a.chars):
        for c in json.load(open(a.chars, encoding="utf-8")):
            try:
                k, v = fetch_char(c)
                chars[k] = v
                print(f"  {c['name']}: #{v['ranks'].get('overall')} overall in {c['region'].upper()}")
            except Exception as e:
                print(f"  {c.get('name')}: failed ({e})")
            time.sleep(0.5)

    now = datetime.datetime.now(datetime.timezone.utc)
    data = {"version": 2, "season": name, "updatedAt": now.strftime("%Y-%m-%d %H:%M UTC"),
            "updatedEpoch": int(now.timestamp()), "regions": regions, "characters": chars}
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("-- AUTO-GENERATED by tools/update_data.py. Do not edit by hand.\n")
        f.write("MPP_DATA = " + lua(data) + "\n")
    print(f"Wrote {os.path.normpath(OUT)}. Type /reload in game to load it.")


if __name__ == "__main__":
    main()
