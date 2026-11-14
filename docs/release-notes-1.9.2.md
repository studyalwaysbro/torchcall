**Torchcall 1.9.2 stops searches from going in circles.**

When one level and class showed more players than a single search can list, Torchcall split that search by race. It used every race in the game, so it went looking for Tauren and Orc priests, which do not exist. The game never answered those searches, and Torchcall sent the same one again every time you pressed Continue.

Race splits now only use races that can actually be that class on Forever, taken from the game's own data. That keeps the combinations Forever added, like Undead paladins, Gnome priests and the Skyborne.

A search the game never answers is now tried once more, then skipped, so the list always moves on.

**How to update:** on CurseForge, hit Update. With Yeeterson Forge it arrives by itself. By hand: download the zip below, close the game fully, replace the `Torchcall` folder in `_forever_/Interface/AddOns/`. Your prospects, stats and settings are kept.
