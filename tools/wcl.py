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

# Percentile anchors stored per benchmark: top X% -> amount at that rank.
BENCH_VERSION = 2  # bump to discard cached benchmarks made differently

# #1 is stored as "top"; these are the other points kept per benchmark.
ANCHORS = [1, 10, 50]

# Healers are ranked on healing per second, everyone else on damage.
HEALER_SPECS = {65, 105, 256, 257, 264, 270, 1468}
TANK_SPECS = {66, 73, 104, 250, 268, 581}


def metric_for_spec(spec_id):
    return "hps" if spec_id in HEALER_SPECS else "dps"


def role_for_spec(spec_id):
    if spec_id in HEALER_SPECS: return "healer"
    if spec_id in TANK_SPECS: return "tank"
    return "dps"

DEBUG = False


def log_debug(label, obj):
    if DEBUG:
        print(f"[debug] {label}: {json.dumps(obj, default=str)[:1500]}")


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def load_credentials(folders=None):
    cid, sec = os.environ.get("WCL_CLIENT_ID"), os.environ.get("WCL_CLIENT_SECRET")
    if cid and sec:
        return cid, sec
    for folder in folders or [HERE]:
        path = os.path.join(folder, "wcl_key.json")
        if os.path.exists(path):
            d = json.load(open(path, encoding="utf-8-sig"))
            cid, sec = d.get("client_id"), d.get("client_secret")
            if cid and sec and "paste" not in cid:
                return cid, sec
    return None, None


class RateLimited(RuntimeError):
    """The Warcraft Logs key hit a limit: its hourly API points, or the
    separate budget for ranking lookups ("database points")."""

    def __init__(self, msg, kind="points"):
        super().__init__(msg)
        self.kind = kind


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
        self.limit_kind = None

    def query(self, q, variables=None):
        body = json.dumps({"query": q, "variables": variables or {}}).encode()
        req = urllib.request.Request(API_URL, data=body, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json",
            "User-Agent": "KeystonePercentile-updater/3.0"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    data = json.load(r)
                break
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    self.out_of_points, self.limit_kind = True, "points"
                    raise RateLimited("Warcraft Logs rate limit reached")
                if attempt == 2:
                    raise
                time.sleep(3)
        if data.get("errors"):
            msg = data["errors"][0].get("message", "GraphQL error")
            if "database points" in msg.lower():
                self.out_of_points, self.limit_kind = True, "database"
                raise RateLimited("Warcraft Logs ranking-lookup limit reached", "database")
            if "points" in msg.lower() or "rate limit" in msg.lower():
                self.out_of_points, self.limit_kind = True, "points"
                raise RateLimited("Warcraft Logs rate limit reached")
            raise RuntimeError(msg)
        return data["data"]

    def reset_minutes(self):
        """Minutes until this key's hourly points refill, or None if unknown."""
        try:
            d = self.query("{ rateLimitData { pointsResetIn } }")["rateLimitData"]
            return max(1, round(d["pointsResetIn"] / 60))
        except Exception:
            return None

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
        id name frozen brackets { min type } encounters { id name } } } } }""")
    zones = []
    for exp in d["worldData"]["expansions"] or []:
        for z in exp.get("zones") or []:
            if "mythic+" in (z.get("name") or "").lower():
                br = z.get("brackets") or {}
                zones.append({"id": z["id"], "name": z["name"], "frozen": z.get("frozen"),
                              "expansion": exp.get("name"), "encounters": z.get("encounters") or [],
                              # Warcraft Logs numbers key-level brackets from the zone's lowest
                              # key: with keys starting at +2, +18 is bracket 17.
                              "bracketMin": br.get("min") if isinstance(br.get("min"), int) else 2})
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
def import_character_runs(api, char, zones, dungeon_map, cache=None):
    """char: {"region","realm","name"} -> list of run dicts for the addon.
    cache: {zone_id: [runs]} for this character, updated in place. Finished
    (frozen) seasons already in the cache are not fetched again. Raises
    RateLimited when the key runs out of points; the cache keeps what was
    fetched so far."""
    cache = cache if cache is not None else {}
    slug = char["realm"].lower().replace(" ", "-").replace("'", "")
    for z in zones:
        zid = str(z["id"])
        if not z["encounters"] or (z.get("frozen") and zid in cache):
            continue
        fields = "\n".join(
            f'd{e["id"]}: encounterRankings(encounterID: {e["id"]}, metric: dps, byBracket: true)\n'
            f'h{e["id"]}: encounterRankings(encounterID: {e["id"]}, metric: hps, byBracket: true)'
            for e in z["encounters"])
        q = f"""query($n:String!,$s:String!,$r:String!) {{ characterData {{
            character(name:$n, serverSlug:$s, serverRegion:$r) {{ {fields} }} }} }}"""
        try:
            data = api.query(q, {"n": char["name"], "s": slug, "r": char["region"].upper()})
        except RateLimited:
            raise
        except RuntimeError as e:
            print(f"    {z['name']}: skipped ({e})")
            continue
        ch = (data.get("characterData") or {}).get("character")
        if not ch:
            print(f"    {char['name']}: not found on Warcraft Logs")
            break
        zone_runs = []
        for e in z["encounters"]:
            by_run = {}
            for metric, alias in (("dps", "d"), ("hps", "h")):
                ranks = (ch.get(f'{alias}{e["id"]}') or {}).get("ranks") or []
                if ranks and not zone_runs and not by_run:
                    log_debug(f"{metric} rank row ({e['name']})", ranks[0])
                for r in ranks:
                    amount, t = row_amount(r), row_time_ms(r)
                    if amount is None or t is None:
                        continue
                    rep = r.get("report") or {}
                    key = (rep.get("code"), rep.get("fightID")) if rep.get("code") else ("t", t // 60000)
                    run = by_run.get(key)
                    if not run:
                        run = by_run[key] = {
                            "t": t // 1000,
                            "zid": z["id"],
                            "season": f'{z["name"]} ({z["expansion"]})' if z.get("expansion") else z["name"],
                            "dungeon": e["name"],
                            "map": dungeon_map.get(norm(e["name"])),
                            "level": row_level(r),
                            "spec": row_spec(r),
                            "dur": (r.get("duration") or 0) // 1000 or None,
                            "report": f'{rep.get("code")}#{rep.get("fightID")}' if rep.get("code") else None,
                            "src": "logs",
                        }
                    # byBracket: rankPercent compares with runs at the same key level only.
                    pct = r.get("rankPercent") if isinstance(r.get("rankPercent"), (int, float)) else None
                    total = r.get("rankTotalParses") if isinstance(r.get("rankTotalParses"), int) else None
                    if metric == "dps":
                        run["dps"], run["pct"], run["n"] = round(amount, 1), pct, total
                    else:
                        run["hps"], run["hpct"], run["hn"] = round(amount, 1), pct, total
            zone_runs.extend(by_run.values())
        cache[zid] = zone_runs
        if zone_runs:
            label = f'{z["name"]} ({z["expansion"]})' if z.get("expansion") else z["name"]
            print(f"    {label}: {len(zone_runs)} ranked runs")
    wanted = {str(z["id"]) for z in zones}
    runs = [r for zid, zr in cache.items() if zid in wanted for r in zr]
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


def _page(api, enc_id, cls, spec, level, pages, metric="dps"):
    """Fetch several ranking pages in one request (GraphQL aliases)."""
    parts = "\n".join(
        f'p{p}: characterRankings(className: "{cls}", specName: "{spec}", bracket: {level}, '
        f'metric: {metric}, page: {p})' for p in pages)
    d = api.query(f"{{ worldData {{ encounter(id: {enc_id}) {{ {parts} }} }} }}")
    enc = (d.get("worldData") or {}).get("encounter") or {}
    out = {}
    for p in pages:
        block = enc.get(f"p{p}") or {}
        rows = block.get("rankings") or []
        out[p] = (rows, bool(block.get("hasMorePages")))
    return out


def _find_count(api, enc_id, cls, spec, bracket, metric, per_page, first_rows, guess=None):
    """Number of ranked runs, found by probing pages (2, 4, 8, ... then binary search)."""
    lo, hi, probe, last_rows = 1, None, max(2, guess or 2), first_rows
    while hi is None:
        r, m = _page(api, enc_id, cls, spec, bracket, metric=metric, pages=[probe])[probe]
        if not r:
            hi = probe
        elif not m:
            return (probe - 1) * per_page + len(r)
        else:
            lo, last_rows, probe = probe, r, probe * 2
            if probe > 4096:
                hi = probe
    while hi - lo > 1:
        mid = (lo + hi) // 2
        r, m = _page(api, enc_id, cls, spec, bracket, metric=metric, pages=[mid])[mid]
        if not r:
            hi = mid
        else:
            lo, last_rows = mid, r
            if not m:
                break
    return (lo - 1) * per_page + len(last_rows)


def benchmark_one(api, enc_id, cls, spec, bracket, old=None, metric="dps", n_hint=None):
    """#1, top 1%, top 10% and median for one dungeon / spec / key level.
    Rankings come sorted best first, so each value is the row at that rank.
    n_hint (number of ranked runs, e.g. from your own run's rankTotalParses) or a
    previous result saves the page probing. Usually 2-3 ranking lookups."""
    rows, more = _page(api, enc_id, cls, spec, bracket, metric=metric, pages=[1])[1]
    amounts = [row_amount(r) for r in rows or [] if row_amount(r) is not None]
    if not amounts:
        return None
    log_debug("benchmark row", rows[0])
    per_page = len(rows)
    got = {1: (rows, more)}
    if not more:
        n = len(amounts)
    else:
        # Check a guessed count (your run's count, or last time's) by reading its
        # last page: it must have rows and be the final page. Otherwise count.
        guess = n_hint or (old or {}).get("n")
        n = None
        if guess and guess > per_page:
            lp = math.ceil(guess / per_page)
            got.update(_page(api, enc_id, cls, spec, bracket, metric=metric, pages=[lp]))
            last_rows, last_more = got[lp]
            if last_rows and not last_more:
                n = (lp - 1) * per_page + len(last_rows)
        if not n:
            n = _find_count(api, enc_id, cls, spec, bracket, metric, per_page, rows, (old or {}).get("lp"))
    res = {"top": round(amounts[0], 1), "n": n, "lp": max(1, math.ceil(n / per_page))}

    wanted = {a: max(1, math.ceil(a / 100 * n)) for a in ANCHORS}
    pages = sorted({(rank - 1) // per_page + 1 for rank in wanted.values()} - set(got))
    for i in range(0, len(pages), 5):
        got.update(_page(api, enc_id, cls, spec, bracket, metric=metric, pages=pages[i:i + 5]))
    for a, rank in wanted.items():
        p, idx = (rank - 1) // per_page + 1, (rank - 1) % per_page
        rows_p = (got.get(p) or ([], False))[0]
        if rows_p:
            v = row_amount(rows_p[min(idx, len(rows_p) - 1)])
            if v is not None:
                res[f"p{a}"] = round(v, 1)
    return res


def fetch_benchmarks(api, zone, dungeon_map, spec_labels, levels, existing, priority=None,
                     reserve=200, max_age_days=3, only_priority=False, n_hints=None):
    """
    Refresh as many (dungeon, spec, level) benchmarks as the point budget allows.
    existing:  previous KP_DATA.dps table, kept for anything not refreshed.
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
                if old and old.get("v") != BENCH_VERSION:
                    old = None  # made with the old (wrong) key-level numbering
                age = now - (old or {}).get("u", 0)
                if old and age < max_age_days * 86400:
                    continue
                pri = 0 if priority and (map_id, spec_id, lv) in priority else 1
                if only_priority and pri:
                    continue
                jobs.append((pri, (old or {}).get("u", 0), map_id, spec_id, lv, e["id"], cls, spec))
    for map_id in list(out):
        for spec_id in list(out[map_id]):
            for lv in list(out[map_id][spec_id]):
                if out[map_id][spec_id][lv].get("v") != BENCH_VERSION:
                    del out[map_id][spec_id][lv]
    jobs.sort()
    done = 0
    for _, _, map_id, spec_id, lv, enc_id, cls, spec in jobs:
        if done % 10 == 0 and api.budget_left() < reserve:
            print(f"    Point budget reached after {done} benchmarks; {len(jobs) - done} left for next run.")
            break
        try:
            old = ((out.get(map_id) or {}).get(spec_id) or {}).get(lv)
            metric = metric_for_spec(spec_id)
            bracket = lv - (zone.get("bracketMin") or 2) + 1
            hint = (n_hints or {}).get((map_id, spec_id, lv))
            b = benchmark_one(api, enc_id, cls, spec, bracket, old, metric=metric, n_hint=hint)
        except RuntimeError as e:
            print(f"    Stopped: {e}")
            break
        done += 1
        if b:
            b["u"], b["m"], b["v"] = now, metric, BENCH_VERSION
            out.setdefault(map_id, {}).setdefault(spec_id, {})[lv] = b
    else:
        if jobs:
            print(f"    Refreshed {done} benchmarks.")
    return out
