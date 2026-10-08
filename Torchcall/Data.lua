-- Torchcall defaults: the whispers and the class list. Edit the whispers in game on the
-- Message tab; this file is only what a fresh install starts with.
--
-- Tokens: {name} first name, {fullname}, {level}, {class}, {zone}, {guild}.
-- The game cuts a chat message at 255 bytes, so every line has to fit with a long name in it.

local _, ns = ...

ns.GUILD_NAME = "The True Torchmen"

ns.TEMPLATES = {
  "Hey {name}, <{guild}> is a friends-first guild on the PvP ruleset. We level in groups, run dungeon nights and are building a casual raid and PvP core for December. No application, no gear check. Want an invite?",
  "Hey {name}, saw you in {zone}. <{guild}> is recruiting: casual, friends first, dungeons and world PvP now, raids in December. Want in?",
  "Hi {name}. Looking for a guild? <{guild}> is small, friendly and levels together in voice. Real life comes first and nobody gets yelled at. Say the word and I will send an invite.",
}

-- Sent with the Link button to someone who answered.
ns.REPLY = "Welcome aboard. Our Discord has class guides, a craft request board and voice chat: discord.gg/passthetorch  Type !torch in there and the guild channels open up."

-- Said in guild chat by the Welcome button when someone you recruited joins.
ns.WELCOME = "Welcome to <{guild}>, {name}! Glad you are here. Ask anything, somebody always knows."

-- The nine Forever classes, in the order the class button cycles through them.
ns.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
ns.CLASS_NAMES = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
                   SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid" }
