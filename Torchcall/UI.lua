-- Torchcall window, minimap button and slash commands.

local _, ns = ...
local plain, try = ns.plain, ns.try

local UI = {}
ns.UI = UI

local ICON = "Interface\\Icons\\INV_Torch_Lit"
local GOLD, WHITE, GREY, ORANGE, GREEN = "|cffffd100", "|cffffffff", "|cff9d9d9d", "|cffff7d0a", "|cff40d040"
local ROWS, ROW_HEIGHT = 12, 21
local COLS = { { "Player", 150, "LEFT" }, { "Lvl", 28, "RIGHT" }, { "Class", 70, "LEFT" },
               { "Zone", 130, "LEFT" }, { "Status", 86, "LEFT" } }
local MODES = { "whisper", "invite" }
local MODE_LABEL = { whisper = "Next does: whisper", invite = "Next does: invite" }
local STATUS_LABEL = { new = "new", whispered = "whispered", invited = "invited", joined = GREEN .. "joined|r",
                       declined = "declined", taken = "guildmate has it", guilded = "in a guild", skipped = "skipped" }

local opts
local main, minimapButton
local currentTab, offset = 1, 0
local searchClass, zoneOnly = nil, false

local function classColored(name, class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if c and c.r then
    return ("|cff%02x%02x%02x%s|r"):format(c.r * 255, c.g * 255, c.b * 255, name)
  end
  return name
end

local function ago(t)
  if not t then return "" end
  local s = time() - t
  if s < 60 then return "now" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  if s < 86400 then return math.floor(s / 3600) .. "h" end
  return math.floor(s / 86400) .. "d"
end

-- Runs one of the core actions and prints why when it does not go through.
local function act(fn, ...)
  local ok, why = fn(...)
  if why then ns.Print(why) end
  UI.Refresh()
  return ok
end

local function currentZone()
  local zone = plain(try(GetRealZoneText))
  if type(zone) == "string" and zone ~= "" then return zone end
end

local planKey -- the filters the queued searches were built from

-- What the search controls say right now, and one string to compare plans by.
local function searchInputs()
  local lo = main and tonumber(main.lo:GetText()) or opts.lo
  local hi = main and tonumber(main.hi:GetText()) or opts.hi
  local zone = zoneOnly and currentZone() or nil
  return lo, hi, zone, table.concat({ tostring(lo), tostring(hi), searchClass or "", zone or "" }, "|")
end

local function startSearch()
  if ns.SearchPending() then return end
  local lo, hi, zone, key = searchInputs()
  if ns.QueueSize() > 0 and key == planKey then
    ns.NextSearch()
  else -- nothing queued, or the filters changed: start over
    planKey = key
    ns.StartSearch(lo, hi, searchClass, zone)
  end
  UI.Refresh()
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function makeButton(parent, text, width, height)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, height or 22)
  b:SetText(text)
  return b
end

local function makeLabel(parent, font, text)
  local s = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
  if text then s:SetText(text) end
  return s
end

local function makeEdit(parent, width, maxLetters)
  local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(width, 20)
  e:SetAutoFocus(false)
  e:SetMaxLetters(maxLetters)
  e:SetScript("OnEscapePressed", e.ClearFocus)
  e:SetScript("OnEnterPressed", e.ClearFocus)
  return e
end

local function showTooltip(owner, title, ...)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:AddLine(title)
  for i = 1, select("#", ...) do
    local line = select(i, ...)
    if line then GameTooltip:AddLine(line, 1, 1, 1, true) end
  end
  GameTooltip:Show()
end

local function buildRow(list, r)
  local row = CreateFrame("Frame", nil, list)
  row:SetPoint("TOPLEFT", 0, -r * ROW_HEIGHT - 2)
  row:SetPoint("TOPRIGHT", 0, -r * ROW_HEIGHT - 2)
  row:SetHeight(ROW_HEIGHT)
  row:EnableMouse(true)
  if r % 2 == 0 then
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, 0.04)
  end
  row.cells = {}
  local x = 0
  for i, col in ipairs(COLS) do
    local cell = makeLabel(row, "GameFontHighlightSmall")
    cell:SetPoint("LEFT", row, "LEFT", x, 0)
    cell:SetWidth(col[2])
    cell:SetJustifyH(col[3])
    cell:SetWordWrap(false)
    row.cells[i] = cell
    x = x + col[2] + 8
  end
  row.skip = makeButton(row, "Skip", 42, 19)
  row.skip:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row.skip:SetScript("OnClick", function() if row.name then act(ns.Skip, row.name) end end)
  row.invite = makeButton(row, "Invite", 54, 19)
  row.invite:SetPoint("RIGHT", row.skip, "LEFT", -3, 0)
  row.invite:SetScript("OnClick", function() if row.name then act(ns.Invite, row.name) end end)
  row.whisper = makeButton(row, "Whisper", 62, 19)
  row.whisper:SetPoint("RIGHT", row.invite, "LEFT", -3, 0)
  row.whisper:SetScript("OnClick", function()
    if row.name then act(ns.Whisper, row.name, row.followup) end
  end)
  row:SetScript("OnEnter", function(self)
    local p = self.name and TorchcallDB.prospects[self.name]
    if not p then return end
    showTooltip(self, p.name,
      p.race and (p.race .. " " .. (p.classStr or "")) or p.classStr,
      p.zone and ("Seen in " .. p.zone .. ", " .. ago(p.seen) .. " ago") or nil,
      p.by and ("Contacted by " .. p.by) or nil,
      p.said and ('They said: "' .. p.said .. '"') or nil)
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

local function buildMessagePanel(f)
  local panel = CreateFrame("Frame", nil, f)
  panel:SetPoint("TOPLEFT", 16, -138)
  panel:SetPoint("BOTTOMRIGHT", -16, 48)

  panel.title = makeLabel(panel, "GameFontNormal")
  panel.title:SetPoint("TOPLEFT", 0, 0)
  local prev = makeButton(panel, "<", 26)
  prev:SetPoint("TOPRIGHT", -30, 4)
  local nextB = makeButton(panel, ">", 26)
  nextB:SetPoint("LEFT", prev, "RIGHT", 4, 0)
  local function step(by)
    local n = #TorchcallDB.templates
    opts.template = (opts.template - 1 + by) % n + 1
    UI.Refresh()
  end
  prev:SetScript("OnClick", function() step(-1) end)
  nextB:SetScript("OnClick", function() step(1) end)

  panel.edit = makeEdit(panel, 640, 255)
  panel.edit:SetPoint("TOPLEFT", 6, -24)
  panel.edit:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    TorchcallDB.templates[opts.template] = self:GetText() or ""
    UI.RefreshMessage()
  end)
  panel.count = makeLabel(panel, "GameFontDisableSmall")
  panel.count:SetPoint("TOPLEFT", 0, -50)
  local previewLabel = makeLabel(panel, "GameFontNormalSmall", "What the next player on the list would read")
  previewLabel:SetPoint("TOPLEFT", 0, -72)
  panel.preview = makeLabel(panel, "GameFontHighlight")
  panel.preview:SetPoint("TOPLEFT", 0, -88)
  panel.preview:SetPoint("TOPRIGHT", 0, -88)
  panel.preview:SetHeight(56)
  panel.preview:SetJustifyH("LEFT")
  panel.preview:SetJustifyV("TOP")
  panel.preview:SetWordWrap(true)

  local replyLabel = makeLabel(panel, "GameFontNormal", "Follow-up, sent by the Link button to someone who answered")
  replyLabel:SetPoint("TOPLEFT", 0, -160)
  panel.reply = makeEdit(panel, 640, 255)
  panel.reply:SetPoint("TOPLEFT", 6, -184)
  panel.reply:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    TorchcallDB.reply = self:GetText() or ""
    UI.RefreshMessage()
  end)
  panel.replyCount = makeLabel(panel, "GameFontDisableSmall")
  panel.replyCount:SetPoint("TOPLEFT", 0, -210)

  local tokens = makeLabel(panel, "GameFontDisableSmall",
    "You can use {name} {fullname} {level} {class} {zone} {guild}. The game cuts a message at 255 characters.")
  tokens:SetPoint("BOTTOMLEFT", 0, 30)
  local restore = makeButton(panel, "Restore the original messages", 220)
  restore:SetPoint("BOTTOMLEFT", 0, 0)
  restore:SetScript("OnClick", function()
    TorchcallDB.templates = {}
    for i, t in ipairs(ns.TEMPLATES) do TorchcallDB.templates[i] = t end
    TorchcallDB.reply = ns.REPLY
    opts.template = 1
    UI.Refresh()
  end)
  return panel
end

local function buildMain()
  local ok, f = pcall(CreateFrame, "Frame", "TorchcallFrame", UIParent, "BasicFrameTemplateWithInset")
  if not ok or not f then
    f = CreateFrame("Frame", "TorchcallWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    if f.SetBackdrop then
      f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
                      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    end
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
  end
  f:SetSize(700, 470)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()
  if f:GetName() and UISpecialFrames then table.insert(UISpecialFrames, f:GetName()) end

  local title = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
  if not title then
    title = makeLabel(f, "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
  end
  title:SetText("Torchcall  |cff9d9d9dguild recruiting|r")

  f.summary = makeLabel(f, "GameFontHighlight")
  f.summary:SetPoint("TOPLEFT", 16, -34)
  f.summary:SetPoint("TOPRIGHT", -16, -34)
  f.summary:SetJustifyH("LEFT")
  f.summary:SetWordWrap(false)

  -- search row
  local levelLabel = makeLabel(f, "GameFontNormalSmall", "Level")
  levelLabel:SetPoint("TOPLEFT", 16, -64)
  f.lo = makeEdit(f, 30, 2)
  f.lo:SetPoint("LEFT", levelLabel, "RIGHT", 10, 0)
  local toLabel = makeLabel(f, "GameFontNormalSmall", "to")
  toLabel:SetPoint("LEFT", f.lo, "RIGHT", 6, 0)
  f.hi = makeEdit(f, 30, 2)
  f.hi:SetPoint("LEFT", toLabel, "RIGHT", 10, 0)
  f.lo:SetText(tostring(opts.lo))
  f.hi:SetText(tostring(opts.hi))

  f.class = makeButton(f, "", 130)
  f.class:SetPoint("LEFT", f.hi, "RIGHT", 12, 0)
  f.class:RegisterForClicks("AnyUp")
  f.class:SetScript("OnClick", function(_, button)
    local at = 0
    for i, token in ipairs(ns.CLASSES) do if token == searchClass then at = i end end
    at = (at + (button == "RightButton" and -1 or 1)) % (#ns.CLASSES + 1)
    searchClass = ns.CLASSES[at]
    UI.Refresh()
  end)
  f.zone = makeButton(f, "", 130)
  f.zone:SetPoint("LEFT", f.class, "RIGHT", 6, 0)
  f.zone:SetScript("OnClick", function() zoneOnly = not zoneOnly; UI.Refresh() end)
  f.search = makeButton(f, "Search", 150)
  f.search:SetPoint("LEFT", f.zone, "RIGHT", 6, 0)
  f.search:SetScript("OnClick", startSearch)
  f.search:SetScript("OnEnter", function(self)
    showTooltip(self, "Search",
      "Asks the game who is online in that level range and keeps the players with no guild.",
      "One search returns at most 50 players. A busy range is split into smaller searches, and each one needs its own press.")
  end)
  f.search:SetScript("OnLeave", function() GameTooltip:Hide() end)

  f.note = makeLabel(f, "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", 16, -90)
  f.note:SetPoint("TOPRIGHT", -16, -90)
  f.note:SetJustifyH("LEFT")
  f.note:SetWordWrap(false)

  f.tabs = {}
  for i, label in ipairs({ "Prospects", "Contacted", "Message" }) do
    local b = makeButton(f, label, 120)
    b:SetPoint("TOPLEFT", 14 + (i - 1) * 124, -108)
    b:SetScript("OnClick", function()
      currentTab, offset = i, 0
      UI.Refresh()
    end)
    f.tabs[i] = b
  end

  local list = CreateFrame("Frame", nil, f)
  list:SetPoint("TOPLEFT", 16, -138)
  list:SetPoint("TOPRIGHT", -16, -138)
  list:SetHeight((ROWS + 1) * ROW_HEIGHT + 4)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - delta * 3
    UI.Refresh()
  end)
  f.list = list
  local x = 0
  for _, col in ipairs(COLS) do
    local head = makeLabel(list, "GameFontNormalSmall", col[1])
    head:SetPoint("TOPLEFT", x, -3)
    head:SetWidth(col[2])
    head:SetJustifyH(col[3])
    x = x + col[2] + 8
  end
  f.rows = {}
  for r = 1, ROWS do f.rows[r] = buildRow(list, r) end
  f.empty = makeLabel(list, "GameFontDisable")
  f.empty:SetPoint("CENTER", 0, 0)
  f.count = makeLabel(f, "GameFontDisableSmall")
  f.count:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, -2)

  f.message = buildMessagePanel(f)

  f.next = makeButton(f, "", 330, 26)
  f.next:SetPoint("BOTTOMLEFT", 14, 14)
  f.next:SetScript("OnClick", function() act(ns.Next) end)
  f.mode = makeButton(f, "", 210)
  f.mode:SetPoint("LEFT", f.next, "RIGHT", 6, 0)
  f.mode:SetScript("OnClick", function()
    local at = 1
    for i, m in ipairs(MODES) do if m == opts.mode then at = i end end
    opts.mode = MODES[at % #MODES + 1]
    UI.Refresh()
  end)
  f.mode:SetScript("OnEnter", function(self)
    showTooltip(self, "What the Next button does",
      "Whisper: sends your message and waits for an answer. This is the polite default.",
      "Invite: sends a guild invite with no message.",
      "Every press is one whisper or one invite to one player. Nothing is sent on its own.")
  end)
  f.mode:SetScript("OnLeave", function() GameTooltip:Hide() end)
  local hint = makeLabel(f, "GameFontDisableSmall", "/torchcall help")
  hint:SetPoint("BOTTOMRIGHT", -16, 20)

  f:SetScript("OnShow", UI.Refresh)
  return f
end

function UI.RefreshMessage()
  if not main then return end
  local panel, db = main.message, TorchcallDB
  local template = db.templates[opts.template] or ""
  panel.title:SetText(("Opening whisper %d of %d"):format(opts.template, #db.templates))
  local sample = ns.NextTarget() or { name = "Thrall Doomhammer", level = 12, classStr = "Shaman", zone = "The Barrens" }
  local rendered = ns.Render(template, sample)
  panel.preview:SetText(rendered)
  local over = #rendered > 255
  panel.count:SetText(("%s%d of 255 characters with %s's name in it%s|r"):format(over and "|cffff4040" or GREY,
    #rendered, sample.name, over and ". Too long, the game will not send it." or ""))
  local replyLength = #ns.Render(db.reply, sample)
  panel.replyCount:SetText(("%s%d of 255 characters|r"):format(replyLength > 255 and "|cffff4040" or GREY, replyLength))
end

function UI.Refresh()
  if not main or not main:IsShown() then return end
  local db, c = TorchcallDB, ns.Counts()
  main.summary:SetText(("%sWaiting|r %s%d|r    %sAnswered|r %s%d|r    %sWhispered|r %s%d|r    %sInvited|r %s%d|r    %sJoined|r %s%d|r    %shour %d/%d, day %d/%d|r")
    :format(GOLD, WHITE, c.new, GOLD, WHITE, c.replied, GOLD, WHITE, db.stats.whispered, GOLD, WHITE, db.stats.invited,
            GOLD, WHITE, db.stats.joined, GREY, ns.SentThisHour(), opts.hourly, ns.SentToday(), opts.daily))
  main.note:SetText(ns.searchNote or "")

  main.class:SetText(searchClass and ns.ClassName(searchClass) or "Any class")
  main.zone:SetText(zoneOnly and "My zone only" or "Any zone")
  local queued = ns.QueueSize()
  if ns.SearchPending() then
    main.search:SetText("Searching...")
  elseif queued > 0 and select(4, searchInputs()) == planKey then
    main.search:SetText(("Next search (%d left)"):format(queued))
  else
    main.search:SetText("Search")
  end

  for i, b in ipairs(main.tabs) do
    if i == currentTab then b:LockHighlight() else b:UnlockHighlight() end
  end
  local messageTab = currentTab == 3
  if messageTab then main.list:Hide(); main.message:Show() else main.message:Hide(); main.list:Show() end

  local canInvite = ns.CanInvite()
  if messageTab then
    main.count:SetText("")
    if not main.message.edit:HasFocus() then main.message.edit:SetText(db.templates[opts.template] or "") end
    if not main.message.reply:HasFocus() then main.message.reply:SetText(db.reply or "") end
    UI.RefreshMessage()
  else
    local rows = ns.List(currentTab == 1 and "new" or "contacted")
    offset = math.max(0, math.min(offset, math.max(0, #rows - ROWS)))
    for r = 1, ROWS do
      local row, p = main.rows[r], rows[r + offset]
      if p then
        row.name = p.name
        row.followup = p.status ~= "new"
        local answered = ns.Answered(p)
        row.cells[1]:SetText(classColored(p.name, p.class))
        row.cells[2]:SetText(p.level and p.level > 0 and tostring(p.level) or "")
        row.cells[3]:SetText(p.classStr or (p.class and ns.ClassName(p.class)) or "")
        row.cells[4]:SetText(p.zone or "")
        local status = STATUS_LABEL[p.status] or p.status
        if answered then status = ORANGE .. "ANSWERED|r" end
        row.cells[5]:SetText(status .. GREY .. " " .. ago(p.status == "new" and p.seen or p.t) .. "|r")
        row.whisper:SetText(row.followup and "Link" or "Whisper")
        -- the follow-up goes once, and only to someone who wrote back
        if p.status == "new" or (answered and not p.linked) then row.whisper:Show() else row.whisper:Hide() end
        if canInvite and (p.status == "new" or p.status == "whispered") then row.invite:Show() else row.invite:Hide() end
        if p.status == "new" or p.status == "whispered" then row.skip:Show() else row.skip:Hide() end
        row:Show()
      else
        row.name = nil
        row:Hide()
      end
    end
    if #rows == 0 then
      main.empty:SetText(currentTab == 1 and "Nobody waiting. Run a search." or "Nobody contacted yet.")
    else
      main.empty:SetText("")
    end
    if #rows > ROWS then
      main.count:SetText(("%d-%d of %d  (mouse wheel to scroll)"):format(offset + 1, math.min(offset + ROWS, #rows), #rows))
    else
      main.count:SetText("")
    end
  end

  main.mode:SetText(MODE_LABEL[opts.mode] or opts.mode)
  local target = ns.NextTarget()
  if target then
    local verb = opts.mode == "invite" and "Invite" or "Whisper"
    main.next:SetText(("%s next: %s"):format(verb, target.name))
  else
    main.next:SetText("Next (nobody waiting)")
  end
end

function UI.Toggle()
  if not main then
    local ok, result = pcall(buildMain)
    if not ok then
      ns.Log("error", "window: " .. tostring(result))
      ns.Print("Could not build the window. The slash commands still work. (" .. tostring(result) .. ")")
      return
    end
    main = result
  end
  if main:IsShown() then main:Hide() else main:Show() end
end

ns.OnChanged = function() UI.Refresh() end

-- ---------------------------------------------------------------------------
-- Minimap button and addon compartment entry
-- ---------------------------------------------------------------------------

local function placeMinimapButton()
  local angle = math.rad(opts.minimapAngle or 250)
  local radius = (Minimap:GetWidth() / 2) + 6
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function tooltipSummary(tt)
  local c, s = ns.Counts(), TorchcallDB.stats
  tt:AddLine("Torchcall")
  tt:AddLine(("%d waiting, %d answered"):format(c.new, c.replied), 1, 1, 1)
  tt:AddLine(("%d whispered, %d invited, %d joined"):format(s.whispered, s.invited, s.joined), 1, 1, 1)
  tt:AddLine("Click to open. Drag to move.", 0.6, 0.6, 0.6)
end

local function buildMinimapButton()
  if not Minimap then return end
  local b = CreateFrame("Button", "TorchcallMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("AnyUp")
  b:RegisterForDrag("LeftButton")
  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", 7, -5)
  icon:SetTexture(ICON)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  b:SetScript("OnClick", UI.Toggle)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    tooltipSummary(GameTooltip)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      opts.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      placeMinimapButton()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  minimapButton = b
  placeMinimapButton()
  if not opts.minimap then b:Hide() end
end

function Torchcall_OnCompartmentClick() UI.Toggle() end

function Torchcall_OnCompartmentEnter(_, button)
  if not (GameTooltip and button and TorchcallDB) then return end
  GameTooltip:SetOwner(button, "ANCHOR_LEFT")
  tooltipSummary(GameTooltip)
  GameTooltip:Show()
end

function Torchcall_OnCompartmentLeave()
  if GameTooltip then GameTooltip:Hide() end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local function printHelp()
  ns.Print("commands (also /tcall):")
  print("  /torchcall                 open or close the window")
  print("  /torchcall search 10-20    search a level range for players with no guild")
  print("  /torchcall search          send the next queued search")
  print("  /torchcall next            whisper or invite the next player on the list")
  print("  /torchcall stats           your totals")
  print("  /torchcall skip <name>     never contact this player    /torchcall forget <name>   drop them from the list")
  print("  /torchcall cap <number>    new people you may contact per hour (now " .. opts.hourly .. ", and " .. opts.daily .. " a day)")
  print("  /torchcall clear           empty the waiting list    /torchcall minimap   show or hide the button")
  print("  /torchcall log             last debug lines")
end

local function slash(input)
  input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = input:match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  local db = TorchcallDB

  if cmd == "" then
    UI.Toggle()
  elseif cmd == "search" then
    local lo, hi = rest:match("^(%d+)%s*%-%s*(%d+)$")
    if not lo then lo = rest:match("^(%d+)$"); hi = lo end
    if lo then
      ns.StartSearch(lo, hi)
    elseif ns.QueueSize() > 0 then
      ns.NextSearch()
    else
      ns.StartSearch(opts.lo, opts.hi)
    end
    ns.Print(ns.searchNote)
    UI.Refresh()
  elseif cmd == "next" then
    act(ns.Next)
  elseif cmd == "stats" then
    local c, s = ns.Counts(), db.stats
    ns.Print(("%d waiting, %d answered. All time: %d found, %d whispered, %d invited, %d joined, %d declined.")
      :format(c.new, c.replied, s.found, s.whispered, s.invited, s.joined, s.declined))
  elseif cmd == "skip" or cmd == "forget" then
    local p = ns.FindProspect(rest)
    if not p then
      ns.Print("Nobody called '" .. rest .. "' is on the list. Names are case sensitive.")
    elseif cmd == "skip" then
      ns.Skip(p.name)
      ns.Print(p.name .. " will not be contacted.")
    else
      ns.Forget(p.name)
      ns.Print(p.name .. " is off the list.")
    end
  elseif cmd == "cap" then
    local n = tonumber(rest)
    if n and n >= 1 and n <= 60 then
      opts.hourly = math.floor(n)
      ns.Print("You can now contact " .. opts.hourly .. " new people an hour.")
      UI.Refresh()
    else
      ns.Print("Give a number from 1 to 60. It is " .. opts.hourly .. " now.")
    end
  elseif cmd == "clear" then
    for name, p in pairs(db.prospects) do
      if p.status == "new" then db.prospects[name] = nil end
    end
    ns.Print("Waiting list emptied. People you already contacted are kept so nobody is asked twice.")
    UI.Refresh()
  elseif cmd == "minimap" then
    opts.minimap = not opts.minimap
    if minimapButton then
      if opts.minimap then minimapButton:Show() else minimapButton:Hide() end
    end
    ns.Print("Minimap button " .. (opts.minimap and "on." or "off."))
  elseif cmd == "log" then
    ns.Print("last debug lines:")
    for i = math.max(1, #db.log - 19), #db.log do print("  " .. db.log[i]) end
  else
    printHelp()
  end
end

function UI.Init()
  opts = TorchcallDB.opts
  SLASH_TORCHCALL1, SLASH_TORCHCALL2 = "/torchcall", "/tcall"
  SlashCmdList["TORCHCALL"] = function(input)
    local ok, err = pcall(slash, input)
    if not ok then ns.Log("error", "slash: " .. tostring(err)); ns.Print("That command failed: " .. tostring(err)) end
  end
  local ok, err = pcall(buildMinimapButton)
  if not ok then ns.Log("error", "minimap: " .. tostring(err)) end
end
