# Torchcall

Guild recruiting for **The True Torchmen** on World of Warcraft: Forever.

It finds players with no guild, opens with one short question, helps you answer what they ask about the guild, and tracks who joined and who stayed. You press a button for every search, every whisper and every invite. It never contacts anyone by itself.

## What it does

- **Search by level and class.** Set a level range and pick any mix of the nine classes. Press Search and it asks the game who is online and keeps the players with no guild. All the classes you picked go out as one search, using the game's own class filter, so the fifty players that come back are the classes you asked for. Optionally limit it to your current zone.
- **It always shows you something.** One who search returns 50 players at most. When more are online, you get the first 50 at once and the rest is lined up as batches (by level, then class, then race): press Search again for the next one. The button counts down the few seconds the game makes you wait between searches.
- **Filters that mean it.** The level range, the classes and the optional Latin-alphabet name filter are applied to every result by the addon itself, not just sent to the server. Change them any time and the list follows. The Next button only ever reaches players who pass them.
- **Prospect list.** Name, level, class, zone. Whisper, Invite or Skip on every row. Press a column title to sort by it.
- **An invite introduces itself.** Invite someone you have not spoken to and they first get your opener as a whisper, then the invite, so the box that pops up on their screen has a reason attached. Still one press, one player, and it counts as one contact. `/torchcall pitch off` goes back to the invite alone.
- **Next button, or a key.** Works down the list, one player per press. Each press is one whisper or one invite, whichever you set it to. Bind it under Options, Keybindings, AddOns.
- **Nobody is asked twice. Ever.** Every name you contact is remembered for good, not for a week. Recruiters in the same guild share who they contacted, so two officers never pitch the same player.
- **Openers that find their own winner.** Four opening whispers ship. Each says who is in the guild (experienced players, casual players, new players), carries the site and the Discord, and ends on a question. With rotation on, every one gets about twenty sends, then the one that gets the most answers is used most, with one send in five still going to the least tried. The Message tab shows sent, answered and joined for each wording.
- **Answers, one press each.** When someone writes back they move to the top, and Reply opens a panel with what they said and a button per topic: what the guild is, how it started, time and real life, raids, PvP, leveling, new players, a dungeon run first, and the Discord and site line. The addon reads their reply and highlights the answer that fits, or tells you it sounds like a yes or a no. Each answer goes to a player once, five at most, and only to someone who wrote to you first. All of them are editable on the Answers tab.
- **Add my group.** One press puts everyone in your party or raid who has no guild at the top of the list, with an opening line written for someone you just played with. Playing together first is the best reason anyone has to say yes.
- **Welcome and check-in.** Everyone who joins lands on the **Joined** tab, with those still owed a hello at the top. A row's **Welcome** button greets that player in guild chat; **Welcome all** greets every recruit of yours still waiting in one line, by name, and has its own key binding. Once per player. A welcome never holds anything else up: the Next key is always the next player. Where the game allows it the welcome is sent by itself when your recruit joins (`/torchcall autowelcome off` leaves it to the buttons). A few days later the row offers a check-in whisper, once. The first week decides who stays.
- **Classes we need.** `/torchcall need healers` (or `tanks`, or class names). Those players come first on the list, are marked, and get an opener that says the guild is short a Priest, not a generic pitch.
- **What works where.** Every contact is counted by level band, class and hour of the day. `/torchcall stats` names the band, class and hour that answer and join most, once there are ten contacts to go on.
- **Recruiters' board.** `/torchcall board` ranks every recruiter in the guild running Torchcall: joined this week, all time, and still here a week later.
- **Nobody left hanging.** At login it tells you who answered and is still waiting on you. `/torchcall warm` lists them, longest wait first.
- **A horn when they join.** Your recruit accepts: a horn, and their name across your screen.
- **The first week.** For each recruit: in the Discord, said hello in guild chat, grouped with you. The last two are noticed by the addon, the first you tick with `/torchcall step <name> discord`. `/torchcall recruits` shows all three, and the check-in whisper carries the Discord link for anyone who has not joined it.
- **Who stayed.** When the guild roster loads, recruits who joined at least a week ago are marked as still here or gone. The Answers tab shows invites after a conversation next to invites with no conversation: how many were accepted and how many were still in the guild a week later.
- **Guild window texts.** `/torchcall guild` shows the guild Info text and message of the day next to a version with the Discord and the site in it, and writes one on command if your rank can. It never writes them by itself.
- **Results.** Joins and declines are read from the game's own messages and counted.
- **Limits.** 30 new people an hour, 100 a day and 4 seconds between whispers by default. `/torchcall cap` changes the hourly number, up to 60. `/torchcall cap day 300` changes the daily one and `/torchcall cap day off` removes it. These are the addon's own brakes, not the game's: the game may still act on an account that gets reported for spam.
- **Only its own searches.** A who search you type yourself never puts anyone on the list. If one goes out while Torchcall is waiting for an answer, Torchcall throws its own search back on the queue instead of guessing whose answer arrived.
- **Your words.** Every message is editable in game with a live character count. Tokens: `{name} {fullname} {level} {class} {zone} {guild}`.

## What it will not do

There is no "invite all", no "send to everyone", no hands-free mode that turns your normal clicks into invites, and no timer. Those are the features that get recruiters reported. One press reaches one player (an invite to someone new is that player's opener and their invite, nothing more). The hourly limit and the gap between whispers cannot be switched off; the daily limit is yours to set. That includes the guild-chat welcome: the game itself refuses chat an addon sends without a press.

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
| `/torchcall group` | Add everyone in your party or raid who has no guild |
| `/torchcall answer raids <name>` | One answer to someone who wrote back |
| `/torchcall checkin <name>` | Check in on a recruit who joined a few days ago |
| `/torchcall rotate` | Try every opener and lean on the best, on or off |
| `/torchcall guild` | The guild Info text and message of the day |
| `/torchcall stats` | Totals and what is working |
| `/torchcall skip <name>` | Never contact this player |
| `/torchcall cap <number>` | New people per hour |
| `/torchcall cap day <number or off>` | New people per day, or no daily limit |
| `/torchcall pitch` | Whisper the opener before an invite to someone new, on or off |
| `/torchcall need <classes>` | Classes the guild is short of: `healers`, `tanks`, class names, `off` |
| `/torchcall warm` | Who answered and is still waiting on you |
| `/torchcall board` | Recruiters this week |
| `/torchcall recruits` | Your recruits and their first week |
| `/torchcall step <name> discord` | Tick a first-week step |
| `/torchcall help` | The rest |

## Is this allowed?

Torchcall reads what the game gives every addon and sends ordinary whispers and guild invites, the same ones you could type. It does not automate them: there is no timer, no loop and no way to make it work through a list by itself. Blizzard publishes no approved list for Forever addons and can disable any addon at any time. How many strangers you whisper is still on you. Be the recruiter you would want to hear from.

## Using it for another guild

The openers use `{guild}`, so they work anywhere. The answers describe The True Torchmen: rewrite each one on the Answers tab, or edit `Data.lua`. The guild window texts are only offered inside the guild named in `Data.lua`.

## Tests

With Lua 5.1, from this folder:

- `lua tests/run.lua` runs the scenario suite.
- `lua tests/fuzz.lua 2500 300` plays 2,500 random recruiting sessions (750,000 random presses, replies, joins, lockdowns, reloads and two-month absences) and checks after every step that no promise above was broken: nothing sent outside a press, nobody contacted twice, every limit held, Next never reaching anyone outside the filters. Records are kept outside the addon, so it cannot mark its own homework. The soak itself was checked by planting 25 different bugs in the addon, one at a time; it caught all 25. For 1.2 another 13 were planted in the new code and it caught 12; the thirteenth, the cap of five answers per player, is covered by the scenario suite.

## Status

Built against Blizzard's Forever interface source, build 1.60.1. Searches, whispers, invites and join tracking have been used in the Forever beta. Everything new in 1.2 (answers, rotation, Add my group, check-ins, who stayed, guild window texts) passes the offline suite and has not been run in the game yet. If something breaks, `/torchcall log` shows what the addon saw.

Made by **The True Torchmen**. MIT license.
