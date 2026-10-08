# Torchcall

Guild recruiting for **The True Torchmen** on World of Warcraft: Forever.

It finds players with no guild, keeps them on a list, and whispers or invites them one at a time. You press a button for every search, every whisper and every invite. It never contacts anyone by itself.

## What it does

- **Search.** Pick a level range, optionally a class or "my zone only", and press Search. It asks the game who is online and keeps the players with no guild. One search returns at most 50 players, so a busy range is split into smaller searches. Each one needs its own press.
- **Prospect list.** Name, level, class, zone. Whisper, Invite or Skip on every row.
- **Next button.** Works down the list, one player per press. Each press is one whisper or one invite, whichever you set it to.
- **Nobody is asked twice.** Everyone you contact is remembered for 60 days, and anyone who declines or whom you skip is remembered for good. Recruiters in the same guild share who they contacted, so two officers never pitch the same player.
- **Answers float to the top.** When someone whispers back they are marked ANSWERED, and the Link button sends them the Discord line. Once, and only to people who answered.
- **Results.** Joins and declines are read from the game's own messages and counted.
- **Limits.** 30 new people an hour, 100 a day and 4 seconds between whispers by default. `/torchcall cap` changes the hourly number, up to 60.
- **Only its own searches.** A who search you type yourself never puts anyone on the list.
- **Your words.** Three opening whispers and one follow-up, editable on the Message tab with a live character count. Tokens: `{name} {fullname} {level} {class} {zone} {guild}`.

## Install

1. Download **Torchcall-x.y.z.zip** from the [latest release](../../releases/latest) and unzip it. You get a folder called `Torchcall`.
2. Move that folder into `World of Warcraft/_classic_beta_/Interface/AddOns/`
   (after launch the folder may have a different name than `_classic_beta_`; use whichever one has your Forever `Interface` folder).
3. Fully restart the game and tick **Torchcall** on the AddOns screen.
4. Type `/torchcall`.

On Linux with [Yeeterson Forge](https://github.com/studyalwaysbro/yeeterson-forge): `yforge add github:studyalwaysbro/torchcall`.

## Commands

| Command | What it does |
|---|---|
| `/torchcall` or `/tcall` | Open the window |
| `/torchcall search 10-20` | Search a level range |
| `/torchcall search` | Send the next queued search |
| `/torchcall next` | Whisper or invite the next player |
| `/torchcall stats` | Totals |
| `/torchcall skip <name>` | Never contact this player |
| `/torchcall cap <number>` | New people per hour |
| `/torchcall help` | The rest |

## Is this allowed?

Torchcall reads what the game gives every addon and sends ordinary whispers and guild invites, the same ones you could type. It does not automate them: there is no timer, no loop and no way to make it work through a list by itself. Blizzard publishes no approved list for Forever addons and can disable any addon at any time. How many strangers you whisper is still on you. Be the recruiter you would want to hear from.

## Tests

`lua tests/run.lua` from this folder, with Lua 5.1.

## Status

Built against Blizzard's Forever interface source, build 1.60.1 (70245), and reviewed against it by a second pair of eyes. Passes its offline suite. Not yet run inside the game, and the guild invite cannot be tried until a guild exists on launch night. If something breaks, `/torchcall log` shows what the addon saw.

Made by **The True Torchmen**. MIT license.
