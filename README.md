# Keystone Percentile

Two things:

1. **Where your Mythic+ rating ranks**: Top X% overall, for your role, your class and your spec.
2. **How your DPS ranks in every key** (HPS for healers): a pop-up when the key ends, and a history of all your runs, compared with Warcraft Logs players of the same spec in the same dungeon and key level.

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

**End-of-key pop-up:**
- Your DPS (HPS for healers), and your Top X% among logged runs of your spec at that dungeon and level.
- A bar from 0 to the #1 run with the 50/25/10/1% marks, and how much more each goal needs.
- What happened: deaths, share of your damage taken that was avoidable, and interrupts, compared with your own average.
- Your whole group, each ranked against players of their own spec.
- A Share button: click posts to group chat, shift-click to guild chat.

**History window** (click the panel, or `/kp runs`), with three tabs:
- **Runs:** every key you've done, with result, DPS or HPS, rank and a bar against #1. Filter by season, dungeon and spec, and sort by date, rank or amount. A star marks your best run per dungeon. Click any run to reopen its summary.
- **Progress:** a graph of your rating over the last 30 days or the whole season, coloured by percentile, with your change this week and this month ("+42 rating · Top 9.4% → Top 8.6%"). Your rating is saved once a day while you play, so the graph starts after two days.
- **Next keys:** for every dungeon, the key level to run next, about how much rating timing it would give, and your new Top % overall and for your spec. Estimates are fitted from your own dungeon scores.

**Settings** are under Options > AddOns > Keystone Percentile, or right-click the addon's icon in the addon dropdown by the minimap.

Ranks marked `~` are estimates from benchmarks. Ranks without `~` are official Warcraft Logs ranks for uploaded runs.

## Where the data comes from

Addons can't go online, so `tools/update_data.py` downloads the data and writes `Data.lua`. Releases on CurseForge already include fresh data every day.

| Data | Source | Needs |
|---|---|---|
| Rating cutoffs per region, role, class, spec | Raider.IO | nothing |
| Your exact Raider.IO ranks | Raider.IO | `tools/characters.json` |
| DPS (HPS for healers) benchmarks per dungeon, spec, key level | Warcraft Logs | API key |
| Your past runs, with official ranks | Warcraft Logs | API key + `tools/characters.json` |

Your DPS, healing, deaths, avoidable damage and interrupts for live runs come from the game's built-in damage meter. They're read right after the key ends, because the game hides meter values from addons during combat.

The interface is in English, German, French and Russian.

**Hero talents:** no public source ranks M+ by hero talent, so that row shows only the name.

## Install

**With WowUp:** Get Addons > Install from URL > `https://github.com/kociconline/Keystone_Percentile`. WowUp then shows updates like any other addon.

**By hand:** download the latest release zip from GitHub and unzip it into `World of Warcraft/_retail_/Interface/AddOns/`.

Every release already contains fresh rating cutoffs for all regions and Warcraft Logs DPS benchmarks, so the addon works right away.

### Optional: your Warcraft Logs runs and exact ranks

Needs Python 3 (on Windows: `winget install -e --id Python.Python.3.12`).

1. Open a terminal in the addon folder (`AddOns/Keystone_Percentile`) and run:
   ```
   py tools/update_data.py
   ```
   The first run creates a second folder next to the addon, `AddOns/Keystone_Percentile_Personal`, with two settings files. Updates from WowUp never touch that folder.
2. In `Keystone_Percentile_Personal/characters.json`, list your characters: region, realm as in its Raider.IO URL (e.g. `twisting-nether`), and name.
3. Create a free API client at https://www.warcraftlogs.com/api/clients (any name, redirect URL `http://localhost`, "Public Client" unticked). Paste its ID and secret into `Keystone_Percentile_Personal/wcl_key.json`.
4. Run `py tools/update_data.py` again. It imports every ranked run of your characters from every season, your exact Raider.IO ranks, and DPS benchmarks for the dungeons, specs and levels you play.
5. Type `/reload` in game. "Keystone Percentile (your data)" appears as its own entry in the AddOns list; keep it enabled.

Rerun after uploading new logs. Options: `--no-benchmarks` (runs only), `--debug` (print raw API samples). `--full` builds the shared release data and is used by GitHub.

## Commands

| Command | Effect |
|---|---|
| `/kp` | Print the rating rows in chat |
| `/kp runs` | Open or close the run history |
| `/kp progress` | Open the rating graph |
| `/kp next` | Open the next-key suggestions |
| `/kp config` | Open the settings |
| `/kp last` | Reopen the last run's summary |
| `/kp popup` | Turn the end-of-key pop-up on or off |
| `/kp hide` / `show` | Toggle the rating panel |
| `/kp lock` | Lock or unlock dragging |
| `/kp reset` | Reset the panel position |
| `/kp tooltips` | Toggle "Top X%" on player tooltips |
| `/kp region eu` | Force a region (`auto` to undo) |

## Publishing (CurseForge, Wago, WoWInterface)

Releases are built by the BigWigs packager on GitHub Actions:

- `daily-data.yml` runs every day at 08:23 UTC. If the data changed, it commits the new `Data.lua` and benchmark cache, tags `vX.Y.Z-data.YYYYMMDD` and publishes a release (GitHub, plus CurseForge and others once their IDs and tokens are set).
- `release.yml` runs when you push a version tag yourself (for example `v4.1.0`) after changing code.

One-time setup:

1. Push this folder to a GitHub repository.
2. Create the project on [CurseForge](https://authors.curseforge.com), [Wago](https://addons.wago.io) and/or [WoWInterface](https://www.wowinterface.com). Add each ID to `Keystone_Percentile.toc`:
   ```
   ## X-Curse-Project-ID: 123456
   ## X-Wago-ID: abcdEFGH
   ## X-WoWI-ID: 98765
   ```
   Leave out any site you don't use.
3. In the GitHub repository, under Settings > Secrets and variables > Actions, add `CF_API_KEY`, `WAGO_API_TOKEN`, `WOWI_API_TOKEN`, and `WCL_CLIENT_ID` and `WCL_CLIENT_SECRET` for the Warcraft Logs benchmarks.
4. Under Settings > Actions > General, set workflow permissions to "Read and write".
5. Push a first tag: `git tag v4.0.0 && git push origin v4.0.0`.
