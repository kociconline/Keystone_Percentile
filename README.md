# M+ Percentile

Shows where your Mythic+ rating ranks, chess.com style, across several groups at once:

```
3,300  M+ rating, US
Overall             Top 8.6%   ~#60,384 / 700,211
Healer              Top 7.9%   ~#13,415 / 169,016
Paladin             Top 8.2%   ~#5,775 / 70,000
Holy                Top 7.3%   ~#1,838 / 25,000
Herald of the Sun   —          no ranking data
```

Hover over the panel to see how many points you need to reach the next bracket in each group.

## Where the numbers come from

WoW addons can't go online, so `tools/update_data.py` downloads the data from Raider.IO's public API and writes it to `Data.lua`:

- **Cutoffs and population** for the top 0.1 / 1 / 5 / 10 / 25 / 40% of every region, separately for overall, each role, each class and each spec. Your percentile is interpolated between those points on a log scale.
- **Exact ranks** (optional) for characters listed in `tools/characters.json`. While your in-game score still matches the downloaded score, the panel shows your real Raider.IO rank (green `#rank`) instead of an estimate (`~#rank`).

Your rating, role, class, spec and hero talent are read live in game, so switching spec or finishing a key updates the panel right away.

**Hero talents:** Raider.IO doesn't rank Mythic+ rating by hero talent, and neither does any other public source, so that row shows only the name. If such data appears later, it can be added the same way.

## Install

1. Copy the `MPlusPercentile` folder to `World of Warcraft/_retail_/Interface/AddOns/`.
2. With Python 3 installed, run:
   ```
   python Interface/AddOns/MPlusPercentile/tools/update_data.py --regions eu
   ```
   Leave out `--regions` to download all regions.
3. Type `/reload` in game.

Optional: copy `tools/characters.example.json` to `tools/characters.json`, list your characters, and run the script again to get exact ranks.

Rerun the script every day or two, or schedule it. The panel warns you when the data is over 7 days old.

## Commands

| Command | Effect |
|---|---|
| `/mpp` | Print every row in chat |
| `/mpp hide` / `show` | Toggle the panel |
| `/mpp lock` | Lock or unlock dragging |
| `/mpp reset` | Reset the panel position |
| `/mpp tooltips` | Toggle overall and class "Top X%" on player tooltips |
| `/mpp region eu` | Force a region (`auto` to undo) |

## Publishing (CurseForge, Wago, WoWInterface)

Releases are built by the BigWigs packager on GitHub Actions:

- `daily-data.yml` runs every day at 08:23 UTC. If Raider.IO's numbers changed, it commits the new `Data.lua`, tags `vX.Y.Z-data.YYYYMMDD` and uploads to every site.
- `release.yml` runs when you push a version tag yourself (for example `v2.1.0`) after changing code.

One-time setup:

1. Push this folder to a GitHub repository.
2. Create the project on [CurseForge](https://authors.curseforge.com), [Wago](https://addons.wago.io) and/or [WoWInterface](https://www.wowinterface.com). Add each ID to `MPlusPercentile.toc`:
   ```
   ## X-Curse-Project-ID: 123456
   ## X-Wago-ID: abcdEFGH
   ## X-WoWI-ID: 98765
   ```
   Leave out any site you don't use.
3. Create an API token on each site and add it to the GitHub repository under Settings > Secrets and variables > Actions as `CF_API_KEY`, `WAGO_API_TOKEN` and `WOWI_API_TOKEN`.
4. Under Settings > Actions > General, set workflow permissions to "Read and write".
5. Push a first tag: `git tag v2.0.0 && git push origin v2.0.0`.
