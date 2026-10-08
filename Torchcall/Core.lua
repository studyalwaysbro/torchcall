-- Torchcall core: who searches, the prospect list, whispers and guild invites.
--
-- Every who search, whisper and guild invite in this file runs straight from a button
-- press or a typed command, one press for one action. Nothing here is ever called from
-- a timer or an event, so the addon cannot contact anyone on its own. That is deliberate:
-- the client restricts these calls, and one person choosing each contact is the
-- difference between recruiting and spam.
--
-- A who search returns at most 50 players, so a busy level range is split into smaller
-- ranges, then by class, then by race, and queued. Each queued search still needs its own
-- press. The level and class filters are also applied here to every result, so the list
-- is right even if the server ignores part of a query.
-- Players are keyed by name: who results carry no GUID, and Forever has no realms.

local ADDON, ns = ...

ns.VERSION = "1.1.0"

local WHO_GAP = 5             -- seconds between who searches (the server throttles faster ones)
local WHO_TIMEOUT = 6         -- how long to wait for an answer before giving the search back
local WHO_MAX = 50            -- most results one search can return
local INVITE_GAP = 2
local NEW_MAX_AGE = 12 * 3600 -- an uncontacted prospect was only known to be online when seen
local KEPT_MAX_AGE = 60 * 86400
local PROSPECT_CAP, LOG_CAP = 3000, 150
local CONTACTED_CAP = 20000   -- names remembered for good so nobody is ever asked twice
local TSTATS_CAP = 40

local issecret = issecretvalue or function() return false end

-- The value, or nil when it is secret.
local function plain(v)
  if issecret(v) then return nil end
  return v
end
ns.plain = plain

-- Call a game function that may be missing or may reject its arguments.
local function try(f, ...)
  if type(f) ~= "function" then return nil end
  local ok, a, b, c, d = pcall(f, ...)
  if ok then return a, b, c, d end
end
ns.try = try

function ns.Print(msg)
  print("|cffff7d0aTorchcall:|r " .. tostring(msg))
end

function ns.Log(kind, msg)
  local db = TorchcallDB
  if not db then return end
  local log = db.log
  log[#log + 1] = date("%m-%d %H:%M:%S") .. " " .. kind .. ": " .. tostring(msg)
  while #log > LOG_CAP do table.remove(log, 1) end
end

local function changed()
  if ns.OnChanged then ns.OnChanged() end
end

-- ---------------------------------------------------------------------------
-- Saved data
-- ---------------------------------------------------------------------------

local function initDB()
  TorchcallDB = type(TorchcallDB) == "table" and TorchcallDB or {}
  local db = TorchcallDB
  db.version = 1
  db.prospects = db.prospects or {} -- [name] = { name, level, class, classStr, race, zone, seen, status, ... }
  db.sent = db.sent or {}           -- times of first contacts in the last day, for the limits
  db.stats = db.stats or {}
  db.opts = db.opts or {}
  db.log = db.log or {}
  if type(db.templates) ~= "table" or #db.templates == 0 then
    db.templates = {}
    for i, t in ipairs(ns.TEMPLATES) do db.templates[i] = t end
  end
  if type(db.reply) ~= "string" then db.reply = ns.REPLY end
  if type(db.welcome) ~= "string" then db.welcome = ns.WELCOME end
  db.tstats = db.tstats or {}       -- [hash of the message text] = { sent, replied, joined, t }
  for key in pairs(db.tstats) do if type(key) ~= "string" then db.tstats[key] = nil end end -- 1.1 betas keyed by slot
  -- Every name ever contacted, by us or by a guildmate. The detailed record below is
  -- dropped after 60 days; this is what keeps that player from ever being asked again.
  db.contacted = db.contacted or {} -- [name] = time
  for name, p in pairs(db.prospects) do
    if p.status ~= "new" and not db.contacted[name] then db.contacted[name] = p.t or time() end
  end
  local s, o = db.stats, db.opts
  for _, k in ipairs({ "found", "whispered", "invited", "joined", "declined", "replied" }) do s[k] = s[k] or 0 end
  if o.minimap == nil then o.minimap = true end
  if o.sound == nil then o.sound = true end
  if o.mode ~= "invite" then o.mode = "whisper" end -- what the Next button does
  o.template = o.template or 1
  o.hourly = math.min(o.hourly or 30, 60) -- first contacts allowed per hour
  o.daily = o.daily or 100       -- and per day
  o.gap = o.gap or 4             -- seconds between whispers
  o.lo, o.hi = o.lo or 1, o.hi or 60
  if type(o.classes) ~= "table" then o.classes = {} end -- class token = true; empty means every class
  if o.latin == nil then o.latin = false end            -- only names in the Latin alphabet
  o.sort = o.sort or "seen"
  if o.sortUp == nil then o.sortUp = false end
end

local myName

local function fullName(unit)
  local name = plain(try(GetUnitName, unit, true))
  if type(name) ~= "string" or name == "" then name = plain((try(UnitName, unit))) end
  if type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then return name end
end

local function prune()
  local db, now, count = TorchcallDB, time(), 0
  for name, p in pairs(db.prospects) do
    local age = now - (p.t or p.seen or 0)
    if p.status == "new" and now - (p.seen or 0) > NEW_MAX_AGE then
      db.prospects[name] = nil
    elseif p.status ~= "new" and p.status ~= "skipped" and p.status ~= "declined" and age > KEPT_MAX_AGE then
      db.prospects[name] = nil
    else
      count = count + 1
    end
  end
  local remembered = 0
  for _ in pairs(db.contacted) do remembered = remembered + 1 end
  if remembered > CONTACTED_CAP then
    local list = {}
    for name, t in pairs(db.contacted) do list[#list + 1] = { name, t } end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    for i = 1, remembered - CONTACTED_CAP do
      if not db.prospects[list[i][1]] then db.contacted[list[i][1]] = nil end
    end
  end
  if count > PROSPECT_CAP then -- drop the oldest uncontacted first
    local list = {}
    for name, p in pairs(db.prospects) do
      if p.status == "new" then list[#list + 1] = { name, p.seen or 0 } end
    end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    for i = 1, math.min(#list, count - PROSPECT_CAP) do db.prospects[list[i][1]] = nil end
  end
end

-- ---------------------------------------------------------------------------
-- Prospects
-- ---------------------------------------------------------------------------

local function findProspect(name)
  if type(name) ~= "string" then return nil end
  local list = TorchcallDB.prospects
  if list[name] then return list[name] end
  local bare = name:gsub("%-[^%-]*$", "") -- a realm suffix, on clients that add one
  if list[bare] then return list[bare] end
  local short = type(Ambiguate) == "function" and plain(try(Ambiguate, name, "none"))
  if type(short) == "string" then return list[short] end
end
ns.FindProspect = findProspect

-- Takes one who result. Returns true when it added a new prospect.
local function addFromWho(info)
  if type(info) ~= "table" then return false end
  local name, guild = plain(info.fullName), plain(info.fullGuildName)
  if type(name) ~= "string" or name == "" or name == myName then return false end
  local known = TorchcallDB.prospects[name]
  -- contacted once, some time ago, and the detailed record has since been dropped
  if not known and TorchcallDB.contacted[name] then return false end
  if type(guild) ~= "string" or guild ~= "" then
    -- in a guild (or the game would not say): not a prospect, and no longer one if they were
    if known and known.status == "new" then TorchcallDB.prospects[name] = nil end
    return false
  end
  local level, class = plain(info.level), plain(info.filename)
  local entry = known or { name = name, status = "new" }
  entry.level = (type(level) == "number" and level > 0) and level or entry.level or 0
  entry.class = type(class) == "string" and class or entry.class
  entry.classStr = plain(info.classStr) or entry.classStr
  entry.race = plain(info.raceStr) or entry.race
  entry.zone = plain(info.area) or entry.zone
  entry.seen = time()
  TorchcallDB.prospects[name] = entry
  return known == nil
end

-- A waiting player was only known to be online when a search saw them.
local function stale(p)
  return p.status == "new" and time() - (p.seen or 0) > NEW_MAX_AGE
end

local function dropStale()
  local list = TorchcallDB.prospects
  for name, p in pairs(list) do
    if stale(p) then list[name] = nil end
  end
end

-- Someone who wrote back and is still waiting on us for the invite or the Discord line.
local function answered(p)
  return p.replied ~= nil and (p.status == "whispered" or (p.status == "invited" and not p.linked))
end
ns.Answered = answered

local STATUS_ORDER = { whispered = 1, invited = 2, taken = 3, joined = 4, declined = 5, guilded = 6 }
local LEVEL_CAP, LEVEL_MAX = 60, 80 -- Forever's cap, and the most the level boxes accept

-- ---------------------------------------------------------------------------
-- Filters: level range, classes, alphabet. They decide what a search asks for, what the
-- waiting list shows and who the Next button reaches.
-- ---------------------------------------------------------------------------

-- The classes picked, in display order. Empty means no class filter.
local function pickedClasses()
  local set, list = TorchcallDB.opts.classes, {}
  for _, token in ipairs(ns.CLASSES) do
    if set[token] then list[#list + 1] = token end
  end
  if #list == #ns.CLASSES then return {} end
  return list
end
ns.PickedClasses = pickedClasses

function ns.ToggleClass(token)
  local set = TorchcallDB.opts.classes
  if token == nil then
    for k in pairs(set) do set[k] = nil end
  elseif ns.CLASS_NAMES[token] then
    set[token] = (not set[token]) or nil
  end
  changed()
end

local function clampLevel(v)
  return math.max(1, math.min(LEVEL_MAX, math.floor(v)))
end

function ns.SetLevels(lo, hi)
  lo, hi = clampLevel(tonumber(lo) or 1), clampLevel(tonumber(hi) or LEVEL_CAP)
  if hi < lo then lo, hi = hi, lo end
  local o = TorchcallDB.opts
  o.lo, o.hi = lo, hi
  return lo, hi
end

-- Is every letter of this name from the Latin alphabet? Accented letters count
-- (Zoe with a diaeresis, Vietnamese names); Cyrillic, Greek, Korean and the rest do not.
local function latinName(name)
  local i, n = 1, #name
  while i <= n do
    local b = name:byte(i)
    local cp, len
    if b < 0x80 then cp, len = b, 1
    elseif b >= 0xC2 and b < 0xE0 then cp, len = (b - 0xC0) * 64 + ((name:byte(i + 1) or 0x80) - 0x80), 2
    elseif b >= 0xE0 and b < 0xF0 then
      cp, len = (b - 0xE0) * 4096 + ((name:byte(i + 1) or 0x80) - 0x80) * 64 + ((name:byte(i + 2) or 0x80) - 0x80), 3
    else return false end -- four-byte characters and stray bytes are never Latin letters
    local latin = cp < 0x250                      -- Basic Latin to Latin Extended-B
      or (cp >= 0x300 and cp < 0x370)             -- combining accents
      or (cp >= 0x1E00 and cp < 0x1F00)           -- Latin Extended Additional
      or (cp >= 0x2010 and cp < 0x2020)           -- hyphens and curly apostrophes
    if not latin then return false end
    i = i + len
  end
  return true
end
ns.LatinName = latinName

-- Does this player pass the filters set in the window right now?
local function matches(p)
  local o = TorchcallDB.opts
  -- with a level range set, a player whose level the game would not give does not pass
  if o.lo > 1 or o.hi < LEVEL_CAP then
    local level = p.level
    if type(level) ~= "number" or level < o.lo or level > o.hi then return false end
  end
  if next(o.classes) and #pickedClasses() > 0 and not (p.class and o.classes[p.class]) then return false end
  if o.latin and not latinName(p.name) then return false end
  return true
end
ns.Matches = matches

local SORTS = {
  name = function(p) return p.name end,
  level = function(p) return p.level or 0 end,
  class = function(p) return p.classStr or p.class or "" end,
  zone = function(p) return p.zone or "" end,
  seen = function(p) return (p.status == "new" and p.seen or p.t) or 0 end,
}

function ns.SetSort(key)
  local o = TorchcallDB.opts
  if not SORTS[key] then return end
  if o.sort == key then o.sortUp = not o.sortUp else o.sort, o.sortUp = key, (key == "name" or key == "class" or key == "zone") end
  changed()
end

-- kind "new" = waiting for a first contact and passing the filters (people who answered
-- always show, and come first); kind "contacted" = everyone already reached.
-- Also returns how many waiting players the filters are hiding.
function ns.List(kind)
  dropStale()
  local rows, hidden = {}, 0
  for _, p in pairs(TorchcallDB.prospects) do
    if kind == "new" then
      if answered(p) then
        rows[#rows + 1] = p
      elseif p.status == "new" then
        if matches(p) then rows[#rows + 1] = p else hidden = hidden + 1 end
      end
    elseif STATUS_ORDER[p.status] and not answered(p) then
      rows[#rows + 1] = p
    end
  end
  local o = TorchcallDB.opts
  local key, up = SORTS[o.sort] or SORTS.seen, o.sortUp
  table.sort(rows, function(a, b)
    if kind == "new" and answered(a) ~= answered(b) then return answered(a) end
    local x, y = key(a), key(b)
    if x ~= y then
      if up then return x < y end
      return x > y
    end
    return a.name < b.name
  end)
  return rows, hidden
end

function ns.Counts()
  local c = { new = 0, hidden = 0, whispered = 0, invited = 0, joined = 0, declined = 0, taken = 0, skipped = 0, guilded = 0, replied = 0 }
  for _, p in pairs(TorchcallDB.prospects) do
    if p.status == "new" and not matches(p) then
      c.hidden = c.hidden + 1
    else
      c[p.status] = (c[p.status] or 0) + 1
    end
    if answered(p) then c.replied = c.replied + 1 end
  end
  return c
end

-- ---------------------------------------------------------------------------
-- Who searches
-- ---------------------------------------------------------------------------

local queue, pending, lastWho = {}, nil, -WHO_GAP
-- Set when a search asked for one class and the answer held another: the server is not
-- honouring that part of the query, so splitting by it would only repeat the same search.
local classFilterBroken, raceFilterBroken = false, false
local sendingOurs = false

-- A who answer carries no sign of which search it belongs to. So when anything else sends
-- a search while ours is out (you typing /who, the who window, another addon), ours is
-- put back on the queue and whatever arrives next is ignored.
local function onForeignWho()
  if sendingOurs or not pending then return end
  local q = pending
  pending = nil
  table.insert(queue, 1, q)
  ns.searchNote = "Another who search went out at the same time, so that one was put back. Press Search again."
  if ns.OnChanged then ns.OnChanged() end
end
ns.OnForeignWho = onForeignWho
ns.searchNote = "Pick a level range and press Search."

local function note(text)
  ns.searchNote = text
  changed()
end

local function whoDisabled()
  if C_GameRules and C_GameRules.IsGameRuleActive and Enum and Enum.GameRule and Enum.GameRule.IngameWhoListDisabled then
    return plain(try(C_GameRules.IsGameRuleActive, Enum.GameRule.IngameWhoListDisabled)) == true
  end
  return false
end

local function className(token)
  local localized = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
  return type(localized) == "string" and localized or ns.CLASS_NAMES[token] or token
end
ns.ClassName = className

local function queryText(q)
  local text = q.lo .. "-" .. q.hi
  if q.class then text = text .. ' c-"' .. className(q.class) .. '"' end
  if q.race then text = text .. ' r-"' .. q.race .. '"' end
  if q.zone then text = text .. ' z-"' .. q.zone .. '"' end
  return text
end
ns.QueryText = queryText

-- The races this character can search for, as the who window names them.
local function raceNames()
  local names = {}
  local filters = C_FriendList and C_FriendList.GetWhoRaceFilters and plain(try(C_FriendList.GetWhoRaceFilters))
  if type(filters) == "table" then
    for _, f in ipairs(filters) do
      local name = type(f) == "table" and plain(f.name)
      if type(name) == "string" and name ~= "" and not name:find('"', 1, true) then names[#names + 1] = name end
    end
  end
  return names
end

local function describe(q)
  local text = (q.lo == q.hi) and ("level " .. q.lo) or ("levels " .. q.lo .. " to " .. q.hi)
  if q.class then text = text .. ", " .. className(q.class) end
  if q.race then text = text .. ", " .. q.race end
  if q.zone then text = text .. ", " .. q.zone end
  return text
end

local function sameQuery(a, b)
  return a.lo == b.lo and a.hi == b.hi and a.class == b.class and a.race == b.race and a.zone == b.zone
end

-- Drop a filter the server ignores from everything still queued, and the repeats that leaves.
local function stripFromQueue(field)
  local kept = {}
  for _, q in ipairs(queue) do
    q[field] = nil
    local repeatOf
    for _, k in ipairs(kept) do if sameQuery(k, q) then repeatOf = true break end end
    if not repeatOf then kept[#kept + 1] = q end
  end
  queue = kept
end

-- Who results only arrive as an event while the client is told to send them to the UI.
-- Blizzard's own who window keeps that switched on while it is open, so "off" here means
-- "back to whatever that window wants".
local function setWhoToUi(on)
  if not on then
    local frame = _G.WhoFrame
    on = type(frame) == "table" and type(frame.IsShown) == "function" and plain(try(frame.IsShown, frame)) == true
  end
  if C_FriendList and C_FriendList.SetWhoToUi then pcall(C_FriendList.SetWhoToUi, on and true or false) end
end

function ns.QueueSize() return #queue end
function ns.SearchPending() return pending ~= nil end

-- Sends the next queued search. Only ever reached from a click or a typed command.
function ns.NextSearch()
  if pending then return false end
  local q = queue[1]
  if not q then
    note("Nothing queued. Press Search to start again.")
    return false
  end
  if whoDisabled() then
    note("Who searches are switched off on this ruleset.")
    return false
  end
  -- the wall-clock copy keeps the gap across a reload
  local wait = math.max(WHO_GAP - (GetTime() - lastWho), WHO_GAP - (time() - (TorchcallDB.lastWho or 0)))
  if wait > 0 then
    note(("The game limits who searches. Try again in %d seconds."):format(math.ceil(wait)))
    return false
  end
  if not (C_FriendList and C_FriendList.SendWho) then
    note("This client has no who search for addons.")
    return false
  end
  setWhoToUi(true)
  local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social
  sendingOurs = true
  local ok, err = pcall(C_FriendList.SendWho, queryText(q), origin)
  sendingOurs = false
  if not ok then
    setWhoToUi(false)
    ns.Log("who", err)
    note("The game refused that search.")
    return false
  end
  table.remove(queue, 1)
  lastWho = GetTime()
  TorchcallDB.lastWho = time()
  pending = q
  note("Searching " .. describe(q) .. "...")
  C_Timer.After(WHO_TIMEOUT, function()
    if pending ~= q then return end
    pending = nil
    setWhoToUi(false)
    table.insert(queue, 1, q)
    note("No answer from the game. Wait a few seconds and press Search again.")
  end)
  return true
end

-- Starts a fresh plan from the level range and classes set in the window, and sends its
-- first search. With classes picked there is one search per class from the start.
function ns.StartSearch(lo, hi, zone)
  if pending then
    note("Still waiting for the last search. Try again in a moment.")
    return false
  end
  lo, hi = ns.SetLevels(lo, hi)
  zone = (type(zone) == "string" and zone ~= "" and not zone:find('"', 1, true)) and zone or nil
  local classes = pickedClasses()
  queue = {}
  if #classes == 0 or classFilterBroken then
    queue[1] = { lo = lo, hi = hi, zone = zone }
  else
    for _, token in ipairs(classes) do
      queue[#queue + 1] = { lo = lo, hi = hi, class = token, zone = zone }
    end
  end
  return ns.NextSearch()
end

local function onWhoResults()
  if not C_FriendList then return end
  -- Only answers to our own search count. A who search you type yourself, or one another
  -- addon runs, must never put people on a recruiting list.
  local q = pending
  if not q then return end
  local shown, total = try(C_FriendList.GetNumWhoResults)
  shown, total = plain(shown), plain(total)
  pending = nil
  setWhoToUi(false)
  if type(shown) ~= "number" then
    note("The game would not show the results of that search.")
    return
  end
  if type(total) ~= "number" then total = shown end
  local added, wrongClass, wrongRace = 0, 0, 0
  for i = 1, shown do
    local info = try(C_FriendList.GetWhoInfo, i)
    if type(info) == "table" then
      local class, race = plain(info.filename), plain(info.raceStr)
      if q.class and type(class) == "string" and class ~= q.class then wrongClass = wrongClass + 1 end
      if q.race and type(race) == "string" and race ~= q.race then wrongRace = wrongRace + 1 end
    end
    if addFromWho(info) then added = added + 1 end
  end
  TorchcallDB.stats.found = TorchcallDB.stats.found + added
  local text = ("%s: %d online, %d new without a guild."):format(describe(q), total, added)
  -- this answer was really the answer to the same search without that filter: treat it so,
  -- and drop the queued searches that would only repeat it
  local function ignored(field)
    q[field] = nil
    stripFromQueue(field)
    for i = #queue, 1, -1 do
      if sameQuery(queue[i], q) then table.remove(queue, i) end
    end
  end
  if wrongClass > 0 and not classFilterBroken then
    classFilterBroken = true
    ignored("class")
    ns.Log("who", "class filter ignored by the server for " .. queryText(q))
    text = text .. " The game ignored the class part of the search, so classes are filtered here instead."
  end
  if wrongRace > 0 and not raceFilterBroken then
    raceFilterBroken = true
    ignored("race")
    ns.Log("who", "race filter ignored by the server for " .. queryText(q))
  end
  if total > shown or shown >= WHO_MAX then
    local picked = pickedClasses()
    local races = (not raceFilterBroken and not q.race) and raceNames() or {}
    local function push(extra)
      local item = { lo = q.lo, hi = q.hi, class = q.class, race = q.race, zone = q.zone }
      for k, v in pairs(extra) do item[k] = v end
      for _, queued in ipairs(queue) do if sameQuery(queued, item) then return end end
      table.insert(queue, 1, item)
    end
    if q.hi > q.lo then
      local mid = math.floor((q.lo + q.hi) / 2)
      push({ lo = mid + 1 })
      push({ hi = mid })
      text = text .. " Too many for one search, so it was split."
    elseif not q.class and not classFilterBroken then
      local list = #picked > 0 and picked or ns.CLASSES
      for i = #list, 1, -1 do push({ class = list[i] }) end
      text = text .. " Too many for one search, so it was split by class."
    elseif #races > 1 then
      for i = #races, 1, -1 do push({ race = races[i] }) end
      text = text .. " Too many for one search, so it was split by race."
    else
      text = text .. " Only the first " .. WHO_MAX .. " could be read."
    end
  end
  if #queue > 0 then text = text .. (" Press Search for the next one (%d left)."):format(#queue) end
  note(text)
end

-- ---------------------------------------------------------------------------
-- Whispers and invites
-- ---------------------------------------------------------------------------

local lastWhisper, lastInvite = -1000, -1000

local function lockedDown()
  return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and plain(try(C_ChatInfo.InChatMessagingLockdown)) == true
end
ns.ChatLockedDown = lockedDown

local function myGuild()
  if not plain(try(IsInGuild)) then return nil end
  local g = plain((try(GetGuildInfo, "player")))
  if type(g) == "string" and g ~= "" then return g end
end
ns.MyGuild = myGuild

function ns.CanInvite()
  if not plain(try(IsInGuild)) then return false, "You are not in a guild yet, so there is nothing to invite to." end
  if type(CanGuildInvite) == "function" and plain(try(CanGuildInvite)) == false then
    return false, "Your guild rank cannot invite."
  end
  return true
end

-- First contacts made in the last day, and in the last hour.
function ns.SentToday()
  local sent, now = TorchcallDB.sent, time()
  while sent[1] and now - sent[1] >= 86400 do table.remove(sent, 1) end
  return #sent
end

function ns.SentThisHour()
  local sent, now, n = TorchcallDB.sent, time(), 0
  for i = ns.SentToday(), 1, -1 do
    if now - sent[i] >= 3600 then break end
    n = n + 1
  end
  return n
end

-- Why no new person may be contacted right now, or nil.
local function overLimit()
  local o = TorchcallDB.opts
  if ns.SentThisHour() >= o.hourly then
    return ("That is %d new people this hour, which is the limit. Change it with /torchcall cap."):format(o.hourly)
  end
  if ns.SentToday() >= o.daily then
    return ("That is %d new people today, which is the daily limit. Pick it up tomorrow."):format(o.daily)
  end
end

local function goneStale(p)
  if not stale(p) then return false end
  TorchcallDB.prospects[p.name] = nil
  changed()
  return true
end

local function countContact()
  local sent = TorchcallDB.sent
  sent[#sent + 1] = time()
end

function ns.Render(template, p)
  local words = {
    name = (p.name:match("^(%S+)")) or p.name,
    fullname = p.name,
    level = tostring(p.level or ""),
    class = p.classStr or (p.class and className(p.class)) or "",
    zone = p.zone or "",
    guild = myGuild() or ns.GUILD_NAME,
  }
  local text = template:gsub("{(%a+)}", function(key) return words[key] end)
  return (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- One whisper to one player. followup = the Discord line for someone who answered.
function ns.Whisper(name, followup)
  local db = TorchcallDB
  local p = db.prospects[name]
  if not p then return false, "That player is not on the list." end
  if followup then
    if not p.replied or (p.status ~= "whispered" and p.status ~= "invited" and p.status ~= "joined") then
      return false, "The follow-up is only for someone who answered you."
    end
    if p.linked then return false, name .. " already has the follow-up." end
  elseif p.status ~= "new" then
    return false, name .. " was already contacted."
  elseif goneStale(p) then
    return false, name .. " was last seen too long ago. Run a search."
  end
  if lockedDown() then return false, "The game holds addon chat in here (instance or match). Try again outside." end
  local wait = math.max(db.opts.gap - (GetTime() - lastWhisper), db.opts.gap - (time() - (db.lastWhisper or 0)))
  if wait > 0 then return false, ("Easy. Next whisper in %d seconds."):format(math.ceil(wait)) end
  local limit = not followup and overLimit()
  if limit then return false, limit end
  local which = db.templates[db.opts.template] and db.opts.template or 1
  local text = ns.Render(followup and db.reply or db.templates[which], p)
  if text == "" then return false, "The message is empty. Write one on the Message tab." end
  if #text > 255 then return false, "That message is longer than the game allows (255). Shorten it on the Message tab." end
  local sendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if type(sendChat) ~= "function" then return false, "This client has no chat function for addons." end
  local ok, err = pcall(sendChat, text, "WHISPER", nil, name)
  if not ok then
    ns.Log("chat", err)
    return false, "The game refused that whisper."
  end
  lastWhisper = GetTime()
  db.lastWhisper = time()
  if not followup then
    p.status, p.t, p.tpl = "whispered", time(), ns.TemplateKey(db.templates[which])
    db.contacted[name] = p.t
    db.stats.whispered = db.stats.whispered + 1
    ns.TemplateStat(p.tpl, "sent")
    countContact()
    if ns.Comm then ns.Comm.Tell(name) end
  else
    p.linked = true
  end
  changed()
  return true
end

-- How each opening message is doing: sent, answered, joined. Results belong to the exact
-- wording, so editing a message starts a fresh count instead of inheriting the old one.
function ns.TemplateKey(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return ("%08x"):format(h)
end

function ns.TemplateStat(key, field)
  local all = TorchcallDB.tstats
  local t = all[key]
  if not t then
    if not field then return { sent = 0, replied = 0, joined = 0 } end
    local count, oldest = 0, nil
    for k, v in pairs(all) do
      count = count + 1
      if not oldest or (v.t or 0) < (all[oldest].t or 0) then oldest = k end
    end
    if count >= TSTATS_CAP and oldest then all[oldest] = nil end
    t = { sent = 0, replied = 0, joined = 0 }
    all[key] = t
  end
  if field then t[field], t.t = (t[field] or 0) + 1, time() end
  return t
end

-- One line in guild chat for someone who just joined. Once per player, from a click.
local lastWelcome = -1000
function ns.Welcome(name)
  local db = TorchcallDB
  local p = db.prospects[name]
  if not p or p.status ~= "joined" then return false, "That is for someone who just joined." end
  if p.welcomed then return false, name .. " was already welcomed." end
  if not myGuild() then return false, "You are not in a guild." end
  if lockedDown() then return false, "The game holds addon chat in here (instance or match). Try again outside." end
  local wait = db.opts.gap - (GetTime() - lastWelcome)
  if wait > 0 then return false, ("Easy. Next welcome in %d seconds."):format(math.ceil(wait)) end
  local text = ns.Render(db.welcome, p)
  if text == "" then return false, "The welcome line is empty. Write one on the Message tab." end
  if #text > 255 then return false, "The welcome line is longer than the game allows (255)." end
  local sendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if type(sendChat) ~= "function" then return false, "This client has no chat function for addons." end
  local ok, err = pcall(sendChat, text, "GUILD")
  if not ok then
    ns.Log("chat", err)
    return false, "The game refused that message."
  end
  lastWelcome = GetTime()
  p.welcomed = true
  changed()
  return true
end

-- One guild invite to one player.
function ns.Invite(name)
  local db = TorchcallDB
  local p = db.prospects[name]
  if not p then return false, "That player is not on the list." end
  if p.status ~= "new" and p.status ~= "whispered" then
    return false, name .. " is marked " .. p.status .. "."
  end
  if goneStale(p) then return false, name .. " was last seen too long ago. Run a search." end
  local can, why = ns.CanInvite()
  if not can then return false, why end
  local wait = INVITE_GAP - (GetTime() - lastInvite)
  if wait > 0 then return false, ("Next invite in %d seconds."):format(math.ceil(wait)) end
  local first = p.status == "new"
  local limit = first and overLimit()
  if limit then return false, limit end
  local invite = (C_GuildInfo and C_GuildInfo.Invite) or GuildInvite
  if type(invite) ~= "function" then return false, "This client has no guild invite for addons." end
  local ok, err = pcall(invite, name)
  if not ok then
    ns.Log("invite", err)
    return false, "The game refused that invite."
  end
  lastInvite = GetTime()
  p.status, p.t = "invited", time()
  db.contacted[name] = p.t
  db.stats.invited = db.stats.invited + 1
  if first then
    countContact()
    if ns.Comm then ns.Comm.Tell(name) end
  end
  changed()
  return true
end

function ns.Skip(name)
  local p = TorchcallDB.prospects[name]
  if not p then return false end
  p.status, p.t = "skipped", time()
  TorchcallDB.contacted[name] = p.t
  if ns.Comm then ns.Comm.Tell(name) end
  changed()
  return true
end

-- Takes a waiting player off the list. Someone already contacted cannot be forgotten:
-- the record is what stops them being asked again.
function ns.Forget(name)
  local p = findProspect(name)
  if not p then return false end
  if p.status ~= "new" then return false, p.name .. " was already contacted, so the record stays. That is what keeps them from being asked twice." end
  TorchcallDB.prospects[p.name] = nil
  changed()
  return true
end

-- The player the Next button would act on.
function ns.NextTarget()
  for _, p in ipairs(ns.List("new")) do
    if p.status == "new" then return p end
  end
end

-- Next button: one press, one player, one whisper or one invite.
function ns.Next()
  local p = ns.NextTarget()
  if not p then
    local _, hidden = ns.List("new")
    if hidden > 0 then return false, ("Nobody matches your level and class filters. %d waiting are hidden by them."):format(hidden) end
    return false, "Nobody is waiting. Run a search."
  end
  if TorchcallDB.opts.mode == "invite" then return ns.Invite(p.name) end
  return ns.Whisper(p.name)
end

-- ---------------------------------------------------------------------------
-- What the game says back
-- ---------------------------------------------------------------------------

-- Turns "%s has joined the guild." into a Lua pattern capturing the name.
local function formatToPattern(fmt)
  local out, i, captures, auto, nameCapture = { "^" }, 1, 0, 0, nil
  while i <= #fmt do
    local ch = fmt:sub(i, i)
    if ch == "%" then
      if fmt:sub(i + 1, i + 1) == "%" then
        out[#out + 1] = "%%"
        i = i + 2
      else
        local pos, spec, nextI = fmt:match("^%%(%d+)%$[%-%+ #0]*%d*%.?%d*([a-zA-Z])()", i)
        if not pos then
          spec, nextI = fmt:match("^%%[%-%+ #0]*%d*%.?%d*([a-zA-Z])()", i)
          auto = auto + 1
          pos = auto
        end
        if not spec then return nil end
        captures = captures + 1
        if tonumber(pos) == 1 then nameCapture = captures end
        out[#out + 1] = (spec == "s") and "(.-)" or "(%-?[%d%.,]+)"
        i = nextI
      end
    else
      out[#out + 1] = (ch:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"))
      i = i + 1
    end
  end
  if not nameCapture then return nil end
  out[#out + 1] = "$"
  return table.concat(out), nameCapture
end
ns.formatToPattern = formatToPattern

-- the game's own message formats, with the English text as a fallback
local SYSTEM_LINES = {
  { "ERR_GUILD_JOIN_S", "%s has joined the guild.", "joined" },
  { "ERR_GUILD_DECLINE_S", "%s declines your guild invitation.", "declined" },
  { "ERR_GUILD_DECLINE_AUTO_S", "%s is declining all guild invitations.", "declined" },
  { "ERR_ALREADY_IN_GUILD_S", "%s is already in a guild.", "guilded" },
  { "ERR_ALREADY_INVITED_TO_GUILD_S", "%s has already been invited to a guild.", "guilded" },
  { "ERR_CHAT_PLAYER_NOT_FOUND_S", "No player named '%s' is currently playing.", "gone" },
  { "ERR_GUILD_PLAYER_NOT_FOUND_S", "Player '%s' not found.", "gone" },
  { "ERR_CHAT_IGNORED_S", "%s is ignoring you.", "skipped" },
}
local systemPatterns

local function buildSystemPatterns()
  systemPatterns = {}
  for _, line in ipairs(SYSTEM_LINES) do
    local localized = _G[line[1]]
    local formats = { line[2] }
    if type(localized) == "string" and localized ~= line[2] then formats[2] = localized end
    for _, fmt in ipairs(formats) do
      local pattern, capture = formatToPattern(fmt)
      if pattern then systemPatterns[#systemPatterns + 1] = { pattern, capture, line[3] } end
    end
  end
end

local function stripLinks(text)
  return (text:gsub("|H.-|h%[?(.-)%]?|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local handlers = {}

function handlers.CHAT_MSG_SYSTEM(text)
  text = plain(text)
  if type(text) ~= "string" then return end
  text = stripLinks(text)
  for _, sp in ipairs(systemPatterns) do
    local caps = { text:match(sp[1]) }
    local p = caps[sp[2]] and findProspect(caps[sp[2]])
    if p then
      local outcome, db = sp[3], TorchcallDB
      if outcome == "gone" then
        -- logged off since the search: a waiting player is forgotten and a later search
        -- finds them again; someone already contacted stays on record so they are not asked twice
        if p.status == "new" then db.prospects[p.name] = nil end
      elseif outcome == "joined" then
        if p.status ~= "joined" then
          db.stats.joined = db.stats.joined + 1
          if p.tpl then ns.TemplateStat(p.tpl, "joined") end
        end
        p.status, p.t = "joined", time()
        ns.Print(p.name .. " joined the guild.")
      elseif outcome == "declined" then
        if p.status ~= "declined" then db.stats.declined = db.stats.declined + 1 end
        p.status, p.t = "declined", time()
      else
        p.status, p.t = outcome, time()
      end
      changed()
      return
    end
  end
end

function handlers.CHAT_MSG_WHISPER(text, sender)
  text, sender = plain(text), plain(sender)
  local p = findProspect(sender)
  if not p or (p.status ~= "whispered" and p.status ~= "invited") then return end
  if not p.replied then
    TorchcallDB.stats.replied = TorchcallDB.stats.replied + 1
    if p.tpl then ns.TemplateStat(p.tpl, "replied") end
  end
  p.replied = time()
  p.said = type(text) == "string" and text:gsub("|", ""):sub(1, 120) or nil
  ns.Print(p.name .. " answered your whisper. They are at the top of the list.")
  if TorchcallDB.opts.sound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then pcall(PlaySound, SOUNDKIT.TELL_MESSAGE) end
  changed()
end

function handlers.WHO_LIST_UPDATE()
  onWhoResults()
end

function handlers.PLAYER_LOGIN()
  myName = fullName("player") or "Unknown"
  ns.myName = myName
  buildSystemPatterns()
  prune()
  if not ns.whoHooked and type(hooksecurefunc) == "function" and C_FriendList and C_FriendList.SendWho then
    ns.whoHooked = pcall(hooksecurefunc, C_FriendList, "SendWho", function() onForeignWho() end)
  end
  ns.Log("login", myName .. " v" .. ns.VERSION .. " build " .. tostring((try(GetBuildInfo))))
  if ns.Comm then ns.Comm.Init() end
  if ns.UI then ns.UI.Init() end
end

local frame = CreateFrame("Frame")
ns.frame = frame

local function safeCall(event, ...)
  local h = handlers[event] or (ns.Comm and ns.Comm.handlers[event])
  if not h then return end
  local ok, err = pcall(h, ...)
  if not ok then
    ns.errors = (ns.errors or 0) + 1
    if ns.errors <= 25 then ns.Log("error", event .. ": " .. tostring(err)) end
  end
end

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... == ADDON then
      initDB()
      frame:UnregisterEvent("ADDON_LOADED")
    end
    return
  end
  if not TorchcallDB then return end
  if event ~= "PLAYER_LOGIN" and not myName then return end
  safeCall(event, ...)
end)

frame:RegisterEvent("ADDON_LOADED")
for _, event in ipairs({ "PLAYER_LOGIN", "WHO_LIST_UPDATE", "CHAT_MSG_SYSTEM", "CHAT_MSG_WHISPER", "CHAT_MSG_ADDON" }) do
  pcall(frame.RegisterEvent, frame, event) -- an event this client lacks must not stop the rest
end
