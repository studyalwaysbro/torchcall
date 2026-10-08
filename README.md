# Torchcall

Guild recruiting for **The True Torchmen** on World of Warcraft: Forever.

It finds players with no guild, keeps them on a list, and whispers or invites them one at a time. You press a button for every search, every whisper and every invite. It never contacts anyone by itself.

## What it does

- **Search by level and class.** Set a level range and pick any mix of the nine classes. Press Search and it asks the game who is online and keeps the players with no guild. Optionally limit it to your current zone.
- **It gets through a crowded server.** One who search returns 50 players at most. A full answer is split by level, then by class, then by race, so busy levels are still covered. Each search needs its own press.
- **Filters that mean it.** The level range, the classes and the optional Latin-alphabet name filter are applied to every result by the addon itself, not just sent to the server. Change them any time and the list follows. The Next button only ever reaches players who pass them.
- **Prospect list.** Name, level, class, zone. Whisper, Invite or Skip on every row. Press a column title to sort by it.
- **Next button, or a key.** Works down the list, one player per press. Each press is one whisper or one invite, whichever you set it to. Bind it under Options, Keybindings, AddOns.
- **Nobody is asked twice. Ever.** Every name you contact is remembered for good, not for a week. Recruiters in the same guild share who they contacted, so two officers never pitch the same player.
- **Answers float to the top.** When someone whispers back they are marked ANSWERED, and the Link button sends them the Discord line. Once, and only to people who answered.
- **Which message works.** Write up to three opening whispers. The Message tab shows how many times each wording was sent, how many people answered and how many joined, so you keep the one that works. Reword a message and its count starts fresh.
- **Welcome button.** When someone you recruited joins, one press says hello in guild chat. Once per player.
- **Results.** Joins and declines are read from the game's own messages and counted.
- **Limits.** 30 new people an hour, 100 a day and 4 seconds between whispers by default. `/torchcall cap` changes the hourly number, up to 60.
- **Only its own searches.** A who search you type yourself never puts anyone on the list. If one goes out while Torchcall is waiting for an answer, Torchcall throws its own search back on the queue instead of guessing whose answer arrived.
- **Your words.** Every message is editable in game with a live character count. Tokens: `{name} {fullname} {level} {class} {zone} {guild}`.

## What it will not do

There is no "invite all", no "send to everyone", no hands-free mode that turns your normal clicks into invites, and no timer. Those are the features that get recruiters reported. One press reaches one player, and the limits above cannot be switched off.

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
| `/torchcall class mage priest` | Only these classes (`class all` to clear) |
| `/torchcall level 20-40` | Only this level range |
| `/torchcall next` | Whisper or invite the next player |
| `/torchcall stats` | Totals |
| `/torchcall skip <name>` | Never contact this player |
| `/torchcall cap <number>` | New people per hour |
| `/torchcall help` | The rest |

## Is this allowed?

Torchcall reads what the game gives every addon and sends ordinary whispers and guild invites, the same ones you could type. It does not automate them: there is no timer, no loop and no way to make it work through a list by itself. Blizzard publishes no approved list for Forever addons and can disable any addon at any time. How many strangers you whisper is still on you. Be the recruiter you would want to hear from.

## Tests

With Lua 5.1, from this folder:

- `lua tests/run.lua` runs the scenario suite.
- `lua tests/fuzz.lua 2500 300` plays 2,500 random recruiting sessions (750,000 random presses, replies, joins, lockdowns, reloads and two-month absences) and checks after every step that no promise above was broken: nothing sent outside a press, nobody contacted twice, every limit held, Next never reaching anyone outside the filters. Records are kept outside the addon, so it cannot mark its own homework. The soak itself was checked by planting 25 different bugs in the addon, one at a time; it caught all 25.

## Status

Built against Blizzard's Forever interface source, build 1.60.1 (70245), and reviewed against it twice by a second pair of eyes. Passes its offline suite. Not yet run inside the game, and the guild invite cannot be tried until a guild exists on launch night. If something breaks, `/torchcall log` shows what the addon saw.

Made by **The True Torchmen**. MIT license.
