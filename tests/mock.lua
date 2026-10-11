-- Minimal stand-in for the WoW client API, enough to load and drive Torchcall offline.
local M = { now = 1000, wall = 1791400000, timers = {}, sentAddon = {}, sentChat = {}, sentWho = {}, invited = {},
            printed = {}, frames = {}, lockdown = false, inGuild = true, canInvite = true, myGuild = "The True Torchmen",
            myName = "Vesh Torchman", who = {}, races = { { name = "Orc", ID = 2 }, { name = "Troll", ID = 8 }, { name = "Tauren", ID = 6 }, { name = "Undead", ID = 5 } }, whoTotal = nil, whoToUi = false, addonResult = 0, zone = "Durotar" }

-- secret values: any use other than passing them around blows up
local secretMT = {
  __index = function() error("indexed a secret value") end,
  __concat = function() error("concatenated a secret value") end,
  __lt = function() error("compared a secret value") end,
  __call = function() error("called a secret value") end,
  __tostring = function() return "<secret>" end,
}
function M.secret() return setmetatable({}, secretMT) end
function issecretvalue(v) return getmetatable(v) == secretMT end

function GetTime() return M.now end
function time() return M.wall end
function date() return "10-08 12:00:00" end
local realPrint = print
function print(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end M.printed[#M.printed + 1] = table.concat(t, " ") end
M.realPrint = realPrint
function strsplit(sep, s, limit)
  local out = {}
  while true do
    local at = s:find(sep, 1, true)
    if not at or (limit and #out + 1 >= limit) then out[#out + 1] = s break end
    out[#out + 1] = s:sub(1, at - 1)
    s = s:sub(at + 1)
  end
  return unpack(out)
end
function Ambiguate(n) return (n:gsub("%-.*$", "")) end
UNKNOWNOBJECT = "Unknown"
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
SOUNDKIT = { TELL_MESSAGE = 3081 }
function PlaySound(id, extra) assert(type(id) == "number" and extra == nil, "PlaySound takes the sound id only") end
UISpecialFrames = {}
SlashCmdList = {}
function GetBuildInfo() return "1.60.1", "70245", "Oct 6 2026", 16001 end
function GetCursorPosition() return 0, 0 end
function GetRealZoneText() return M.zone end
Enum = { SocialWhoOrigin = { Social = 1 } }
ERR_GUILD_JOIN_S = "%s has joined the guild."
ERR_GUILD_DECLINE_S = "%s declines your guild invitation."

C_Timer = {
  After = function(delay, fn) M.timers[#M.timers + 1] = { at = M.now + delay, fn = fn } end,
  NewTicker = function(period, fn) M.timers[#M.timers + 1] = { at = M.now + period, fn = fn, period = period } end,
}
-- advance the clock, running timers in order
function M.advance(seconds)
  local target = M.now + seconds
  while true do
    local best
    for i, t in ipairs(M.timers) do
      if t.at <= target and (not best or t.at < M.timers[best].at) then best = i end
    end
    if not best then break end
    local t = table.remove(M.timers, best)
    M.wall = M.wall + (t.at - M.now)
    M.now = t.at
    if t.period then M.timers[#M.timers + 1] = { at = t.at + t.period, fn = t.fn, period = t.period } end
    t.fn()
  end
  M.wall = M.wall + (target - M.now)
  M.now = target
end

-- the party or raid: M.group = { { name = , guild = , class = "MAGE", level = 12 }, ... }, M.raid = true for a raid
-- the guild roster: M.roster = { "Name", ... }
M.group, M.raid, M.roster = {}, false, {}
local function member(t)
  local kind, i = tostring(t):match("^(%a+)(%d+)$")
  if (kind == "party" and not M.raid) or (kind == "raid" and M.raid) then return M.group[tonumber(i)] end
end
function GetUnitName(t) if t == "player" then return M.myName end local m = member(t) return m and m.name end
function UnitName(t) if t == "player" then return M.myName end local m = member(t) return m and m.name end
function GetGuildInfo(t)
  if t == "player" then if M.inGuild then return M.myGuild, "Flamewarden", 1 end return nil end
  local m = member(t)
  if m and m.guild == "secret" then return M.secret() end
  return m and m.guild or nil
end
function IsInRaid() return M.raid end
function GetNumGroupMembers() return #M.group > 0 and #M.group + 1 or 0 end
function UnitExists(t) return t == "player" or member(t) ~= nil end
function UnitIsPlayer(t) local m = member(t) return t == "player" or (m ~= nil and not m.npc) end
function UnitClass(t) local m = member(t) if m then return (m.class or "WARRIOR"):sub(1, 1) .. (m.class or "WARRIOR"):sub(2):lower(), m.class or "WARRIOR" end end
function UnitLevel(t) local m = member(t) return m and (m.level or 10) end
function UnitRace(t) local m = member(t) return m and "Orc" end
function GetNumGuildMembers() return #M.roster end
-- the guild window's two texts
M.guildInfo, M.guildMotd, M.canEditInfo, M.canEditMotd = "", "", true, true
function CanEditGuildInfo() return M.canEditInfo end
function CanEditMOTD() return M.canEditMotd end
C_GuildInfoText = {
  GetInfoText = function() return M.guildInfo end,
  SetInfoText = function(t) assert(type(t) == "string" and #t <= 500, "guild info too long") if M.guard then M.guard("GUILDTEXT", "info", t) end M.guildInfo = t end,
  GetMOTD = function() return M.guildMotd end,
  SetMOTD = function(t) assert(type(t) == "string" and #t <= 128, "motd too long") if M.guard then M.guard("GUILDTEXT", "motd", t) end M.guildMotd = t end,
}
function GetGuildRosterInfo(i) if M.rosterHidden then return M.secret() end return M.roster[i] end
function IsInGuild() return M.inGuild end
function CanGuildInvite() return M.canInvite end

C_ChatInfo = {
  RegisterAddonMessagePrefix = function(p) M.prefix = p return 0 end,
  InChatMessagingLockdown = function() return M.lockdown end,
  SendAddonMessage = function(prefix, msg, channel) if M.lockdown then return 11 end if M.addonResult ~= 0 then return M.addonResult end M.sentAddon[#M.sentAddon + 1] = { prefix, msg, channel } return 0 end,
  SendChatMessage = function(msg, channel, lang, target)
    if M.chatError then error("blocked") end
    assert(type(msg) == "string" and #msg <= 255, "chat message too long or not text")
    if M.guard then M.guard(channel, target or msg, msg) end
    M.sentChat[#M.sentChat + 1] = { msg, channel, target }
  end,
}
C_GuildInfo = { Invite = function(name)
  if M.inviteError then error("blocked") end
  if M.guard then M.guard("INVITE", name) end
  M.invited[#M.invited + 1] = name
end }
for k, v in pairs(C_GuildInfoText) do C_GuildInfo[k] = v end
-- the game's own "is this name in my guild" check; M.noMemberCheck removes it, as on a client without one
function C_GuildInfo.MemberExistsByName(name)
  if M.rosterHidden then return M.secret() end
  for _, n in ipairs(M.roster) do if n == name then return true end end
  return false
end
function C_GuildInfo.GuildRoster() M.rosterAsked = (M.rosterAsked or 0) + 1 end
local function freshFriendList() return {
  SetWhoToUi = function(on) M.whoToUi = on end,
  SendWho = function(text, origin)
    if M.whoError then error("blocked") end
    if M.guard and text ~= "someone else's search" then M.guard("who", text) end
    M.sentWho[#M.sentWho + 1] = text
  end,
  GetNumWhoResults = function() return math.min(#M.who, 50), M.whoTotal or #M.who end,
  GetWhoInfo = function(i) return M.who[i] end,
  GetWhoRaceFilters = function() return M.races end,
} end
C_FriendList = freshFriendList()
-- answer the search that was just sent with these players
function M.answerWho(players, total)
  M.who, M.whoTotal = players, total
  M.fire("WHO_LIST_UPDATE")
end
function M.player(name, guild, level, class, race)
  return { fullName = name, fullGuildName = guild or "", level = level or 10, raceStr = race or "Orc",
           classStr = class and (class:sub(1, 1) .. class:sub(2):lower()) or "Warrior", area = "Durotar",
           filename = class or "WARRIOR", gender = 2 }
end

-- frames --------------------------------------------------------------------
-- Each widget type answers only the methods that type really has on this client (checked
-- against Blizzard's interface source). Calling anything else is an error, the same as in game.
local function noop() end
local REGION = { SetPoint = noop, ClearAllPoints = noop, SetAllPoints = noop, SetSize = noop, SetWidth = noop, SetHeight = noop,
  GetWidth = function() return 140 end, GetCenter = function() return 0, 0 end, GetEffectiveScale = function() return 1 end,
  Show = function(f) local was = f.__shown f.__shown = true if not was and f.__scripts.OnShow then f.__scripts.OnShow(f) end end,
  Hide = function(f) f.__shown = false end, IsShown = function(f) return f.__shown end,
  GetName = function(f) return f.__name end, GetParent = function(f) return f.__parent end }
local FRAME = { RegisterEvent = function(f, e) f.__events[e] = true end, UnregisterEvent = function(f, e) f.__events[e] = nil end,
  SetScript = function(f, name, fn) assert(fn == nil or type(fn) == "function", "SetScript needs a function") f.__scripts[name] = fn end,
  GetScript = function(f, name) return f.__scripts[name] end,
  CreateFontString = function(f) return M.newFrame("FontString", nil, f) end,
  CreateTexture = function(f) return M.newFrame("Texture", nil, f) end,
  EnableMouse = noop, EnableMouseWheel = noop, SetFrameStrata = noop, SetFrameLevel = noop, SetClampedToScreen = noop,
  SetMovable = noop, RegisterForDrag = noop, StartMoving = noop, StopMovingOrSizing = noop }
local function setText(f, t) assert(type(t) == "string" or type(t) == "number", "SetText needs text, got " .. type(t)) f.__text = t end
local function getText(f) return f.__text end
local EXTRA = {
  Frame = {},
  Button = { SetText = setText, GetText = getText, RegisterForClicks = noop, LockHighlight = function(f) f.__lit = true end, UnlockHighlight = function(f) f.__lit = false end, SetHighlightTexture = noop,
             Enable = function(f) f.__off = false end, Disable = function(f) f.__off = true end, IsEnabled = function(f) return not f.__off end },
  EditBox = { SetText = setText, GetText = getText, SetAutoFocus = noop, SetMaxLetters = noop, HasFocus = function() return false end, ClearFocus = noop },
  GameTooltip = { SetOwner = noop, Show = REGION.Show, AddLine = function(f, text) assert(type(text) == "string") f.__lines[#f.__lines + 1] = text end },
  FontString = { SetText = setText, GetText = getText, SetJustifyH = noop, SetJustifyV = noop, SetWordWrap = noop },
  Texture = { SetTexture = noop, SetColorTexture = noop },
}
local frameMT = {}
frameMT.__index = function(self, key)
  local kind = self.__kind
  local found = (EXTRA[kind] or {})[key] or REGION[key]
  if not found and kind ~= "FontString" and kind ~= "Texture" then found = FRAME[key] end
  if found then return found end
  if key == "SetBackdrop" and self.__template == "BackdropTemplate" then return noop end
  if type(key) == "string" and key:match("^[A-Z]") and key ~= "TitleText" and key ~= "TitleContainer" and key ~= "SetBackdrop" then
    error(kind .. " has no method " .. key, 2)
  end
  return nil
end
function M.newFrame(kind, name, parent, template)
  if template == "BasicFrameTemplateWithInset" and M.failTemplate then error("no such template") end
  local f = setmetatable({ __events = {}, __scripts = {}, __shown = true, __name = name, __parent = parent, __lines = {}, __kind = kind, __template = template }, frameMT)
  M.frames[#M.frames + 1] = f
  if name then _G[name] = f end
  return f
end
function CreateFrame(kind, name, parent, template) return M.newFrame(kind, name, parent, template) end
UIParent = M.newFrame("Frame", "UIParent")
Minimap = M.newFrame("Frame", "Minimap")
GameTooltip = M.newFrame("GameTooltip", "GameTooltip")

function M.fire(event, ...)
  for _, f in ipairs(M.frames) do
    if f.__events[event] and f.__scripts.OnEvent then f.__scripts.OnEvent(f, event, ...) end
  end
end

-- press the first button whose label starts with this text
function M.click(label, button)
  for _, f in ipairs(M.frames) do
    local text = type(f.__text) == "string" and f.__text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    -- a hidden or disabled button cannot be pressed, and neither can one inside a hidden panel
    local visible, up = not f.__off, f
    while visible and up do visible = up.__shown ~= false up = up.__parent end
    if visible and f.__kind == "Button" and text and text:sub(1, #label) == label and f.__scripts.OnClick then
      f.__scripts.OnClick(f, button or "LeftButton")
      return true
    end
  end
  return false
end

-- start over as a fresh login: no frames, timers or records, saved variables kept unless asked
function M.reset(wipe)
  for _, f in ipairs(M.frames) do if f.__name then _G[f.__name] = nil end end
  M.frames, M.timers = {}, {}
  M.sentAddon, M.sentChat, M.sentWho, M.invited, M.printed = {}, {}, {}, {}, {}
  M.lockdown, M.inGuild, M.canInvite, M.addonResult = false, true, true, 0
  M.group, M.raid, M.roster, M.rosterHidden = {}, false, {}, nil
  M.chatError, M.whoError, M.inviteError, M.who, M.whoTotal, M.whoToUi = nil, nil, nil, {}, nil, false
  UIParent = M.newFrame("Frame", "UIParent")
  Minimap = M.newFrame("Frame", "Minimap")
  GameTooltip = M.newFrame("GameTooltip", "GameTooltip")
  SlashCmdList = {}
  C_FriendList = freshFriendList()
  WhoFrame = nil
  if wipe then TorchcallDB = nil end
end

-- Bindings.xml: every command a key can run must compile and must only call functions that exist.
function M.bindings(dir)
  local f = assert(io.open(dir .. "/Bindings.xml"))
  local xml = f:read("*a")
  f:close()
  local out = {}
  for name, attrs, body in xml:gmatch('<Binding name="([%w_]+)"([^>]*)>(.-)</Binding>') do
    out[#out + 1] = { name = name, category = attrs:match('category="([^"]+)"'), header = attrs:match('header="([^"]+)"'),
                      run = assert(loadstring(body), "binding " .. name .. " does not compile") }
  end
  return out
end

-- the client's post-hook: the original runs, then the hook, and a hook error never reaches the caller
function hooksecurefunc(tbl, name, hook)
  local original = assert(tbl[name], "nothing to hook")
  tbl[name] = function(...)
    original(...)
    pcall(hook, ...)
  end
end

function M.load(dir, files)
  local ns = {}
  for _, file in ipairs(files) do
    local chunk = assert(loadfile(dir .. "/" .. file))
    chunk("Torchcall", ns)
  end
  M.ns = ns
  return ns
end

return M
