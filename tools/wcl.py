"""
Warcraft Logs (API v2) support for update_data.py.

Two jobs:
  1. import_character_runs(): every ranked M+ run of your characters, with the
     official Warcraft Logs percentile, for the in-game run history.
  2. fetch_benchmarks(): DPS needed for top 1/10/25/50/75% and #1, per
     dungeon, spec and key level, so live runs can be ranked in game.

Needs a free API client from https://www.warcraftlogs.com/api/clients
Provide it as environment variables WCL_CLIENT_ID / WCL_CLIENT_SECRET, or in
tools/wcl_key.json: {"client_id": "...", "client_secret": "..."}.

The ranking payloads are documented as "can change without notice", so all
parsing here is defensive. Run update_data.py with --debug to print raw
samples if something looks off.
"""
import base64, json, math, os, re, time, urllib.parse, urllib.request

TOKEN_URL = "https://www.warcraftlogs.com/oauth/token"
API_URL = "https://www.warcraftlogs.com/api/v2/client"
HERE = os.path.dirname(os.path.abspath(__file__))

CLASS_NAMES = ["Death Knight", "Demon Hunter", "Druid", "Evoker", "Hunter", "Mage", "Monk",
               "Paladin", "Priest", "Rogue", "Shaman", "Warlock", "Warrior"]

# Percentile anchors stored per benchmark: top X% -> DPS at that rank.
ANCHORS = [1, 10, 25, 50, 75]

DEBUG = False


def log_debug(label, obj):
    if DEBUG:
        print(f"[debug] {label}: {json.dumps(obj, default=str)[:1500]}")


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def load_credentials():
    cid, sec = os.environ.get("WCL_CLIENT_ID"), os.environ.get("WCL_CLIENT_SECRET")
    if cid and sec:
        return cid, sec
    path = os.path.join(HERE, "wcl_key.json")
    if os.path.exists(path):
        d = json.load(open(path, encoding="utf-8"))
        return d.get("client_id"), d.get("client_secret")
    return None, None


class WCL:
    def __init__(self, client_id, client_secret, point_budget=None):
        auth = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
        req = urllib.request.Request(TOKEN_URL, data=b"grant_type=client_credentials",
                                     headers={"Authorization": f"Basic {auth}",
                                              "Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=30) as r:
            self.token = json.load(r)["access_token"]
        self.point_budget = point_budget
        self.spent_start = None
        self.out_of_points = False

    def query(self, q, variables=None):
        body = json.dumps({"query": q, "variables": variables or {}}).encode()
        req = urllib.request.Request(API_URL, data=body, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json",
            "User-Agent": "MPlusPercentile-updater/3.0"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    data = json.load(r)
                break
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    self.out_of_points = True
                    raise RuntimeError("Warcraft Logs rate limit reached")
                if attempt == 2:
                    raise
                time.sleep(3)
        if data.get("errors"):
            raise RuntimeError(data["errors"][0].get("message", "GraphQL error"))
        return data["data"]

    def points(self):
        d = self.query("{ rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } }")["rateLimitData"]
        if self.spent_start is None:
            self.spent_start = d["pointsSpentThisHour"]
        return d

    def budget_left(self):
        d = self.points()
        left_hour = d["limitPerHour"] - d["pointsSpentThisHour"]
        if self.point_budget is not None:
            left_hour = min(left_hour, self.point_budget - (d["pointsSpentThisHour"] - self.spent_start))
        return left_hour


# --------------------------------------------------------------------------
# Zones and dungeons
# --------------------------------------------------------------------------
def mythic_plus_zones(api):
    """All Warcraft Logs M+ zones, newest first, each with its dungeons."""
    d = api.query("""{ worldData { expansions { id name zones {
        id name frozen encounters { id name } } } } }""")
    zones = []
    for exp in d["worldData"]["expansions"] or []:
        for z in exp.get("zones") or []:
            if "mythic+" in (z.get("name") or "").lower():
                zones.append({"id": z["id"], "name": z["name"], "frozen": z.get("frozen"),
                              "expansion": exp.get("name"), "encounters": z.get("encounters") or []})
    zones.sort(key=lambda z: z["id"], reverse=True)
    return zones


def current_zone(zones):
    live = [z for z in zones if not z.get("frozen")]
    return (live or zones or [None])[0]


# --------------------------------------------------------------------------
# Parsing helpers for ranking rows (field names differ between eras)
# --------------------------------------------------------------------------
def row_level(r):
    for k in ("bracketData", "keystoneLevel", "bracket", "hardModeLevel"):
        v = r.get(k)
        if isinstance(v, (int, float)) and v > 0:
            return int(v)
    return None


def row_amount(r):
    for k in ("amount", "total", "dps"):
        v = r.get(k)
        if isinstance(v, (int, float)):
            return float(v)
    return None


def row_time_ms(r):
    rep = r.get("report") or {}
    for v in (r.get("startTime"), rep.get("startTime")):
        if isinstance(v, (int, float)) and v > 0:
            return int(v)
    return None


def row_spec(r):
    s = r.get("spec") or r.get("specName") or r.get("bestSpec")
    return s if isinstance(s, str) else None


# --------------------------------------------------------------------------
# 1. Your characters' ranked runs
# --------------------------------------------------------------------------
def import_character_runs(api, char, zones, dungeon_map):
    """char: {"region","realm","name"}  ->  list of run dicts for Data.lua."""
    runs = []
    slug = char["realm"].lower().replace(" ", "-").replace("'", "")
    for z in zones:
        if not z["encounters"]:
            continue
        fields = "\n".join(
            f'e{e["id"]}: encounterRankings(encounterID: {e["id"]}, metric: dps)' for e in z["encounters"])
        q = f"""query($n:String!,$s:String!,$r:String!) {{ characterData {{
            character(name:$n, serverSlug:$s, serverRegion:$r) {{ {fields} }} }} }}"""
        try:
            data = api.query(q, {"n": char["name"], "s": slug, "r": char["region"].upper()})
        except RuntimeError as e:
            if "rate limit" in str(e):
                raise
            print(f"    {z['name']}: skipped ({e})")
            continue
        ch = (data.get("characterData") or {}).get("character")
        if not ch:
            print(f"    {char['name']}: not found on Warcraft Logs")
            return runs
        found = 0
        for e in z["encounters"]:
            block = ch.get(f'e{e["id"]}') or {}
            ranks = block.get("ranks") or []
            if ranks and found == 0:
                log_debug(f"rank row ({e['name']})", ranks[0])
            for r in ranks:
                amount, t = row_amount(r), row_time_ms(r)
                if amount is None or t is None:
                    continue
                rep = r.get("report") or {}
                runs.append({
                    "t": t // 1000,
                    "season": z["name"],
                    "dungeon": e["name"],
                    "map": dungeon_map.get(norm(e["name"])),
                    "level": row_level(r),
                    "dps": round(amount, 1),
                    "pct": r.get("rankPercent") if isinstance(r.get("rankPercent"), (int, float)) else None,
                    "spec": row_spec(r),
                    "dur": (r.get("duration") or 0) // 1000 or None,
                    "report": f'{rep.get("code")}#{rep.get("fightID")}' if rep.get("code") else None,
                    "src": "logs",
                })
                found += 1
        if found:
            print(f"    {z['name']}: {found} ranked runs")
    runs.sort(key=lambda x: x["t"])
    return runs


# --------------------------------------------------------------------------
# 2. Benchmarks: DPS at each percentile, per dungeon / spec / key level
# --------------------------------------------------------------------------
def split_spec_label(label):
    """'Beast Mastery Hunter' -> ('Hunter', 'BeastMastery') as Warcraft Logs slugs."""
    for cls in CLASS_NAMES:
        if label.endswith(" " + cls):
            spec = label[: -len(cls) - 1]
            return cls.replace(" ", ""), spec.replace(" ", "")
    return None, None


def _page(api, enc_id, cls, spec, level, pages):
    """Fetch several ranking pages in one request (GraphQL aliases)."""
    parts = "\n".join(
        f'p{p}: characterRankings(className: "{cls}", specName: "{spec}", bracket: {level}, '
        f'metric: dps, page: {p})' for p in pages)
    d = api.query(f"{{ worldData {{ encounter(id: {enc_id}) {{ {parts} }} }} }}")
    enc = (d.get("worldData") or {}).get("encounter") or {}
    out = {}
    for p in pages:
        block = enc.get(f"p{p}") or {}
        rows = block.get("rankings") or []
        out[p] = (rows, bool(block.get("hasMorePages")))
    return out


def benchmark_one(api, enc_id, cls, spec, level, old=None):
    """Returns {"top":..,"n":..,"lp":..,"p1":..,...} or None.
    Usually 2 requests when a previous result (old) gives the last page."""
    guess = (old or {}).get("lp")
    first_pages = [1] + ([guess, guess + 1] if guess and guess > 1 else [])
    got0 = _page(api, enc_id, cls, spec, level, first_pages)
    rows, more = got0[1]
    if not rows:
        return None
    log_debug("benchmark row", rows[0])
    amounts = [row_amount(r) for r in rows if row_amount(r) is not None]
    if not amounts:
        return None
    per_page = len(rows)

    # Find the last page: reuse last time's answer if it still holds,
    # otherwise probe 2, 4, 8, ... then binary search.
    last_rows = rows
    known_last = None
    if more and guess and guess > 1:
        g_rows, g_more = got0[guess]
        n_rows, _ = got0[guess + 1]
        if g_rows and not g_more and not n_rows:
            known_last, last_rows = guess, g_rows
    if more and known_last:
        last_page = known_last
    elif more:
        lo, hi, probe = 1, None, max(2, guess or 2)
        while hi is None:
            r, m = _page(api, enc_id, cls, spec, level, [probe])[probe]
            if not r:
                hi = probe
            elif not m:
                lo, hi, last_rows = probe, probe, r
                break
            else:
                lo, probe = probe, probe * 2
                if probe > 4096:
                    hi = probe
        while hi - lo > 1:
            mid = (lo + hi) // 2
            r, m = _page(api, enc_id, cls, spec, level, [mid])[mid]
            if not r:
                hi = mid
            else:
                lo, last_rows = mid, r
                if not m:
                    break
        last_page = lo
    else:
        last_page = 1
    n = (last_page - 1) * per_page + len(last_rows)

    res = {"top": round(amounts[0], 1), "n": n, "lp": last_page}
    if last_page == 1:
        for a in ANCHORS:
            idx = min(len(amounts) - 1, max(0, math.ceil(a / 100 * n) - 1))
            res[f"p{a}"] = round(amounts[idx], 1)
        return res

    wanted = {}
    for a in ANCHORS:
        rank = max(1, math.ceil(a / 100 * n))
        wanted[a] = ((rank - 1) // per_page + 1, (rank - 1) % per_page)
    pages = sorted({p for p, _ in wanted.values()})
    got = {1: (rows, more)}
    pages = [p for p in pages if p not in got]
    for i in range(0, len(pages), 5):
        got.update(_page(api, enc_id, cls, spec, level, pages[i:i + 5]))
    for a, (p, idx) in wanted.items():
        rows_p = (got.get(p) or ([], False))[0]
        if rows_p:
            v = row_amount(rows_p[min(idx, len(rows_p) - 1)])
            if v is not None:
                res[f"p{a}"] = round(v, 1)
    return res


def fetch_benchmarks(api, zone, dungeon_map, spec_labels, levels, existing, priority=None,
                     reserve=200, max_age_days=3):
    """
    Refresh as many (dungeon, spec, level) benchmarks as the point budget allows.
    existing:  previous MPP_DATA.dps table, kept for anything not refreshed.
    priority:  set of (mapID, specID, level) to do first (your own runs).
    Stale entries are refreshed oldest-first, so coverage fills in over a few days.
    """
    out = existing or {}
    now = int(time.time())
    jobs = []
    for e in zone["encounters"]:
        map_id = dungeon_map.get(norm(e["name"]))
        if not map_id:
            continue
        for spec_id, label in spec_labels.items():
            cls, spec = split_spec_label(label)
            if not cls:
                continue
            for lv in levels:
                old = ((out.get(map_id) or {}).get(spec_id) or {}).get(lv)
                age = now - (old or {}).get("u", 0)
                if old and age < max_age_days * 86400:
                    continue
                pri = 0 if priority and (map_id, spec_id, lv) in priority else 1
                jobs.append((pri, (old or {}).get("u", 0), map_id, spec_id, lv, e["id"], cls, spec))
    jobs.sort()
    done = 0
    for _, _, map_id, spec_id, lv, enc_id, cls, spec in jobs:
        if done % 10 == 0 and api.budget_left() < reserve:
            print(f"    Point budget reached after {done} benchmarks; {len(jobs) - done} left for next run.")
            break
        try:
            old = ((out.get(map_id) or {}).get(spec_id) or {}).get(lv)
            b = benchmark_one(api, enc_id, cls, spec, lv, old)
        except RuntimeError as e:
            print(f"    Stopped: {e}")
            break
        done += 1
        if b:
            b["u"] = now
            out.setdefault(map_id, {}).setdefault(spec_id, {})[lv] = b
    else:
        if jobs:
            print(f"    Refreshed {done} benchmarks.")
    return out
