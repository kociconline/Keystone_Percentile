# M+ Percentile

**See where you rank in Mythic+, chess.com style.** Not just "Top 8%" overall, but also among your role, your class and your spec.

```
3,300  M+ rating, EU
Overall    Top 8.6%   ~#60,384 / 700,211
Healer     Top 7.9%   ~#13,415 / 169,016
Paladin    Top 8.2%   ~#5,775 / 70,000
Holy       Top 7.3%   ~#1,838 / 25,000
```

## Features

- **Top % overall, by role, by class and by spec**, for your own region
- **Your approximate ladder position** in each group
- **Next goal:** hover the panel to see how many points you need for the next bracket in each group
- **Updates instantly** after every key and when you change spec
- **Player tooltips** show overall and class percentile for groupmates
- **Fresh data every day**, built into each release. No setup and no extra programs.
- Small, movable, lockable panel

## Commands

`/mpp` prints everything in chat. `/mpp hide`, `show`, `lock`, `reset`, `tooltips`, and `region <us/eu/kr/tw/auto>`.

## Exact ranks (optional)

Releases contain the ladder for all regions, so percentiles are estimated from your live rating. For your exact Raider.IO rank in every row, list your characters in `tools/characters.json` and run `tools/update_data.py` (needs Python 3).

## Data

Ladder data comes from the public [Raider.IO](https://raider.io) API. Thanks to Raider.IO for publishing it. This addon isn't affiliated with Raider.IO or Blizzard.

Hero talents aren't ranked by any public source yet, so the hero talent row shows only the name.
