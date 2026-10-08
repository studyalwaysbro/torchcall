-- Torchcall core: who searches, the prospect list, whispers and guild invites.
--
-- Every who search, whisper and guild invite in this file runs straight from a button
-- press or a typed command, one press for one action. Nothing here is ever called from
-- a timer or an event, so the addon cannot contact anyone on its own. That is deliberate:
-- the client restricts these calls, and one person choosing each contact is the
-- difference between recruiting and spam.
--
-- A who search returns at most 50 players, so a busy level range is split into smaller
-- ranges (and then by class) and queued. Each queued search still needs its own press.
-- Players are keyed by name: who results carry no GUID, and Forever has no realms.

local ADDON, ns = ...

ns.VERSION = "1.0.0"

local WHO_GAP = 5             -- seconds between who searches (the server throttles faster ones)
local WHO_TIMEOUT = 6         -- how long to wait for an answer before giving the search back
local WHO_MAX = 50            -- most results one search can return
local INVITE_GAP = 2
local NEW_MAX_AGE = 12 * 3600 -- an uncontacted prospect was only known to be online when seen
local KEPT_MAX_AGE = 60 * 86400
local PROSPECT_CAP, LOG_CAP = 3000, 150

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
  if type(guild) ~= "string" or guild ~= "" then
    -- in a guild (or the game would not say): not a prospect, and no longer one if they were
    if known and known.status == "new" then TorchcallDB.prospects[name] = nil end
    return false
  end
  local level, class = plain(info.level), plain(info.filename)
  local entry = known or { name = name, status = "new" }
  entry.level = type(level) == "number" and level or entry.level or 0
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

-- kind "new" = waiting for a first contact (people who answered come first);
-- kind "contacted" = everyone already reached, newest first.
function ns.List(kind)
  dropStale()
  local rows = {}
  for _, p in pairs(TorchcallDB.prospects) do
    if kind == "new" then
      if p.status == "new" or answered(p) then rows[#rows + 1] = p end
    elseif STATUS_ORDER[p.status] and not answered(p) then
      rows[#rows + 1] = p
    end
  end
  table.sort(rows, function(a, b)
    if kind == "new" then
      if answered(a) ~= answered(b) then return answered(a) end
      if (a.seen or 0) ~= (b.seen or 0) then return (a.seen or 0) > (b.seen or 0) end
      if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
    elseif (a.t or 0) ~= (b.t or 0) then
      return (a.t or 0) > (b.t or 0)
    end
    return a.name < b.name
  end)
  return rows
end

function ns.Counts()
  local c = { new = 0, whispered = 0, invited = 0, joined = 0, declined = 0, taken = 0, skipped = 0, guilded = 0, replied = 0 }
  for _, p in pairs(TorchcallDB.prospects) do
    c[p.status] = (c[p.status] or 0) + 1
    if answered(p) then c.replied = c.replied + 1 end
  end
  return c
end

-- ---------------------------------------------------------------------------
-- Who searches
-- ---------------------------------------------------------------------------

local queue, pending, lastWho = {}, nil, -WHO_GAP
local searchZone -- zone every search in the current plan is limited to, or nil
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
  if q.zone then text = text .. ' z-"' .. q.zone .. '"' end
  return text
end
ns.QueryText = queryText

local function describe(q)
  local text = (q.lo == q.hi) and ("level " .. q.lo) or ("levels " .. q.lo .. " to " .. q.hi)
  if q.class then text = text .. ", " .. className(q.class) end
  if q.zone then text = text .. ", " .. q.zone end
  return text
end

local function setWhoToUi(on)
  if C_FriendList and C_FriendList.SetWhoToUi then pcall(C_FriendList.SetWhoToUi, on) end
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
  local wait = WHO_GAP - (GetTime() - lastWho)
  if wait > 0 then
    note(("The game limits who searches. Try again in %d seconds."):format(math.ceil(wait)))
    return false
  end
  if not (C_FriendList and C_FriendList.SendWho) then
    note("This client has no who search for addons.")
    return false
  end
  -- results only arrive as an event while the client is told to send them to the UI
  setWhoToUi(true)
  local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social
  local ok, err = pcall(C_FriendList.SendWho, queryText(q), origin)
  if not ok then
    setWhoToUi(false)
    ns.Log("who", err)
    note("The game refused that search.")
    return false
  end
  table.remove(queue, 1)
  lastWho = GetTime()
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

-- Starts a fresh plan and sends its first search.
function ns.StartSearch(lo, hi, class, zone)
  if pending then
    note("Still waiting for the last search. Try again in a moment.")
    return false
  end
  lo, hi = math.floor(tonumber(lo) or 1), math.floor(tonumber(hi) or 60)
  if lo < 1 then lo = 1 end
  if hi > 80 then hi = 80 end
  if hi < lo then lo, hi = hi, lo end
  local o = TorchcallDB.opts
  o.lo, o.hi = lo, hi
  searchZone = (type(zone) == "string" and zone ~= "") and zone or nil
  queue = { { lo = lo, hi = hi, class = class, zone = searchZone } }
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
  local added = 0
  for i = 1, shown do
    if addFromWho(try(C_FriendList.GetWhoInfo, i)) then added = added + 1 end
  end
  TorchcallDB.stats.found = TorchcallDB.stats.found + added
  local text = ("%s: %d online, %d new without a guild."):format(describe(q), total, added)
  if total > shown or shown >= WHO_MAX then
    if q.hi > q.lo then
      local mid = math.floor((q.lo + q.hi) / 2)
      table.insert(queue, 1, { lo = mid + 1, hi = q.hi, class = q.class, zone = q.zone })
      table.insert(queue, 1, { lo = q.lo, hi = mid, class = q.class, zone = q.zone })
      text = text .. " Too many for one search, so it was split."
    elseif not q.class then
      for i = #ns.CLASSES, 1, -1 do
        table.insert(queue, 1, { lo = q.lo, hi = q.hi, class = ns.CLASSES[i], zone = q.zone })
      end
      text = text .. " Too many for one search, so it was split by class."
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
  local wait = db.opts.gap - (GetTime() - lastWhisper)
  if wait > 0 then return false, ("Easy. Next whisper in %d seconds."):format(math.ceil(wait)) end
  local limit = not followup and overLimit()
  if limit then return false, limit end
  local text = ns.Render(followup and db.reply or db.templates[db.opts.template] or db.templates[1], p)
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
  if not followup then
    p.status, p.t = "whispered", time()
    db.stats.whispered = db.stats.whispered + 1
    countContact()
    if ns.Comm then ns.Comm.Tell(name) end
  else
    p.linked = true
  end
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
  if ns.Comm then ns.Comm.Tell(name) end
  changed()
  return true
end

function ns.Forget(name)
  local p = findProspect(name)
  if not p then return false end
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
  if not p then return false, "Nobody is waiting. Run a search." end
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
        -- logged off since the search: forget them, a later search finds them again
        db.prospects[p.name] = nil
      elseif outcome == "joined" then
        if p.status ~= "joined" then db.stats.joined = db.stats.joined + 1 end
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
  if not p.replied then TorchcallDB.stats.replied = TorchcallDB.stats.replied + 1 end
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
