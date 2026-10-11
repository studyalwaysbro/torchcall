-- Torchcall defaults: the whispers and the class list. Edit the whispers in game on the
-- Message tab; this file is only what a fresh install starts with.
--
-- Tokens: {name} first name, {fullname}, {level}, {class}, {zone}, {guild}.
-- An opener that uses a token the game gave no value for is passed over for that player.
-- The game cuts a chat message at 255 bytes, so every line has to fit with a long name in it.

local _, ns = ...

ns.GUILD_NAME = "The True Torchmen"

-- Short on purpose, and each one is a question. The 1.1 openers read like an advert and one
-- whisper in twenty got an answer. With rotation on, every opener here gets a fair number of
-- sends and then the one that gets the most answers is used most. No links in a first whisper:
-- a link from a stranger reads as a gold seller.
ns.TEMPLATES = {
  "Hey {name}, got a guild yet? <{guild}> is a group of friends leveling together. Want to run a dungeon with us and see if it fits?",
  "Hey {name}, <{guild}> could use another {class}. Friends first, dungeons and world PvP, no application. Interested?",
  "Hi {name}, want a guild invite? <{guild}>: friends first, real life comes first, nobody gets yelled at. Say no and I will not ask again.",
  "Hey {name}, got a guild yet? <{guild}> is friends leveling together. Who we are and how we play: passthetorch.pages.dev  Want an invite?",
}
-- The fourth carries the site so its answer rate can be compared with the three that carry
-- nothing. If it does worse, rotation stops using it by itself.

-- Used in place of an opener for someone you added from your own party or raid.
-- Playing together first is the best reason anyone has to say yes.
ns.GROUP_TEMPLATE = "Good run, {name}. If you want a guild, <{guild}> is a group of friends who level and run dungeons together. Want an invite?"

-- What 1.1 shipped with. A saved message that is still exactly one of these was never edited,
-- so it is swapped for the current one in the same place. Anything you rewrote is left alone.
ns.OLD_TEMPLATES = {
  "Hey {name}, <{guild}> is a friends-first guild on the PvP ruleset. We level in groups, run dungeon nights and are building a casual raid and PvP core for December. No application, no gear check. Want an invite?",
  "Hey {name}, saw you in {zone}. <{guild}> is recruiting: casual, friends first, dungeons and world PvP now, raids in December. Want in?",
  "Hi {name}. Looking for a guild? <{guild}> is small, friendly and levels together in voice. Real life comes first and nobody gets yelled at. Say the word and I will send an invite.",
}

-- The Discord and site line, for someone who answered.
ns.REPLY = "Discord (voice, class guides, craft requests): discord.gg/passthetorch  Site: passthetorch.pages.dev  Type !torch in the Discord and the guild channels open up."
ns.OLD_REPLY = "Welcome aboard. Our Discord has class guides, a craft request board and voice chat: discord.gg/passthetorch  Type !torch in there and the guild channels open up."

-- What the guild window says: the Info text and the message of the day. Torchcall never
-- writes these by itself. /torchcall guild shows what is there now next to these, and
-- /torchcall guild info or /torchcall guild motd writes one of them, if your rank can.
-- Offered only inside the guild named above.
ns.GUILD_INFO = table.concat({
  "The True Torchmen. Whoever is ahead lights the way for whoever is behind.",
  "Friends first, fun first, real life always wins. Leveling groups, dungeon nights, world PvP as a pack, casual raids from December 9.",
  "Discord: discord.gg/passthetorch",
  "Site: passthetorch.pages.dev",
  "New here? Say hi in guild chat and ask anything. Type !torch in the Discord to open the guild channels.",
}, "\n")
ns.GUILD_MOTD = "Welcome, Torchmen. Discord: discord.gg/passthetorch  Site: passthetorch.pages.dev  Ask anything, somebody always knows."

-- Answers for someone who wrote back. One press sends one of them, each goes to a player
-- once, and they can all be rewritten on the Answers tab. "words" are what the addon looks
-- for in a reply to suggest the right one; it only suggests, you press.
-- These describe The True Torchmen. Another guild using this addon should rewrite every one.
ns.ANSWERS = {
  { key = "about", label = "What we are", words = { "what is", "what's", "whats", "about", "who are", "tell me", "more info", "info", "kind of guild", "what kind" },
    text = "The name is the idea: whoever is ahead lights the way for whoever is behind. We are friends who level in small groups, run dungeon nights and never leave anyone to play alone unless they want to." },
  { key = "story", label = "How it started", words = { "how long", "how old", "how big", "how many", "new guild", "started", "story", "history", "members", "size", "who runs", "leader", "gm" },
    text = "We started as one Discord of friends coming back for Forever. The members vote on the big things, the name and the ruleset so far, and OPB leads. It is small on purpose: we grow by people we have actually played with." },
  { key = "life", label = "Time and real life", words = { "time", "times", "schedule", "when", "casual", "hardcore", "kids", "work", "job", "busy", "hours", "timezone", "late", "weekend", "weekends", "active" },
    text = "Real life wins every time. Leave mid dungeon if work or the kids call, nobody keeps score. Events end when we said they would, and if you vanish for three months you come back to a welcome." },
  { key = "raids", label = "Raids", words = { "raid", "raids", "raiding", "raider", "endgame", "end game", "loot", "onyxia", "hyjal", "barrow", "progression", "60" },
    text = "Raids open December 9. We start with Barrow Deeps, the 10 player one, and build up from there at a casual pace. Loot rules are written down before the first pull and nobody gets yelled at for a wipe." },
  { key = "pvp", label = "PvP", words = { "pvp", "gank", "ganked", "ganking", "bg", "bgs", "battleground", "battlegrounds", "wpvp", "world pvp", "arena", "honor", "rank" },
    text = "We chose the PvP ruleset on purpose. We travel as a pack, answer a gank as a guild, and plan premade nights for the new 15 a side battleground once enough of us can queue." },
  { key = "leveling", label = "Leveling and dungeons", words = { "level", "leveling", "levelling", "dungeon", "dungeons", "quest", "quests", "group", "groups", "run", "runs", "help" },
    text = "We level in parties of two or three and do a guild night for each new dungeon as we reach it. There is also one fixed Guild Night a week with no raid: dungeons, world PvP or just voice. Come to what fits." },
  { key = "new", label = "New or returning", words = { "new to", "noob", "newbie", "first time", "never played", "returning", "came back", "rusty", "learning", "application", "apply", "requirements", "gear" },
    text = "No application and no gear check. New people get a named buddy for the first two weeks, so there is always someone to ask. First time in WoW or back after years, both are fine here." },
  { key = "run", label = "Offer a run first", words = { "not sure", "maybe", "think about", "dunno", "idk", "depends", "try" },
    text = "No need to decide now. The easy way to find out is one dungeon with a couple of us, no strings. Want me to set one up, or would you rather just take the invite?" },
  { key = "discord", label = "Discord link", words = { "discord", "voice", "vc", "mic", "link", "site", "website" } },
}
-- The Discord answer is the follow-up line above it in the window, so it has no text here.

-- What a plain yes and a plain no look like in a reply.
ns.SAYS_YES = { "yes", "yeah", "yea", "yep", "yup", "sure", "ok", "okay", "inv", "invite", "invite me", "sounds good", "why not", "im in", "i'm in", "count me in", "please", "pls", "sign me up", "lets go", "let's go", "down" }
ns.SAYS_NO = { "no", "nope", "nah", "no thanks", "no thank you", "not interested", "stop", "leave me alone", "go away", "reported", "report", "spam", "already have", "have a guild", "im good", "i'm good", "pass" }

-- One whisper a few days after someone you recruited joins.
ns.CHECKIN = "Hey {name}, how are you finding <{guild}> so far? If you want a dungeon group or have a question nobody answered, tell me and I will sort it."

-- Said in guild chat by the Welcome button when someone you recruited joins.
ns.WELCOME = "Welcome to <{guild}>, {name}! Glad you are here. Ask anything, somebody always knows."

-- The nine Forever classes, in the order the class button cycles through them.
ns.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
ns.CLASS_NAMES = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
                   SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid" }
