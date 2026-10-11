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

ns.VERSION = "1.2.1"

local WHO_GAP = 5             -- seconds between who searches (the server throttles faster ones)
local WHO_TIMEOUT = 6         -- how long to wait for an answer before giving the search back
local WHO_MAX = 50            -- most results one search can return
local INVITE_GAP = 2
local NEW_MAX_AGE = 12 * 3600 -- an uncontacted prospect was only known to be online when seen
local KEPT_MAX_AGE = 60 * 86400
local PROSPECT_CAP, LOG_CAP = 3000, 150
local CONTACTED_CAP = 20000   -- names remembered for good so nobody is ever asked twice
local TSTATS_CAP = 40
local ANSWER_MAX = 5          -- answers one player can be sent; past that, talk to them yourself
local CHECKIN_AFTER = 2 * 86400 -- a recruit is due a check-in this long after joining
local CHECKIN_UNTIL = 21 * 86400
local ROTATE_MIN = 20         -- sends each opener gets before the best one is preferred
local ROTATE_EXPLORE = 5      -- after that, every fifth send still goes to the least tried
local FUNNEL_MIN = 20         -- contacts on a path before its rate is worth comparing

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
  local moved = 0
  for i, old in ipairs(ns.OLD_TEMPLATES) do
    if db.templates[i] == old then db.templates[i] = ns.TEMPLATES[i] moved = moved + 1 end
  end
  -- all three were the untouched 1.1 set: the openers added since come along too
  if moved == #ns.OLD_TEMPLATES and #db.templates == moved then
    for i = moved + 1, #ns.TEMPLATES do db.templates[i] = ns.TEMPLATES[i] end
  end
  if type(db.reply) ~= "string" or db.reply == ns.OLD_REPLY then db.reply = ns.REPLY end
  if type(db.answers) ~= "table" then db.answers = {} end -- [topic] = text, for someone who answered
  for _, a in ipairs(ns.ANSWERS) do
    if type(db.answers[a.key]) ~= "string" then db.answers[a.key] = a.text end
  end
  if type(db.checkin) ~= "string" then db.checkin = ns.CHECKIN end
  if type(db.groupmsg) ~= "string" then db.groupmsg = ns.GROUP_TEMPLATE end
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
  for _, k in ipairs({ "found", "whispered", "invited", "joined", "declined", "replied", "answers", "checkins" }) do s[k] = s[k] or 0 end
  -- how an invite went, split by whether the player had been spoken to first
  for _, path in ipairs({ "cold", "warm" }) do
    if type(s[path]) ~= "table" then s[path] = {} end
    for _, k in ipairs({ "invited", "joined", "declined", "stayed", "left" }) do s[path][k] = s[path][k] or 0 end
  end
  if o.rotate == nil then o.rotate = true end -- try every opener, then lean on the one that gets answers
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
  if p.ran then return true end -- someone you played with is never filtered away
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
    if kind == "new" and (a.ran and true or false) ~= (b.ran and true or false) then return a.ran and true or false end
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

-- Which opening message the next whisper uses. With rotation on, each one is tried until it
-- has a fair sample, then the one with the best answer rate is preferred, with every fifth
-- send still going to the least tried so a slow starter gets a second look.
-- An opener that leans on something the game did not tell us about this player
-- ("could use another {class}" with no class) would read broken, so it is passed over.
local function usable(text, p)
  if type(text) ~= "string" or not text:find("%S") then return false end
  if not p then return true end
  if text:find("{class}", 1, true) and not (p.classStr or p.class) then return false end
  if text:find("{zone}", 1, true) and not (p.zone and p.zone ~= "") then return false end
  if text:find("{level}", 1, true) and not (type(p.level) == "number" and p.level > 0) then return false end
  return true
end

function ns.PickTemplate(p)
  local db = TorchcallDB
  local n = #db.templates
  local chosen = db.templates[db.opts.template] and db.opts.template or 1
  if not usable(db.templates[chosen], p) then
    for i = 1, n do
      if usable(db.templates[i], p) then chosen = i break end
    end
  end
  if not db.opts.rotate or n < 2 then return chosen end
  local least, best, total = nil, nil, 0
  local sent, rate = {}, {}
  for i = 1, n do
    local text = db.templates[i]
    if usable(text, p) then
      local t = ns.TemplateStat(ns.TemplateKey(text))
      sent[i], rate[i] = t.sent, t.sent > 0 and t.replied / t.sent or 0
      total = total + t.sent
      if not least or sent[i] < sent[least] then least = i end
      if not best or rate[i] > rate[best] then best = i end
    end
  end
  if not least then return chosen end
  if sent[least] < ROTATE_MIN or total % ROTATE_EXPLORE == ROTATE_EXPLORE - 1 then return least end
  return best
end

local function sendChat(text, channel, target)
  local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if type(send) ~= "function" then return false, "This client has no chat function for addons." end
  local ok, err = pcall(send, text, channel, nil, target)
  if not ok then
    ns.Log("chat", err)
    return false, "The game refused that message."
  end
  return true
end

-- The checks every whisper shares: chat allowed here, the pause between whispers, the length.
local function whisperReady(text, what)
  local db = TorchcallDB
  if lockedDown() then return false, "The game holds addon chat in here (instance or match). Try again outside." end
  local wait = math.max(db.opts.gap - (GetTime() - lastWhisper), db.opts.gap - (time() - (db.lastWhisper or 0)))
  if wait > 0 then return false, ("Easy. Next whisper in %d seconds."):format(math.ceil(wait)) end
  if text == "" then return false, what .. " is empty. Write one in the window." end
  if #text > 255 then return false, what .. " is longer than the game allows (255). Shorten it in the window." end
  return true
end

local function whispered()
  lastWhisper = GetTime()
  TorchcallDB.lastWhisper = time()
end

-- Has this player written back, and are they still someone we are talking to?
local function inConversation(p)
  return p.replied ~= nil and (p.status == "whispered" or p.status == "invited" or p.status == "joined")
end

-- One whisper to one player. followup = the Discord line for someone who answered.
function ns.Whisper(name, followup)
  local db = TorchcallDB
  local p = db.prospects[name]
  if not p then return false, "That player is not on the list." end
  if followup then
    if not inConversation(p) then return false, "The follow-up is only for someone who answered you." end
    if p.linked then return false, name .. " already has the follow-up." end
  elseif p.status ~= "new" then
    return false, name .. " was already contacted."
  elseif goneStale(p) then
    return false, name .. " was last seen too long ago. Run a search."
  end
  local which = followup and 0 or ns.PickTemplate(p)
  -- someone you just played with gets the line written for that, not a cold opener
  local opener = (not followup) and (p.ran and db.groupmsg:find("%S") and db.groupmsg or db.templates[which])
  local text = ns.Render(followup and db.reply or opener, p)
  local ok, why = whisperReady(text, followup and "The follow-up" or "The message")
  if not ok then return false, why end
  local limit = not followup and overLimit()
  if limit then return false, limit end
  ok, why = sendChat(text, "WHISPER", name)
  if not ok then return false, why end
  whispered()
  if not followup then
    p.status, p.t, p.tpl = "whispered", time(), ns.TemplateKey(opener)
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

-- ---------------------------------------------------------------------------
-- Answers: short replies about the guild for someone who wrote back. Each one is a single
-- whisper from a single press, each topic goes to a player once, and nobody who has not
-- written to you first can be sent one.
-- ---------------------------------------------------------------------------

function ns.AnswerTopic(key)
  for _, a in ipairs(ns.ANSWERS) do
    if a.key == key then return a end
  end
end

-- Reads what a player wrote and names the most fitting next step: an answer topic,
-- "invite" when they said yes, "skip" when they said no. nil when nothing stands out.
function ns.Suggest(text)
  if type(text) ~= "string" then return nil end
  local lower = " " .. text:lower():gsub("[%p%c]", " "):gsub("%s+", " ") .. " "
  local function has(words)
    for _, w in ipairs(words) do
      if lower:find(" " .. w .. " ", 1, true) or (w:find(" ", 1, true) and lower:find(w, 1, true)) then return true end
    end
    return false
  end
  if has(ns.SAYS_NO) then return "skip" end
  local best, bestAt
  for _, a in ipairs(ns.ANSWERS) do
    for _, w in ipairs(a.words or {}) do
      local at = lower:find(" " .. w, 1, true)
      if at and (not bestAt or at < bestAt) then best, bestAt = a.key, at end
    end
  end
  if best then return best end
  if has(ns.SAYS_YES) then return "invite" end
  return nil
end

-- The topics still unsent to this player, in window order, and how many they have had.
function ns.AnswersLeft(name)
  local p = TorchcallDB.prospects[name]
  local left, had = {}, 0
  if not p or not inConversation(p) then return left, had end
  for _, a in ipairs(ns.ANSWERS) do
    local sent = (p.ans and p.ans[a.key]) or (a.key == "discord" and p.linked)
    if sent then had = had + 1 else left[#left + 1] = a.key end
  end
  if had >= ANSWER_MAX then left = {} end
  return left, had
end

function ns.Answer(name, key)
  local db = TorchcallDB
  local p = db.prospects[name]
  if not p then return false, "That player is not on the list." end
  local topic = ns.AnswerTopic(key)
  if not topic then return false, "There is no answer called '" .. tostring(key) .. "'." end
  if not inConversation(p) then return false, "Answers are only for someone who wrote back to you." end
  if key == "discord" then return ns.Whisper(name, true) end
  p.ans = type(p.ans) == "table" and p.ans or {}
  if p.ans[key] then return false, name .. " already has that answer." end
  local _, had = ns.AnswersLeft(name)
  if had >= ANSWER_MAX then
    return false, ("That is %d answers to %s. From here, type to them yourself."):format(had, name)
  end
  local text = ns.Render(db.answers[key] or topic.text, p)
  local ok, why = whisperReady(text, "That answer")
  if not ok then return false, why end
  ok, why = sendChat(text, "WHISPER", name)
  if not ok then return false, why end
  whispered()
  p.ans[key] = time()
  db.stats.answers = db.stats.answers + 1
  changed()
  return true
end

-- ---------------------------------------------------------------------------
-- After they join: one check-in whisper a few days later. The first week decides whether
-- a recruit stays, and a recruit nobody speaks to is gone by the second.
-- ---------------------------------------------------------------------------

local function checkInDue(p)
  if p.status ~= "joined" or p.checked then return false end
  local age = time() - (p.t or 0)
  return age >= CHECKIN_AFTER and age <= CHECKIN_UNTIL
end
ns.CheckInDue = checkInDue

function ns.DueCheckIns()
  local list = {}
  for _, p in pairs(TorchcallDB.prospects) do
    if checkInDue(p) then list[#list + 1] = p end
  end
  table.sort(list, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.name < b.name end)
  return list
end

function ns.CheckIn(name)
  local db = TorchcallDB
  local p = db.prospects[name]
  if not p or p.status ~= "joined" then return false, "A check-in is for someone you recruited who joined." end
  if p.checked then return false, name .. " already had a check-in." end
  if time() - (p.t or 0) < CHECKIN_AFTER then return false, name .. " only just joined. Give it a couple of days." end
  local text = ns.Render(db.checkin, p)
  local ok, why = whisperReady(text, "The check-in")
  if not ok then return false, why end
  ok, why = sendChat(text, "WHISPER", name)
  if not ok then return false, why end
  whispered()
  p.checked = time()
  db.stats.checkins = db.stats.checkins + 1
  changed()
  return true
end

-- ---------------------------------------------------------------------------
-- What is working: invites sent cold against invites sent after a conversation.
-- ---------------------------------------------------------------------------

function ns.Funnel()
  local s = TorchcallDB.stats
  local function rate(part, whole) return whole > 0 and math.floor(part * 100 / whole + 0.5) or nil end
  local f = {
    whispered = s.whispered, replied = s.replied, replyRate = rate(s.replied, s.whispered),
    cold = { invited = s.cold.invited, joined = s.cold.joined, declined = s.cold.declined, rate = rate(s.cold.joined, s.cold.invited),
             stayed = s.cold.stayed, left = s.cold.left, kept = rate(s.cold.stayed, s.cold.stayed + s.cold.left) },
    warm = { invited = s.warm.invited, joined = s.warm.joined, declined = s.warm.declined, rate = rate(s.warm.joined, s.warm.invited),
             stayed = s.warm.stayed, left = s.warm.left, kept = rate(s.warm.stayed, s.warm.stayed + s.warm.left) },
  }
  if f.cold.invited >= FUNNEL_MIN and f.warm.invited >= FUNNEL_MIN then
    if f.warm.rate > f.cold.rate then
      f.advice = ("Invites after a conversation are accepted %d%% of the time, cold ones %d%%. Talk first."):format(f.warm.rate, f.cold.rate)
    elseif f.cold.rate > f.warm.rate then
      f.advice = ("Cold invites are accepted %d%% of the time, invites after a conversation %d%%. People who join without a word tend to leave the same way, so watch who stays."):format(f.cold.rate, f.warm.rate)
    else
      f.advice = ("Cold invites and invites after a conversation are both accepted %d%% of the time."):format(f.cold.rate)
    end
  elseif s.whispered >= FUNNEL_MIN and (f.replyRate or 0) < 10 then
    f.advice = ("Only %d%% of whispers get an answer. Try a shorter opener, or leave rotation on and let it find one."):format(f.replyRate or 0)
  else
    f.advice = "Not enough contacts yet to say what works. It takes about twenty on each path."
  end
  return f
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
  local ok, why = sendChat(text, "GUILD")
  if not ok then return false, why end
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
  p.path = p.replied and "warm" or "cold" -- had they spoken to us before the invite?
  p.status, p.t = "invited", time()
  db.contacted[name] = p.t
  db.stats.invited = db.stats.invited + 1
  db.stats[p.path].invited = db.stats[p.path].invited + 1
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
-- People you have played with. Someone from your own party who has no guild is the best
-- prospect there is, so one press puts them on the list, marked, at the top.
-- ---------------------------------------------------------------------------

function ns.AddGroup()
  local inRaid = plain(try(IsInRaid)) == true
  local count = tonumber(plain(try(GetNumGroupMembers))) or 0
  if count < 2 then return false, "You are not in a group." end
  local added, guilded, known = {}, 0, 0
  for i = 1, inRaid and math.min(count, 40) or 4 do
    local unit = (inRaid and "raid" or "party") .. i
    if plain(try(UnitExists, unit)) and plain(try(UnitIsPlayer, unit)) then
      local name = fullName(unit)
      local guild = try(GetGuildInfo, unit)
      if name and name ~= myName then
        if issecret(guild) then
          -- the game will not say: leave them alone
        elseif type(guild) == "string" and guild ~= "" then
          guilded = guilded + 1
        elseif TorchcallDB.prospects[name] or TorchcallDB.contacted[name] then
          known = known + 1
          local p = TorchcallDB.prospects[name]
          if p and p.status == "new" then p.ran, p.seen = true, time() end
        else
          local _, class = try(UnitClass, unit)
          local level = plain(try(UnitLevel, unit))
          TorchcallDB.prospects[name] = { name = name, status = "new", ran = true, seen = time(),
            level = type(level) == "number" and level > 0 and level or 0,
            class = plain(class), classStr = plain((try(UnitClass, unit))), race = plain((try(UnitRace, unit))),
            zone = plain(try(GetRealZoneText)) }
          TorchcallDB.stats.found = TorchcallDB.stats.found + 1
          added[#added + 1] = name
        end
      end
    end
  end
  changed()
  if #added == 0 then
    if known > 0 then return false, "Everyone in this group without a guild is already on your list." end
    return false, guilded > 0 and "Everyone in this group already has a guild." or "Nobody else in this group could be read."
  end
  return true, ("Added %s. They are at the top of the list, with the line for people you have played with."):format(table.concat(added, ", "))
end

-- ---------------------------------------------------------------------------
-- Who stayed. When the guild roster is read, each recruit who joined at least a week ago
-- is marked as still here or gone, once. Getting someone in is half of it.
-- ---------------------------------------------------------------------------

local STAY_AFTER = 7 * 86400

-- Answers "is this name in the guild?" for every name asked, or nil when the roster cannot
-- be trusted yet. The game's own membership check is used when this client has it; the check
-- is first tried on your own name, because before the roster has loaded it says no to everyone.
local function rosterLookup()
  local exists = C_GuildInfo and C_GuildInfo.MemberExistsByName
  if type(exists) == "function" and myName and plain(try(exists, myName)) == true then
    return function(name)
      local found = try(exists, name)
      if issecret(found) or type(found) ~= "boolean" then return nil end
      return found
    end
  end
  local n = tonumber(plain(try(GetNumGuildMembers))) or 0
  if n < 1 then return nil end
  local here = {}
  for i = 1, n do
    local name = plain((try(GetGuildRosterInfo, i)))
    if type(name) ~= "string" then return nil end -- a roster we cannot read in full proves nothing
    here[name] = true
    here[(name:gsub("%-[^%-]*$", ""))] = true
  end
  if not here[myName] then return nil end -- a list without you on it is not the whole list
  return function(name) return here[name] == true end
end

function ns.ReadRoster()
  if not myGuild() then return end
  -- the roster event fires often: only look when a recruit is waiting to be judged
  local waiting, now = {}, time()
  for name, p in pairs(TorchcallDB.prospects) do
    if p.status == "joined" and p.stayed == nil and now - (p.t or now) >= STAY_AFTER then waiting[#waiting + 1] = name end
  end
  if #waiting == 0 then return end
  local inGuild = rosterLookup()
  if not inGuild then return end
  local s, any = TorchcallDB.stats, false
  for _, name in ipairs(waiting) do
    local p, found = TorchcallDB.prospects[name], inGuild(name)
    if found ~= nil then
      p.stayed = found
      local path = p.path and s[p.path] -- joins from before 1.2 have no path and are not counted
      if path then
        if p.stayed then path.stayed = path.stayed + 1 else path.left = path.left + 1 end
      end
      any = true
    end
  end
  if any then changed() end
end

-- ---------------------------------------------------------------------------
-- The guild window: Info text and message of the day. Read at any time, written only from
-- a typed command, only in the guild this copy was written for, and only if your rank can.
-- ---------------------------------------------------------------------------

local GUILD_TEXT = {
  info = { label = "Guild info", max = 500, want = function() return ns.GUILD_INFO end,
           get = function() return (C_GuildInfo and C_GuildInfo.GetInfoText) or GetGuildInfoText end,
           set = function() return (C_GuildInfo and C_GuildInfo.SetInfoText) or SetGuildInfoText end,
           can = function() return CanEditGuildInfo end },
  motd = { label = "Message of the day", max = 128, want = function() return ns.GUILD_MOTD end,
           get = function() return (C_GuildInfo and C_GuildInfo.GetMOTD) or GetGuildRosterMOTD end,
           set = function() return (C_GuildInfo and C_GuildInfo.SetMOTD) or GuildSetMOTD end,
           can = function() return CanEditMOTD end },
}

-- What one of the two says now, what Torchcall would write, and whether you may write it.
function ns.GuildText(which)
  local g = GUILD_TEXT[which]
  if not g then return nil end
  local now = plain(try(g.get()))
  local state = { label = g.label, want = g.want(), now = type(now) == "string" and now or nil, max = g.max }
  state.ours = myGuild() == ns.GUILD_NAME
  state.can = state.ours and plain(try(g.can())) == true and type(g.set()) == "function"
  state.same = state.now ~= nil and state.now:gsub("%s+", " ") == state.want:gsub("%s+", " ")
  state.empty = state.now ~= nil and not state.now:find("%S")
  return state
end

function ns.SetGuildText(which)
  local g, state = GUILD_TEXT[which], ns.GuildText(which)
  if not state then return false, "Say which: info or motd." end
  if not myGuild() then return false, "You are not in a guild." end
  if not state.ours then return false, "These texts were written for <" .. ns.GUILD_NAME .. ">. Edit them in Data.lua for another guild." end
  if not state.can then return false, "Your guild rank cannot edit the " .. state.label:lower() .. "." end
  if state.same then return false, "The " .. state.label:lower() .. " already says that." end
  if #state.want > state.max then return false, "That text is longer than the game allows (" .. state.max .. ")." end
  local ok, err = pcall(g.set(), state.want)
  if not ok then
    ns.Log("guild", err)
    return false, "The game refused that. Try it from the guild window."
  end
  if state.now and not state.empty then TorchcallDB["old" .. which] = state.now:sub(1, 600) end -- so it can be put back by hand
  return true
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
        -- a check-in to someone who is offline never arrived: it can be sent again later
        if p.checked and time() - p.checked <= 10 then
          p.checked = nil
          db.stats.checkins = math.max(0, db.stats.checkins - 1)
        end
      elseif outcome == "joined" then
        if p.status ~= "joined" then
          db.stats.joined = db.stats.joined + 1
          if p.tpl then ns.TemplateStat(p.tpl, "joined") end
          if p.path then db.stats[p.path].joined = db.stats[p.path].joined + 1 end
        end
        p.status, p.t = "joined", time()
        ns.Print(p.name .. " joined the guild.")
      elseif outcome == "declined" then
        if p.status ~= "declined" then
          db.stats.declined = db.stats.declined + 1
          if p.path then db.stats[p.path].declined = db.stats[p.path].declined + 1 end
        end
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
  if not p or (p.status ~= "whispered" and p.status ~= "invited" and not (p.status == "joined" and p.checked)) then return end
  if p.status == "joined" then -- an answer to a check-in: note it, nothing more to send
    p.said = type(text) == "string" and text:gsub("|", ""):sub(1, 120) or nil
    changed()
    return
  end
  if not p.replied then
    TorchcallDB.stats.replied = TorchcallDB.stats.replied + 1
    if p.tpl then ns.TemplateStat(p.tpl, "replied") end
  end
  p.replied = time()
  p.said = type(text) == "string" and text:gsub("|", ""):sub(1, 120) or nil
  local next = ns.Suggest(p.said)
  local hint = (next == "invite" and " Sounds like a yes.") or (next == "skip" and " Sounds like a no.")
    or (next and ns.AnswerTopic(next) and (" They are asking about: " .. ns.AnswerTopic(next).label:lower() .. ".")) or ""
  ns.Print(p.name .. " answered your whisper. They are at the top of the list." .. hint)
  if TorchcallDB.opts.sound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then pcall(PlaySound, SOUNDKIT.TELL_MESSAGE) end
  changed()
end

function handlers.WHO_LIST_UPDATE()
  onWhoResults()
end

function handlers.GUILD_ROSTER_UPDATE()
  ns.ReadRoster()
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
  -- ask the game for the guild roster once, so recruits can be checked against it. A request
  -- for data: nobody is contacted.
  if C_Timer and C_Timer.After then
    C_Timer.After(12, function()
      if TorchcallDB and myGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
    end)
  end
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
for _, event in ipairs({ "PLAYER_LOGIN", "WHO_LIST_UPDATE", "CHAT_MSG_SYSTEM", "CHAT_MSG_WHISPER", "CHAT_MSG_ADDON", "GUILD_ROSTER_UPDATE" }) do
  pcall(frame.RegisterEvent, frame, event) -- an event this client lacks must not stop the rest
end
