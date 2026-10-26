# M+ Percentile

**See where you rank in Mythic+, chess.com style:** your rating as "Top X%" overall, by role, by class and by spec, plus how your DPS ranks in every key you run.

## Rating percentiles

```
3,300  M+ rating, EU
Overall    Top 8.6%   ~#60,384 / 700,211
Healer     Top 7.9%   ~#13,415 / 169,016
Paladin    Top 8.2%   ~#5,775 / 70,000
Holy       Top 7.3%   ~#1,838 / 25,000
```

- Top % overall, by role, by class and by spec, for your region
- Your approximate ladder position in each group
- Hover to see how many points you need for the next bracket
- Updates instantly after every key and when you change spec

## DPS in every key

- **End-of-key pop-up:** your DPS and your Top X% among Warcraft Logs players of your spec, in that dungeon, at that key level
- **See the gap:** a bar from 0 to the #1 run with the 50/25/10/1% marks, and how much more DPS each goal needs
- **Run history:** every key you've run, filterable by season, dungeon and spec, sortable by date, rank or DPS. Click any run to reopen its summary.
- **Your old logs too:** with the optional script, every run you've uploaded to Warcraft Logs is imported with its official rank

## Commands

`/mpp runs` opens your run history, `/mpp last` reopens the last summary, and `/mpp` prints your rating percentiles. Options: `hide`, `show`, `lock`, `reset`, `tooltips`, `popup`, `region`.

## Data

Fresh data is built into every release, daily. Rating data comes from the public [Raider.IO](https://raider.io) API, and DPS benchmarks from the [Warcraft Logs](https://www.warcraftlogs.com) API. Thanks to both. This addon isn't affiliated with Raider.IO, Warcraft Logs or Blizzard.

DPS benchmarks compare you with players who upload logs, who skew toward the more dedicated end, so "Top 50%" here is a higher bar than on the rating ladder. Hero talents aren't ranked by any public source yet.
