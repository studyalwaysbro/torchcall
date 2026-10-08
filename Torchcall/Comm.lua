-- Torchcall guild sync: recruiters in the same guild tell each other who has already
-- been contacted, on the hidden addon channel, so nobody gets the same pitch twice.
-- Only names travel. Nothing here is visible in chat, and nothing here contacts a player.

local _, ns = ...
local plain, try = ns.plain, ns.try

local PREFIX = "Torchcall"
local PROTO = 1
local SHARE_MAX_AGE = 14 * 86400 -- how far back a login catch-up goes
local CHUNK_BYTES = 200
local OUTBOX_CAP = 400       -- messages waiting to go out
local PER_WINDOW, WINDOW = 4, 5 -- the game throttles a burst of addon messages
local SHARED = { whispered = true, invited = true, joined = true, declined = true, skipped = true }

local Comm = { handlers = {} }
ns.Comm = Comm

local outbox, lastReply, helloTries = {}, -1000, 0
-- The game does not always report our own name the way we read it, so every message
-- carries a random tag for this session and we drop the ones that carry ours.
local token = ("%06x"):format(math.random(0, 0xFFFFFF))

local function send(msg)
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
  if not plain(try(IsInGuild)) or ns.ChatLockedDown() then return false end
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "GUILD")
  res = plain(res)
  -- newer clients return a result code (0 = sent), older ones true, some nothing
  local sent = ok and (res == nil or res == true or res == 0)
  if not sent then ns.Log("comm", "send refused: " .. tostring(res)) end
  return sent
end

-- A few every five seconds; whatever a lockdown or a throttle holds back goes out on the ticker.
local windowStart, windowSent = -1000, 0
local function flush()
  if GetTime() - windowStart >= WINDOW then windowStart, windowSent = GetTime(), 0 end
  while outbox[1] and windowSent < PER_WINDOW do
    if not send(outbox[1]) then return end
    table.remove(outbox, 1)
    windowSent = windowSent + 1
  end
end

local function post(msg)
  if #outbox >= OUTBOX_CAP then
    ns.Log("comm", "outbox full, a contact was not shared")
    return
  end
  outbox[#outbox + 1] = msg
  flush()
end

local function validName(name)
  return type(name) == "string" and name ~= "" and #name <= 48 and not name:find("[|;,]")
end

-- Called when this player contacts or skips someone.
function Comm.Tell(name)
  if not validName(name) or not ns.MyGuild() then return end
  post(table.concat({ "C", PROTO, token, name }, ";"))
end

local function shareRecent()
  local now, names = time(), {}
  for name, p in pairs(TorchcallDB.prospects) do
    if SHARED[p.status] and not p.by and now - (p.t or 0) <= SHARE_MAX_AGE and validName(name) then
      names[#names + 1] = { name, p.t or 0 }
    end
  end
  table.sort(names, function(a, b) return a[2] > b[2] end)
  local head, chunk, size = table.concat({ "L", PROTO, token }, ";") .. ";", {}, 0
  for _, entry in ipairs(names) do
    if size + #entry[1] + 1 > CHUNK_BYTES then
      post(head .. table.concat(chunk, ","))
      chunk, size = {}, 0
    end
    chunk[#chunk + 1] = entry[1]
    size = size + #entry[1] + 1
  end
  if #chunk > 0 then post(head .. table.concat(chunk, ",")) end
end

local function hello()
  -- the guild name is not known for the first moments after login
  if not ns.MyGuild() or not send(table.concat({ "H", PROTO, token }, ";")) then
    helloTries = helloTries + 1
    if helloTries < 6 and plain(try(IsInGuild)) then C_Timer.After(15, hello) end
  end
end

-- A guildmate already reached this player: keep them off our list.
local function markTaken(name, by)
  if not validName(name) or name == ns.myName then return false end
  local list = TorchcallDB.prospects
  local p = list[name]
  if p and p.status ~= "new" then return false end
  TorchcallDB.contacted[name] = time()
  list[name] = { name = name, status = "taken", by = by, t = time(),
                 level = p and p.level, class = p and p.class, classStr = p and p.classStr, zone = p and p.zone }
  return true
end

function Comm.handlers.CHAT_MSG_ADDON(prefix, text, channel, sender)
  prefix, text, channel, sender = plain(prefix), plain(text), plain(channel), plain(sender)
  if prefix ~= PREFIX or channel ~= "GUILD" then return end
  if type(text) ~= "string" or type(sender) ~= "string" then return end
  local kind, proto, tag, body = strsplit(";", text, 4)
  if tonumber(proto) ~= PROTO or tag == token then return end
  local by = sender:gsub("|", ""):sub(1, 48)
  if kind == "H" then
    if GetTime() - lastReply > 30 then
      lastReply = GetTime()
      C_Timer.After(1 + math.random() * 5, shareRecent) -- spread replies out
    end
  elseif kind == "C" then
    if markTaken(body, by) and ns.OnChanged then ns.OnChanged() end
  elseif kind == "L" and type(body) == "string" then
    local any = false
    for name in body:gmatch("[^,]+") do
      if markTaken(name, by) then any = true end
    end
    if any and ns.OnChanged then ns.OnChanged() end
  end
end

function Comm.Init()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
  end
  C_Timer.After(12, hello)
  C_Timer.NewTicker(WINDOW, flush)
end
