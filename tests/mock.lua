-- Minimal stand-in for the WoW client API, enough to load and drive Torchcall offline.
local M = { now = 1000, wall = 1791400000, timers = {}, sentAddon = {}, sentChat = {}, sentWho = {}, invited = {},
            printed = {}, frames = {}, lockdown = false, inGuild = true, canInvite = true, myGuild = "The True Torchmen",
            myName = "Vesh Torchman", who = {}, whoTotal = nil, whoToUi = false, addonResult = 0, zone = "Durotar" }

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
function PlaySound() end
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

function GetUnitName(t) if t == "player" then return M.myName end end
function UnitName(t) if t == "player" then return M.myName end end
function GetGuildInfo(t) if t == "player" and M.inGuild then return M.myGuild, "Flamewarden", 1 end end
function IsInGuild() return M.inGuild end
function CanGuildInvite() return M.canInvite end

C_ChatInfo = {
  RegisterAddonMessagePrefix = function(p) M.prefix = p return 0 end,
  InChatMessagingLockdown = function() return M.lockdown end,
  SendAddonMessage = function(prefix, msg, channel) if M.lockdown then return 11 end if M.addonResult ~= 0 then return M.addonResult end M.sentAddon[#M.sentAddon + 1] = { prefix, msg, channel } return 0 end,
  SendChatMessage = function(msg, channel, lang, target)
    if M.chatError then error("blocked") end
    M.sentChat[#M.sentChat + 1] = { msg, channel, target }
  end,
}
C_GuildInfo = { Invite = function(name) M.invited[#M.invited + 1] = name end }
C_FriendList = {
  SetWhoToUi = function(on) M.whoToUi = on end,
  SendWho = function(text, origin) if M.whoError then error("blocked") end M.sentWho[#M.sentWho + 1] = text end,
  GetNumWhoResults = function() return math.min(#M.who, 50), M.whoTotal or #M.who end,
  GetWhoInfo = function(i) return M.who[i] end,
}
-- answer the search that was just sent with these players
function M.answerWho(players, total)
  M.who, M.whoTotal = players, total
  M.fire("WHO_LIST_UPDATE")
end
function M.player(name, guild, level, class)
  return { fullName = name, fullGuildName = guild or "", level = level or 10, raceStr = "Orc",
           classStr = class and (class:sub(1, 1) .. class:sub(2):lower()) or "Warrior", area = "Durotar",
           filename = class or "WARRIOR", gender = 2 }
end

-- frames --------------------------------------------------------------------
local frameMT = {}
frameMT.__index = function(self, key)
  local known = {
    RegisterEvent = function(f, e) f.__events[e] = true end,
    UnregisterEvent = function(f, e) f.__events[e] = nil end,
    SetScript = function(f, name, fn) f.__scripts[name] = fn end,
    GetScript = function(f, name) return f.__scripts[name] end,
    Show = function(f) local was = f.__shown f.__shown = true if not was and f.__scripts.OnShow then f.__scripts.OnShow(f) end end,
    Hide = function(f) f.__shown = false end,
    IsShown = function(f) return f.__shown end,
    SetText = function(f, t) assert(type(t) == "string" or type(t) == "number", "SetText needs text, got " .. type(t)) f.__text = t end,
    GetText = function(f) return f.__text end,
    GetName = function(f) return f.__name end,
    GetParent = function(f) return f.__parent end,
    GetWidth = function() return 140 end,
    GetCenter = function() return 0, 0 end,
    GetEffectiveScale = function() return 1 end,
    CreateFontString = function(f) return M.newFrame("FontString", nil, f) end,
    CreateTexture = function(f) return M.newFrame("Texture", nil, f) end,
    AddLine = function(f, text) assert(type(text) == "string") f.__lines[#f.__lines + 1] = text end,
    StartMoving = function() end, StopMovingOrSizing = function() end,
  }
  if known[key] then return known[key] end
  if key == "TitleText" or key == "TitleContainer" then return nil end
  if type(key) == "string" and key:match("^[A-Z]") then return function() end end -- any other widget method
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
    if f.__kind == "Button" and type(f.__text) == "string" and f.__text:sub(1, #label) == label and f.__scripts.OnClick then
      f.__scripts.OnClick(f, button or "LeftButton")
      return true
    end
  end
  return false
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
