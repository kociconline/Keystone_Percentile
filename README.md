# M+ Percentile

Two things, chess.com style:

1. **Where your Mythic+ rating ranks**: Top X% overall, for your role, your class and your spec.
2. **How your DPS ranks in every key**: a pop-up when the key ends, and a history of all your runs, compared with Warcraft Logs players of the same spec in the same dungeon and key level.

## What you see in game

**Rating panel** (always on screen, drag to move, click for run history):

```
3,300  M+ rating, EU
Overall             Top 8.6%   ~#60,384 / 700,211
Healer              Top 7.9%   ~#13,415 / 169,016
Paladin             Top 8.2%   ~#5,775 / 70,000
Holy                Top 7.3%   ~#1,838 / 25,000
Herald of the Sun   —          no ranking data
```

**End-of-key pop-up:** your DPS, your Top X% among logged runs of your spec at that dungeon and level, a bar from 0 to the #1 run with the 50/25/10/1% marks, and how much more DPS each goal needs.

**Run history** (`/mpp runs`): every key you've done, with result, DPS, rank and a bar against #1. Filter by season, dungeon and spec, and sort by date, rank or DPS. A star marks your best run per dungeon. Click any run to reopen its summary.

Ranks marked `~` are estimates from benchmarks. Ranks without `~` are official Warcraft Logs ranks for uploaded runs.

## Where the data comes from

Addons can't go online, so `tools/update_data.py` downloads the data and writes `Data.lua`. Releases on CurseForge already include fresh data every day.

| Data | Source | Needs |
|---|---|---|
| Rating cutoffs per region, role, class, spec | Raider.IO | nothing |
| Your exact Raider.IO ranks | Raider.IO | `tools/characters.json` |
| DPS benchmarks per dungeon, spec, key level | Warcraft Logs | API key |
| Your past runs, with official ranks | Warcraft Logs | API key + `tools/characters.json` |

Your DPS for live runs comes from the game's built-in damage meter. It's read right after the key ends, because the game hides meter values from addons during combat.

**Hero talents:** no public source ranks M+ by hero talent, so that row shows only the name.

## Install

1. Copy the `MPlusPercentile` folder to `World of Warcraft/_retail_/Interface/AddOns/`.
2. Type `/reload` in game. With a CurseForge release you're done.

### Optional: import your Warcraft Logs runs and exact ranks

Needs Python 3.

1. Copy `tools/characters.example.json` to `tools/characters.json` and list your characters.
2. Create a free API client at https://www.warcraftlogs.com/api/clients (any name, any redirect URL, e.g. `http://localhost`). Copy `tools/wcl_key.example.json` to `tools/wcl_key.json` and paste the client ID and secret.
3. Run:
   ```
   python tools/update_data.py --regions eu
   ```
   It imports every ranked run of your characters from every season, then fetches benchmarks for your own dungeons, specs and levels first.
4. Type `/reload` in game.

Rerun after uploading new logs. Useful options:

- `--levels 12-18`: key levels to benchmark (default `10-20`)
- `--no-benchmarks`: import your runs only
- `--debug`: print raw API samples if something looks wrong

Warcraft Logs limits free keys to a number of points per hour. The script stops when the budget runs out and continues next time, refreshing the oldest benchmarks first. A full first pass over every spec, dungeon and level takes a few runs; after that, each refresh is cheap.

## Commands

| Command | Effect |
|---|---|
| `/mpp` | Print the rating rows in chat |
| `/mpp runs` | Open or close the run history |
| `/mpp last` | Reopen the last run's summary |
| `/mpp popup` | Turn the end-of-key pop-up on or off |
| `/mpp hide` / `show` | Toggle the rating panel |
| `/mpp lock` | Lock or unlock dragging |
| `/mpp reset` | Reset the panel position |
| `/mpp tooltips` | Toggle "Top X%" on player tooltips |
| `/mpp region eu` | Force a region (`auto` to undo) |

## Publishing (CurseForge, Wago, WoWInterface)

Releases are built by the BigWigs packager on GitHub Actions:

- `daily-data.yml` runs every day at 08:23 UTC. If the data changed, it commits the new `Data.lua` and benchmark cache, tags `vX.Y.Z-data.YYYYMMDD` and uploads to every site.
- `release.yml` runs when you push a version tag yourself (for example `v3.1.0`) after changing code.

One-time setup:

1. Push this folder to a GitHub repository.
2. Create the project on [CurseForge](https://authors.curseforge.com), [Wago](https://addons.wago.io) and/or [WoWInterface](https://www.wowinterface.com). Add each ID to `MPlusPercentile.toc`:
   ```
   ## X-Curse-Project-ID: 123456
   ## X-Wago-ID: abcdEFGH
   ## X-WoWI-ID: 98765
   ```
   Leave out any site you don't use.
3. In the GitHub repository, under Settings > Secrets and variables > Actions, add `CF_API_KEY`, `WAGO_API_TOKEN`, `WOWI_API_TOKEN`, and `WCL_CLIENT_ID` and `WCL_CLIENT_SECRET` for the Warcraft Logs benchmarks.
4. Under Settings > Actions > General, set workflow permissions to "Read and write".
5. Push a first tag: `git tag v3.0.0 && git push origin v3.0.0`.
