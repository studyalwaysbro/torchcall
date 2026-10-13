-- Soak test: lua tests/fuzz.lua [sessions] [steps] [seed]   (from the project root, Lua 5.1)
--
-- Plays random recruiting sessions against the mock client: searches answered with random
-- players (some guilded, some with secret fields, some with non-Latin names), random presses
-- of every button, key and slash command, random replies, joins, declines, guild sync
-- traffic, lockdowns, refused calls, long idle gaps and relogs. After every step it checks
-- the promises the addon makes, from records kept outside the addon:
--   * nothing reaches a player except during a press, and one press sends at most one thing
--   * nobody gets the opening whisper twice, a guild invite twice, the follow-up twice,
--     or the follow-up without having answered; nobody is welcomed twice or before joining
--   * the hourly and daily limits, the whisper gap and the who gap always hold
--   * the Next button only reaches players who pass the level, class and alphabet filters
--   * an answer only ever goes to someone who wrote back, each topic once, five at most;
--     a check-in only to a recruit who joined at least two days ago, once; the line for
--     people you played with only to someone who really was in your group
--   * reading the guild roster or adding your group never sends anything to anyone
--   * no handler ever raises an error, and the saved data stays plain and bounded
package.path = "tests/?.lua;" .. package.path
local M = require("mock")
local SESSIONS, STEPS, SEED = tonumber(arg[1]) or 300, tonumber(arg[2]) or 250, tonumber(arg[3]) or 20261008
math.randomseed(SEED)
local R = math.random
local function pick(t) return t[R(#t)] end
local function chance(p) return R() < p end

local FILES = { "Data.lua", "Core.lua", "Comm.lua", "UI.lua" }
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local FIRST = { "Bob", "Ann", "Cy", "Dee", "Eli", "Fay", "Gus", "Hal", "Ivy", "Jon", "Kit", "Lou", "Moe", "Ned", "Oda", "Pat",
                "Se\195\177ora", "\208\152\208\178\208\176\208\189", "\236\157\180\236\136\156", "Zo\195\171", "O'Neil", "X" }
local LAST = { "Smith", "Lee", "Dunn", "Fox", "Gant", "Holt", "Ives", "Jett", "Kerr", "Lowe", "Mann", "Nash", "Orr", "Quill",
               "Stone", "Thunderbluffson", "\208\159\208\181\209\130\209\128\208\190\208\178", "de la Cruz" }
local GUILDS = { "", "", "", "", "OLYMPUS", "Some Guild", "The True Torchmen" }
local ZONES = { "Durotar", "The Barrens", "Orgrimmar", "Stranglethorn Vale", "Zephras Isle" }
local JUNK = { "", " ", "x", "|", ";;;", "C;1", "L;1;abcdef;", "C;2;abcdef;Bob Smith", string.rep("z", 300), "%s", "{name}", "1-", "-5", "999" }

local NONLATIN = { ["\208\152\208\178\208\176\208\189"] = true, ["\236\157\180\236\136\156"] = true,
                   ["\208\159\208\181\209\130\209\128\208\190\208\178"] = true }
local theirs = 0
local world = {} -- [name] = what the game last said about that player in an answer to one of our searches
local ns, db
local totals = { steps = 0, whispers = 0, followups = 0, invites = 0, welcomes = 0, searches = 0, relogs = 0, wipes = 0, blocked = 0,
                 answers = 0, checkins = 0, groupOpeners = 0 }
local TOPICS = { "about", "story", "life", "raids", "pvp", "leveling", "new", "run" }

-- records kept outside the addon ------------------------------------------------
local rec
local function freshRecords()
  rec = { opened = {}, invited = {}, linked = {}, welcomed = {}, replied = {}, joined = {}, contacts = {},
          answered = {}, joinedAt = {}, checked = {}, grouped = {}, lastWhisper = -1e9, lastWho = -1e9 }
end
freshRecords()

local inAction, sends, viaNext = false, 0, false
-- The addon wraps its game calls in pcall, so a broken promise is written down here and
-- raised by the check after the step, where nothing can swallow it.
local broken
local function fail(msg)
  broken = broken or ("PROMISE BROKEN: " .. msg)
  error(broken, 0)
end

local lastKind, lastTarget
M.guard = function(kind, target, msg)
  -- the one thing that may go out by itself: the guild-chat welcome for your own recruit, with that setting on
  local own = kind == "GUILD" and not inAction and db.opts.autowelcome
  if not inAction and not own then fail(kind .. " sent outside a press, to " .. tostring(target)) end
  if not own then sends = sends + 1 end
  -- the one pair a press may send: the opener, then the invite, to the same player, with that setting on
  local pair = sends == 2 and kind == "INVITE" and lastKind == "WHISPER" and lastTarget == target and db.opts.pitch
  if sends > 1 and not pair and not own then fail("one press sent more than one thing (" .. kind .. ")") end
  if not own then lastKind, lastTarget = kind, target end
  local o = db.opts
  if kind == "who" then
    if time() - rec.lastWho < 5 then fail("who searches closer than 5 seconds") end
    rec.lastWho = time()
    totals.searches = totals.searches + 1
    return
  end
  if kind == "GUILDTEXT" then -- the guild window's own text: only ever from a typed command, only with the rank
    if not M.inGuild then fail("guild text written with no guild") end
    if (target == "info" and not M.canEditInfo) or (target == "motd" and not M.canEditMotd) then fail("guild text written without the rank") end
    return
  end
  if M.lockdown and kind ~= "INVITE" then fail("chat sent during a lockdown") end
  local p = db.prospects[target]
  if type(target) == "string" and target:find("^Theirs ") then fail("reached someone from a who search that was not ours: " .. target) end
  local function firstContact()
    local now, hour = time(), 0
    for i = #rec.contacts, 1, -1 do
      if now - rec.contacts[i] >= 86400 then table.remove(rec.contacts, i)
      elseif now - rec.contacts[i] < 3600 then hour = hour + 1 end
    end
    if hour >= o.hourly then fail("hourly limit exceeded: " .. hour .. " of " .. o.hourly) end
    if o.daily > 0 and #rec.contacts >= o.daily then fail("daily limit exceeded") end
    if not p or p.status ~= "new" then fail("first contact with someone not waiting: " .. tostring(target)) end
    if now - (p.seen or 0) > 12 * 3600 then fail("first contact with someone last seen over 12 hours ago") end
    if viaNext and not rec.grouped[target] then -- someone from your own group is exempt from the filters, by design
      -- judged from what the game last said about this player and the filters as set, not by asking the addon
      local raw = world[target]
      if not raw then fail("Next reached someone no search of ours ever returned: " .. target) end
      local ranged = o.lo > 1 or o.hi < 60
      if ranged and (type(raw.level) ~= "number" or raw.level < o.lo or raw.level > o.hi) then
        fail(("Next reached level %s with the range %d-%d: %s"):format(tostring(raw.level), o.lo, o.hi, target))
      end
      local picked, all = 0, 0
      for _, c in ipairs(CLASSES) do all = all + 1; if o.classes[c] then picked = picked + 1 end end
      if picked > 0 and picked < all and not (raw.class and o.classes[raw.class]) then
        fail("Next reached a " .. tostring(raw.class) .. " outside the picked classes: " .. target)
      end
      if o.latin and NONLATIN[(target:match("^(%S+)"))] then fail("Next reached a non-Latin name with the Latin filter on: " .. target) end
      if o.latin and NONLATIN[(target:match("%s(.+)$"))] then fail("Next reached a non-Latin name with the Latin filter on: " .. target) end
    end
    if target == M.myName then fail("contacted yourself") end
    rec.contacts[#rec.contacts + 1] = now
  end
  if kind == "WHISPER" then
    if time() - rec.lastWhisper < o.gap then fail("whispers closer than the gap") end
    rec.lastWhisper = time()
    local topic = msg:match("^ANS:(%a+)")
    if topic then
      if not rec.replied[target] then fail("answer to someone who never wrote back: " .. target) end
      if not (rec.opened[target] or rec.invited[target]) then fail("answer to someone never contacted: " .. target) end
      local had = rec.answered[target] or {}
      if had[topic] then fail("answer '" .. topic .. "' sent twice to " .. target) end
      local count = rec.linked[target] and 1 or 0
      for _ in pairs(had) do count = count + 1 end
      if count >= 5 then fail("more than five answers to " .. target) end
      had[topic] = true
      rec.answered[target] = had
      totals.answers = totals.answers + 1
    elseif msg:find("^CHECKIN") then
      if not rec.joinedAt[target] then fail("check-in to someone who never joined: " .. target) end
      if time() - rec.joinedAt[target] < 2 * 86400 then fail("check-in less than two days after joining: " .. target) end
      if rec.checked[target] then fail("check-in sent twice to " .. target) end
      rec.checked[target] = time()
      totals.checkins = totals.checkins + 1
    elseif msg:find("^FOLLOWUP") then
      if not rec.replied[target] then fail("follow-up to someone who never answered: " .. target .. " :: " .. msg) end
      if rec.linked[target] then fail("follow-up sent twice to " .. target) end
      rec.linked[target] = true
      totals.followups = totals.followups + 1
    else
      if msg:find("^GROUP") then
        if not rec.grouped[target] then fail("played-together line to someone never in your group: " .. target) end
        totals.groupOpeners = totals.groupOpeners + 1
      end
      if rec.opened[target] then fail("opening whisper sent twice to " .. target) end
      if not rec.invited[target] then firstContact() elseif not p or p.status ~= "new" then fail("whisper after an invite") end
      rec.opened[target] = true
      totals.whispers = totals.whispers + 1
    end
  elseif kind == "INVITE" then
    if not M.inGuild or not M.canInvite then fail("invite without a guild or the rank") end
    if rec.invited[target] then fail("guild invite sent twice to " .. target) end
    if not rec.opened[target] then firstContact() end
    rec.invited[target] = true
    totals.invites = totals.invites + 1
  elseif kind == "GUILD" then
    -- the welcome line names its player by first name; it must be someone who joined and was not welcomed yet
    local who
    for name in pairs(rec.joined) do
      if not rec.welcomed[name] and target:find((name:match("^(%S+)")), 1, true) then who = name break end
    end
    if not who then fail("guild chat line that welcomes nobody new: " .. target) end
    rec.welcomed[who] = true
    totals.welcomes = totals.welcomes + 1
  else
    fail("unexpected chat channel " .. tostring(kind))
  end
end

local function press(fn, ...)
  inAction, sends = true, 0
  local ok, err = pcall(fn, ...)
  inAction, viaNext = false, false
  if not ok then error(err, 0) end
end

-- the world ---------------------------------------------------------------------
local function randomName() return pick(FIRST) .. " " .. pick(LAST) end
local function randomPlayer()
  local class = pick(CLASSES)
  local info = { fullName = randomName(), fullGuildName = pick(GUILDS), level = R(1, 60), raceStr = pick({ "Orc", "Troll", "Tauren", "Undead" }),
                 classStr = class:sub(1, 1) .. class:sub(2):lower(), area = pick(ZONES), filename = class, gender = R(2, 3) }
  if chance(0.03) then info[pick({ "fullName", "fullGuildName", "level", "filename", "area", "raceStr", "classStr" })] = M.secret() end
  if chance(0.01) then info.filename = nil end
  if chance(0.01) then info.level = 0 end
  return info
end
local function knownName(status)
  local names = {}
  for name, p in pairs(db.prospects) do
    if not status or p.status == status then names[#names + 1] = name end
  end
  if #names == 0 or chance(0.1) then return randomName() end
  return pick(names)
end
local function contactedName()
  return knownName(pick({ "whispered", "whispered", "invited", "invited", "joined" }))
end

local function login(wipe)
  M.reset(wipe)
  if wipe then freshRecords(); world = {}; totals.wipes = totals.wipes + 1 end
  M.whoMode = pick({ "text", "text", "exclude", "include", "local", false }) or nil -- every way a search can ask for classes
  ns = M.load(os.getenv("TORCHCALL_DIR") or "Torchcall", FILES)
  M.fire("ADDON_LOADED", "Torchcall")
  M.fire("PLAYER_LOGIN")
  db = TorchcallDB
  -- lines the guard can tell apart from an opener
  for _, key in ipairs(TOPICS) do db.answers[key] = "ANS:" .. key .. " for {name}" end
  db.checkin, db.groupmsg = "CHECKIN {name}", "GROUP {name}"
  db.reply = "FOLLOWUP discord.gg/passthetorch" -- the openers carry the link too, so the follow-up is told apart by this
  if wipe then M.advance(30) end -- fresh data has no memory of the last whisper; a real wipe is never that fast
  totals.relogs = totals.relogs + 1
end

local function answer()
  local n = pick({ 0, 1, 3, 8, 20, 50, 50 })
  local list = {}
  for i = 1, n do list[i] = randomPlayer() end
  local total = (n == 50 and chance(0.7)) and R(51, 400) or n
  if chance(0.03) then total = M.secret() end
  M.who, M.whoTotal = list, total
  if ns.SearchPending() then
    for _, info in ipairs(list) do
      local name = info.fullName
      if not issecretvalue(name) then
        local old = world[name] or {}
        local level, class = info.level, info.filename
        -- a field the game hides this time leaves what an earlier answer said
        world[name] = { level = (not issecretvalue(level) and type(level) == "number" and level > 0) and level or old.level,
                        class = (not issecretvalue(class) and class) or old.class }
      end
    end
  end
  M.fire("WHO_LIST_UPDATE")
end

local SLASH = { "", "help", "stats", "search", "search 1-60", "search 10-20", "search 60", "next", "cap 5", "cap 30", "cap 60", "cap 9999", "cap day 5", "cap day off", "cap day 100", "cap day x", "cap day 99999", "need healers", "need tanks mage", "need off", "need", "need wizards", "board", "recruits", "warm", "step", "step Nobody discord",
                "class mage", "class all", "class warrior priest rogue", "level 1-60", "level 20-40", "level 60-1", "clear", "minimap", "log",
                "skip", "forget", "welcome", "bogus", "group", "rotate", "answer", "answer raids", "answer bogus", "answer discord", "checkin", "guild", "guild info", "guild motd", "guild zz" }

local STEP = {
  function() M.advance(R() * 8) end,
  function() M.advance(R() * 8) end,
  function() M.advance(R(1, 90)) end,
  function() if chance(0.15) then M.advance(R(600, 4000)) end end,
  function() if chance(0.02) then M.advance(13 * 3600) end end,
  function() press(ns.StartSearch, R(1, 60), R(1, 60), chance(0.2) and pick(ZONES) or nil) end,
  function() press(ns.NextSearch) end,
  function() press(Torchcall_KeySearch) end,
  function() if ns.SearchPending() and chance(0.9) then answer() end end,
  function() if ns.SearchPending() then answer() end end,
  function() if chance(0.2) then answer() end end, -- an answer nobody asked for
  function() -- somebody else's who search goes out, and its answer comes back
    if not chance(0.3) then return end
    if not pcall(C_FriendList.SendWho, "someone else's search", 2) then return end -- refused: no answer comes
    local list = {}
    for i = 1, R(1, 6) do
      theirs = theirs + 1
      list[i] = { fullName = "Theirs " .. theirs, fullGuildName = "", level = R(1, 60), raceStr = "Orc", classStr = "Mage", area = "Durotar", filename = "MAGE", gender = 2 }
    end
    M.who, M.whoTotal = list, #list
    M.fire("WHO_LIST_UPDATE")
  end,
  function() -- away for two months, then back
    if not chance(0.02) then return end
    M.advance(61 * 86400)
    login(false)
  end,
  function() if chance(0.05) then WhoFrame = chance(0.5) and M.newFrame("Frame", "WhoFrame") or nil end end,
  function() viaNext = true; press(ns.Next) end,
  function() viaNext = true; press(ns.Next) end,
  function() viaNext = true; press(Torchcall_KeyNext) end,
  function() viaNext = true; press(SlashCmdList["TORCHCALL"], "next") end,
  function() press(ns.Whisper, knownName()) end,
  function() press(ns.Whisper, contactedName(), true) end,
  function() press(ns.Whisper, contactedName(), true) end,
  function() press(ns.Invite, knownName()) end,
  function() press(ns.Invite, knownName("whispered")) end,
  function() press(ns.Welcome, knownName()) end,
  function() press(ns.Welcome, knownName("joined")) end,
  function() press(ns.WelcomeAll) end,
  function() press(Torchcall_KeyWelcome) end,
  function() press(ns.Skip, knownName()) end,
  function() if chance(0.3) then press(ns.Forget, knownName()) end end,
  function() ns.ToggleClass(chance(0.25) and nil or pick(CLASSES)) end,
  function() ns.SetLevels(R(1, 60), R(1, 60)) end,
  function() if chance(0.3) then ns.SetLevels(1, 60); ns.ToggleClass(nil) end end,
  function() db.opts.latin = chance(0.3) end,
  function() db.opts.daily = pick({ 3, 8, 100, 100, 0 }) end,
  function() db.opts.mode = pick({ "whisper", "whisper", "invite" }) end,
  function() db.opts.pitch = chance(0.5) end,
  function() db.opts.autowelcome = chance(0.5) end,
  function() M.pressOnly = chance(0.5) end, -- a client that refuses chat sent by a timer
  function() M.fire("CHAT_MSG_GUILD", chance(0.1) and M.secret() or "hi", chance(0.1) and M.secret() or knownName("joined")) end,
  function() M.fire("GROUP_ROSTER_UPDATE") end,
  function() if chance(0.5) then press(ns.Step, knownName("joined"), pick({ "discord", "hello", "run", "junk" })) end end,
  function() M.fire("CHAT_MSG_ADDON", "Torchcall", "S;1;zz" .. R(99) .. ";" .. pick({ "3,1,1", "0,0,0", "9,99,1", "x", "", "5,5,5,5" }), "GUILD", "Board " .. R(80)) end,
  function() ns.Insights() ns.Board() ns.Recruits() ns.FollowUps() ns.MyScore() end,
  function() db.opts.template = R(1, #db.templates) end,
  function() ns.SetSort(pick({ "name", "level", "class", "zone", "seen", "junk" })) end,
  function() -- someone writes back
    local name = contactedName()
    local p = db.prospects[name]
    local text = chance(0.05) and M.secret() or pick({ "sure", "no thanks", "who?", "|cffff0000red|r", "" })
    if p and (p.status == "whispered" or p.status == "invited") then rec.replied[name] = true end
    M.fire("CHAT_MSG_WHISPER", text, name)
  end,
  function() -- a whisper from anyone at all; it counts as an answer only from someone we contacted
    local name = randomName()
    local p = db.prospects[name]
    local secret = chance(0.1)
    if not secret and p and (p.status == "whispered" or p.status == "invited") then rec.replied[name] = true end
    M.fire("CHAT_MSG_WHISPER", "hi", secret and M.secret() or name)
  end,
  function() -- the game reports on an invite
    local name = chance(0.6) and knownName("invited") or knownName()
    local line = pick({ "%s has joined the guild.", "%s has joined the guild.", "%s declines your guild invitation.", "%s is already in a guild.",
                        "No player named '%s' is currently playing.", "%s is ignoring you.", "%s has gone offline.", "%s" })
    local hidden = chance(0.03)
    if line == "%s has joined the guild." and db.prospects[name] then
      rec.joined[name] = true
      if not hidden then rec.joinedAt[name] = time() end
    end
    -- a check-in that reached nobody may be sent again
    if not hidden and line:find("No player named", 1, true) and rec.checked[name] and time() - rec.checked[name] <= 10 then rec.checked[name] = nil end
    M.fire("CHAT_MSG_SYSTEM", hidden and M.secret() or line:format(chance(0.2) and ("|Hplayer:" .. name .. "|h[" .. name .. "]|h") or name))
  end,
  function() press(ns.Answer, contactedName(), pick(TOPICS)) end,
  function() press(ns.Answer, contactedName(), pick(TOPICS)) end,
  function() press(ns.Answer, knownName(), pick({ "discord", "bogus", "raids", 7 })) end,
  function() press(ns.CheckIn, knownName("joined")) end,
  function() press(ns.CheckIn, knownName()) end,
  function() if chance(0.1) then M.advance(3 * 86400) end end,
  function() -- you are in a group, or a raid, or neither
    M.group, M.raid = {}, chance(0.2)
    for i = 1, pick({ 0, 0, 1, 4, 4, 12 }) do
      local guild = pick({ false, false, false, "Some Guild", "secret" })
      local m = { name = chance(0.5) and knownName() or randomName(), guild = guild or nil, class = pick(CLASSES), level = R(1, 60), npc = chance(0.05) or nil }
      M.group[i] = m
      if not guild and not m.npc and (M.raid or i <= 4) then rec.grouped[m.name] = true end
    end
  end,
  function() press(ns.AddGroup) end,
  function() -- the guild roster arrives: reading it must never send anything
    M.roster, M.rosterHidden = { M.myName }, chance(0.05) or nil
    for name in pairs(rec.joined) do if chance(0.6) then M.roster[#M.roster + 1] = name end end
    M.fire("GUILD_ROSTER_UPDATE")
  end,
  function() db.opts.rotate = chance(0.7) end,
  function() M.canEditInfo, M.canEditMotd = chance(0.7), chance(0.7) end,
  function() if chance(0.2) then M.guildInfo = pick({ "", "something the guild master wrote", M.secret() }) end end,
  function() if chance(0.1) then M.myGuild = pick({ "The True Torchmen", "The True Torchmen", "Another Guild" }) end end,
  function() if chance(0.05) then db.answers[pick(TOPICS)] = pick({ "", string.rep("q", 300) }) end end,
  function() if chance(0.03) then db.checkin = pick({ "", string.rep("q", 300), "CHECKIN {name}" }) end end,
  function() -- a guildmate's addon talks
    local kind = pick({ "C", "C", "L", "H", "Z" })
    local body = kind == "L" and (knownName() .. "," .. randomName() .. "," .. pick(JUNK)) or knownName()
    local text = chance(0.15) and pick(JUNK) or table.concat({ kind, chance(0.95) and 1 or 2, "abcdef", body }, ";")
    M.fire("CHAT_MSG_ADDON", chance(0.95) and "Torchcall" or "Other", chance(0.03) and M.secret() or text,
           chance(0.9) and "GUILD" or "WHISPER", chance(0.03) and M.secret() or "Mira Officer")
  end,
  function() M.lockdown = chance(0.2) end,
  function() M.inGuild = not chance(0.1) end,
  function() M.canInvite = not chance(0.1) end,
  function() M.chatError = chance(0.05) or nil end,
  function() M.whoError = chance(0.05) or nil end,
  function() M.inviteError = chance(0.05) or nil end,
  function() M.addonResult = chance(0.1) and pick({ 3, 11 }) or 0 end,
  function() M.races = chance(0.1) and {} or { { name = "Orc", ID = 2 }, { name = "Troll", ID = 8 }, { name = "Tauren", ID = 6 }, { name = "Undead", ID = 5 } } end,
  function() press(SlashCmdList["TORCHCALL"], pick(SLASH) .. (chance(0.3) and (" " .. knownName()) or "")) end,
  function() press(SlashCmdList["TORCHCALL"], pick(JUNK)) end,
  function() press(M.click, pick({ "Search", "Next search", "Whisper next", "Invite next", "Whisper", "Invite", "Skip", "Link", "Welcome",
                                   "Prospects", "Contacted", "Message", "Any zone", "My zone", "Any names", "Latin names", "All", "Mage",
                                   "Next does", "<", ">", "Restore", "Answers", "Reply", "Check in", "Add my group", "Put this line back", "Trying every opener",
                                   "What we are", "How it started", "Time and real life", "Raids", "PvP", "Leveling", "New or returning", "Offer a run",
                                   "Discord link", "Send the guild invite", "They said no", "Close" })) end,
  function() if chance(0.2) then db.templates[R(1, #db.templates)] = pick({ "Hi {name}", "", string.rep("y", 300), "{bogus} {zone} {level} {class} <{guild}>" }) end end,
  function() if chance(0.1) then db.reply = pick({ "FOLLOWUP join discord.gg/passthetorch", "FOLLOWUP discord.gg/x " .. string.rep("w", 300) }) end end,
  function() if chance(0.03) then login(false) end end,
}

local function plain(value, seen, depth)
  if issecretvalue(value) then fail("saved data holds a secret value") end
  local kind = type(value)
  if kind == "table" then
    if seen[value] then fail("saved data refers to the same table twice") end
    if depth > 6 then fail("saved data nests too deep") end
    seen[value] = true
    for k, v in pairs(value) do
      if type(k) ~= "string" and type(k) ~= "number" then fail("saved data has a " .. type(k) .. " key") end
      plain(v, seen, depth + 1)
    end
  elseif kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
    fail("saved data holds a " .. kind)
  end
end

local function checkState(session, step)
  if broken then error(broken, 0) end
  if ns.errors then fail("a handler raised: " .. tostring(db.log[#db.log])) end
  for i = math.max(1, #M.printed - 3), #M.printed do
    if M.printed[i]:find("command failed", 1, true) then fail("slash command failed: " .. M.printed[i]) end
  end
  if ns.QueueSize() > 120 then fail("search queue grew without bound: " .. ns.QueueSize()) end
  if step % 50 == 0 then
    local count = 0
    for name, p in pairs(db.prospects) do
      count = count + 1
      if p.name ~= name then fail("prospect filed under the wrong name") end
      if type(p.status) ~= "string" then fail("prospect without a status") end
    end
    if count > 3500 then fail("prospect list grew past its cap: " .. count) end
    if #db.sent > 400 then fail("contact clock grew without bound") end
    if #db.log > 150 then fail("log grew past its cap") end
    plain(db, {}, 0)
    if #M.sentChat > 2000 then M.sentChat = {} end
    if #M.sentAddon > 2000 then M.sentAddon = {} end
    if #M.printed > 2000 then M.printed = {} end
    if #M.sentWho > 2000 then M.sentWho = {} end
  end
end

local started = os.clock()
for session = 1, SESSIONS do
  login(session == 1 or chance(0.5))
  if chance(0.7) then press(SlashCmdList["TORCHCALL"], "") end -- most people keep the window open
  for step = 1, STEPS do
    local ok, err = pcall(STEP[R(#STEP)])
    if not ok then
      M.realPrint(("FAILED in session %d, step %d (seed %d): %s"):format(session, step, SEED, tostring(err)))
      M.realPrint("last log lines: " .. table.concat(db.log, " | ", math.max(1, #db.log - 3)))
      os.exit(1)
    end
    ok, err = pcall(checkState, session, step)
    if not ok then
      M.realPrint(("FAILED CHECK in session %d, step %d (seed %d): %s"):format(session, step, SEED, tostring(err)))
      os.exit(1)
    end
    totals.steps = totals.steps + 1
  end
end
M.realPrint(("%d sessions, %d steps, 0 failures in %.1fs (seed %d)"):format(SESSIONS, totals.steps, os.clock() - started, SEED))
M.realPrint(("  %d searches, %d opening whispers, %d invites, %d follow-ups, %d welcomes, %d logins (%d on fresh data)")
  :format(totals.searches, totals.whispers, totals.invites, totals.followups, totals.welcomes, totals.relogs, totals.wipes))
M.realPrint(("  %d answers, %d check-ins, %d openers to people played with"):format(totals.answers, totals.checkins, totals.groupOpeners))
