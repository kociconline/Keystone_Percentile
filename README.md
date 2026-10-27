<p align="center"><img src="Media/Store/logo.png" width="160" alt="Keystone Percentile logo"></p>

# Keystone Percentile

Two things:

1. **Where your Mythic+ rating ranks**: Top X% overall, for your role, your class and your spec.
2. **How your DPS ranks in every key** (HPS for healers): a pop-up when the key ends, and a history of all your runs, compared with Warcraft Logs players of the same spec in the same dungeon and key level.

## What you see in game

Open the main window with the **minimap button**, `/kp`, or from the small Keystone Percentile panel next to Blizzard's **Mythic+ window** (on the right, under Raider.IO's "best runs" panel when you use Raider.IO). The window has four tabs:

- **Overview:** your rating and Top % overall, for your role, class and spec, plus your goals:
  ```
  3,634  M+ rating, EU
  Overall     Top 3.1%   ~#30,841 / 984,581
  ...
  Goals
  Top 2%   next step      +70 rating · ~5 keys
  Top 1%                  +173 rating · ~12 keys
  Top 0.1% season title   +402 rating · ~27 keys
  ```
  Top 1% and Top 0.1% are always shown, plus the next bracket above you (Top 40%, 30%, 25%, 20%, 15%, 10%, 5%, 2%). Click a goal to open its plan in the Goals tab.
- **Runs:** every key you've done: key level and result (timed +1/+2/+3 or over time), your DPS or HPS, the median and #1 DPS of your class and spec in that dungeon at that key level with how far above or below you are ("500k +22%"), and your Top %. Filter by season, dungeon and spec, and sort by date, rank or amount. A raid-star marks your best run per dungeon. Click a run to open its page: your DPS, your rank ("#14 of 1,672 at +18"), and the median, your next bracket, Top 1%, Top 0.1% and #1 of your spec, each with its DPS and your difference.
- **Progress:** a graph of your rating over the whole season (or the last 30 days). Days before you installed the addon are rebuilt from your keys on Warcraft Logs (each logged key carries its rating points; your rating is your best run per dungeon added up). After that, your real rating is saved once a day while you play.
- **Goals:** a planner for one goal at a time (overall or your spec): the rating needed, about how many keys, and one row per dungeon with how high to time it.

All brackets are exact: besides Raider.IO's official cutoffs (0.1/1/5/10/25/40%), the release data includes brackets calculated from Raider.IO's daily score distribution, checked against the official ones. The number of keys is an estimate, based on how much rating each key level has given you so far.

**End-of-key pop-up:**
- Your DPS (HPS for healers), and your Top X% among logged runs of your spec at that dungeon and key level.
- The median, your next bracket, Top 1%, Top 0.1% and #1 of your class and spec for that dungeon and key level, each with its DPS and how far you are from it.
- A bar from 0 to the #1 run with those marks.
- What happened: deaths, share of your damage taken that was avoidable, and interrupts, compared with your own average.
- Your whole group, each ranked against players of their own spec.
- Your next rating goal and how many keys are left.
- A Share button: click posts to group chat, shift-click to guild chat.

**Floating panel** (optional, off by default): a small always-on panel with your Top % and next goal. Turn it on in the settings or with `/kp panel`, drag to move, drag the corner to resize.

**Settings** are under Options > AddOns > Keystone Percentile, or right-click the minimap button.

Ranks marked `~` are estimates from benchmarks. Ranks without `~` are official Warcraft Logs ranks for uploaded runs.

## Where the data comes from

Addons can't go online, so `tools/update_data.py` downloads the data and writes `Data.lua`. Releases on CurseForge already include fresh data every day.

| Data | Source | Needs |
|---|---|---|
| Rating cutoffs and score distributions per region, role, class, spec | Raider.IO | nothing |
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
4. Run `py tools/update_data.py` again. It imports every ranked run of your characters from the current season (add `--all-seasons` for past seasons too), your exact Raider.IO ranks, and DPS benchmarks for the dungeons, specs and levels you play.
5. Type `/reload` in game. "Keystone Percentile (your data)" appears as its own entry in the AddOns list; keep it enabled.

Rerun after uploading new logs. With `--all-seasons`, past seasons are fetched once and then reused. Warcraft Logs limits each API key to a number of points per hour: if it runs out, the script says when to try again and keeps everything fetched so far. Use a separate API client for GitHub's daily job, so your own imports don't share its budget. Options: `--no-benchmarks` (runs only), `--debug` (print raw API samples). `--full` builds the shared release data and is used by GitHub.

## Commands

| Command | Effect |
|---|---|
| `/kp` | Open or close the window (Overview) |
| `/kp runs` | Open the run history |
| `/kp progress` | Open the rating graph |
| `/kp goals` | Open the goals with their keys |
| `/kp last` | Reopen the last run's summary |
| `/kp config` | Open the settings |
| `/kp panel` | Turn the floating panel on or off |
| `/kp minimap` | Show or hide the minimap button |
| `/kp popup` | Turn the end-of-key pop-up on or off |
| `/kp lock` | Lock or unlock the floating panel |
| `/kp reset` | Reset the floating panel's position and size |
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
