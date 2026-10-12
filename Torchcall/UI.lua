-- Torchcall window, minimap button and slash commands.

local _, ns = ...
local plain, try = ns.plain, ns.try

local UI = {}
ns.UI = UI

local ICON = "Interface\\Icons\\INV_Torch_Lit"
local GOLD, WHITE, GREY, ORANGE, GREEN = "|cffffd100", "|cffffffff", "|cff9d9d9d", "|cffff7d0a", "|cff40d040"
local ROWS, ROW_HEIGHT = 12, 21
local COLS = { { "Player", 150, "LEFT", "name" }, { "Lvl", 28, "RIGHT", "level" }, { "Class", 70, "LEFT", "class" },
               { "Zone", 130, "LEFT", "zone" }, { "Status", 86, "LEFT", "seen" } }
local MODES = { "whisper", "invite" }
local MODE_LABEL = { whisper = "Next does: whisper", invite = "Next does: invite" }
local STATUS_LABEL = { new = "new", whispered = "whispered", invited = "invited", joined = GREEN .. "joined|r",
                       declined = "declined", taken = "guildmate has it", guilded = "in a guild", skipped = "skipped" }

local opts
local main, minimapButton
local currentTab, offset = 1, 0
local zoneOnly = false
local talkingTo            -- the player the conversation panel is open on
local lineAt = 1           -- which line the Answers tab is editing

-- Everything the Answers tab can edit: the answers, then the two lines sent at other moments.
local function editableLines()
  local list = {}
  for _, a in ipairs(ns.ANSWERS) do
    if a.text then list[#list + 1] = { label = "Answer: " .. a.label, get = function() return TorchcallDB.answers[a.key] end,
                                       set = function(v) TorchcallDB.answers[a.key] = v end, original = a.text } end
  end
  list[#list + 1] = { label = "Opener for someone you just played with", get = function() return TorchcallDB.groupmsg end,
                      set = function(v) TorchcallDB.groupmsg = v end, original = ns.GROUP_TEMPLATE }
  list[#list + 1] = { label = "Opener for a class the guild needs (/torchcall need)", get = function() return TorchcallDB.needmsg end,
                      set = function(v) TorchcallDB.needmsg = v end, original = ns.NEED_TEMPLATE }
  list[#list + 1] = { label = "Check-in, a few days after they join", get = function() return TorchcallDB.checkin end,
                      set = function(v) TorchcallDB.checkin = v end, original = ns.CHECKIN }
  return list
end

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
  local lo, hi = opts.lo, opts.hi
  local zone = zoneOnly and currentZone() or nil
  return lo, hi, zone, table.concat({ tostring(lo), tostring(hi), table.concat(ns.PickedClasses(), ","), zone or "" }, "|")
end

local function startSearch()
  if ns.SearchPending() then return end
  local lo, hi, zone, key = searchInputs()
  if ns.QueueSize() > 0 and key == planKey then
    ns.NextSearch()
  else -- nothing queued, or the filters changed: start over
    planKey = key
    ns.StartSearch(lo, hi, zone)
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
    if not row.name then return end
    if row.action == "welcome" then act(ns.Welcome, row.name)
    elseif row.action == "checkin" then act(ns.CheckIn, row.name)
    elseif row.action == "talk" then talkingTo = row.name UI.Refresh()
    else act(ns.Whisper, row.name) end
  end)
  row:SetScript("OnEnter", function(self)
    local p = self.name and TorchcallDB.prospects[self.name]
    if not p then return end
    showTooltip(self, p.name,
      p.race and (p.race .. " " .. (p.classStr or "")) or p.classStr,
      p.zone and ("Seen in " .. p.zone .. ", " .. ago(p.seen) .. " ago") or nil,
      p.ran and "You played with them. They get the line written for that." or nil,
      p.by and ("Contacted by " .. p.by) or nil,
      p.said and ('They said: "' .. p.said .. '"') or nil,
      p.stayed == true and "Still in the guild a week on." or (p.stayed == false and "Left the guild within a week.") or nil)
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

local function buildMessagePanel(f)
  local panel = CreateFrame("Frame", nil, f)
  panel:SetPoint("TOPLEFT", 16, -162)
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
  panel.results = makeLabel(panel, "GameFontHighlightSmall")
  panel.results:SetPoint("TOPRIGHT", 0, -50)
  local previewLabel = makeLabel(panel, "GameFontNormalSmall", "What the next player on the list would read")
  previewLabel:SetPoint("TOPLEFT", 0, -70)
  panel.preview = makeLabel(panel, "GameFontHighlight")
  panel.preview:SetPoint("TOPLEFT", 0, -86)
  panel.preview:SetPoint("TOPRIGHT", 0, -86)
  panel.preview:SetHeight(44)
  panel.preview:SetJustifyH("LEFT")
  panel.preview:SetJustifyV("TOP")
  panel.preview:SetWordWrap(true)

  local replyLabel = makeLabel(panel, "GameFontNormal", "Follow-up, sent by the Link button to someone who answered")
  replyLabel:SetPoint("TOPLEFT", 0, -140)
  panel.reply = makeEdit(panel, 640, 255)
  panel.reply:SetPoint("TOPLEFT", 6, -162)
  panel.reply:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    TorchcallDB.reply = self:GetText() or ""
    UI.RefreshMessage()
  end)
  panel.replyCount = makeLabel(panel, "GameFontDisableSmall")
  panel.replyCount:SetPoint("TOPLEFT", 0, -186)

  local welcomeLabel = makeLabel(panel, "GameFontNormal", "Guild chat welcome, said by the Welcome button when someone you recruited joins")
  welcomeLabel:SetPoint("TOPLEFT", 0, -208)
  panel.welcome = makeEdit(panel, 640, 255)
  panel.welcome:SetPoint("TOPLEFT", 6, -230)
  panel.welcome:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    TorchcallDB.welcome = self:GetText() or ""
    UI.RefreshMessage()
  end)
  panel.welcomeCount = makeLabel(panel, "GameFontDisableSmall")
  panel.welcomeCount:SetPoint("TOPLEFT", 0, -254)

  local tokens = makeLabel(panel, "GameFontDisableSmall",
    "You can use {name} {fullname} {level} {class} {zone} {guild}. The game cuts a message at 255 characters.")
  tokens:SetPoint("BOTTOMLEFT", 0, 30)
  local restore = makeButton(panel, "Restore the original messages", 220)
  restore:SetPoint("BOTTOMLEFT", 0, 0)
  restore:SetScript("OnClick", function()
    TorchcallDB.templates = {}
    for i, t in ipairs(ns.TEMPLATES) do TorchcallDB.templates[i] = t end
    TorchcallDB.reply = ns.REPLY
    TorchcallDB.welcome = ns.WELCOME
    opts.template = 1
    UI.Refresh()
  end)
  panel.rotate = makeButton(panel, "", 220)
  panel.rotate:SetPoint("LEFT", restore, "RIGHT", 8, 0)
  panel.rotate:SetScript("OnClick", function() opts.rotate = not opts.rotate; UI.Refresh() end)
  panel.rotate:SetScript("OnEnter", function(self)
    showTooltip(self, "Try every opener",
      "On: each opening whisper gets about twenty sends, then the one that gets the most answers is used most. One send in five still goes to the least tried.",
      "Off: every whisper uses the opener showing above.",
      "Someone you added from your own group always gets the line written for that, on the Answers tab.")
  end)
  panel.rotate:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return panel
end

-- The Answers tab: every line sent after the opener, one at a time, and what is working.
local function buildAnswersPanel(f)
  local panel = CreateFrame("Frame", nil, f)
  panel:SetPoint("TOPLEFT", 16, -162)
  panel:SetPoint("BOTTOMRIGHT", -16, 48)
  panel.title = makeLabel(panel, "GameFontNormal")
  panel.title:SetPoint("TOPLEFT", 0, 0)
  local prev = makeButton(panel, "<", 26)
  prev:SetPoint("TOPRIGHT", -30, 4)
  local nextB = makeButton(panel, ">", 26)
  nextB:SetPoint("LEFT", prev, "RIGHT", 4, 0)
  local function step(by)
    panel.edit:ClearFocus()
    lineAt = (lineAt - 1 + by) % #editableLines() + 1
    UI.Refresh()
  end
  prev:SetScript("OnClick", function() step(-1) end)
  nextB:SetScript("OnClick", function() step(1) end)
  panel.edit = makeEdit(panel, 640, 255)
  panel.edit:SetPoint("TOPLEFT", 6, -24)
  panel.edit:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    local line = editableLines()[lineAt]
    if line then line.set(self:GetText() or "") end
    UI.RefreshAnswers()
  end)
  panel.count = makeLabel(panel, "GameFontDisableSmall")
  panel.count:SetPoint("TOPLEFT", 0, -50)
  panel.preview = makeLabel(panel, "GameFontHighlight")
  panel.preview:SetPoint("TOPLEFT", 0, -68)
  panel.preview:SetPoint("TOPRIGHT", 0, -68)
  panel.preview:SetHeight(44)
  panel.preview:SetJustifyH("LEFT")
  panel.preview:SetJustifyV("TOP")
  panel.preview:SetWordWrap(true)
  local reset = makeButton(panel, "Put this line back", 150)
  reset:SetPoint("TOPLEFT", 0, -116)
  reset:SetScript("OnClick", function()
    local line = editableLines()[lineAt]
    if line then line.set(line.original) end
    panel.edit:ClearFocus()
    UI.Refresh()
  end)
  local how = makeLabel(panel, "GameFontDisableSmall",
    "Answers go only to someone who wrote back to you: press Reply on their row. One press sends one, and each goes to a player once.")
  how:SetPoint("LEFT", reset, "RIGHT", 10, 0)
  how:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  how:SetJustifyH("LEFT")
  how:SetWordWrap(true)

  local workingLabel = makeLabel(panel, "GameFontNormal", "What is working")
  workingLabel:SetPoint("TOPLEFT", 0, -152)
  panel.funnel = makeLabel(panel, "GameFontHighlightSmall")
  panel.funnel:SetPoint("TOPLEFT", 0, -172)
  panel.funnel:SetPoint("TOPRIGHT", 0, -172)
  panel.funnel:SetHeight(110)
  panel.funnel:SetJustifyH("LEFT")
  panel.funnel:SetJustifyV("TOP")
  panel.funnel:SetWordWrap(true)
  return panel
end

-- The conversation panel, beside the window: what they wrote, and one button per answer.
local function buildTalkPanel(f)
  local panel = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  panel:SetSize(230, 430)
  panel:SetPoint("TOPLEFT", f, "TOPRIGHT", 2, -24)
  if panel.SetBackdrop then
    panel:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
                        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  end
  panel:EnableMouse(true)
  panel.title = makeLabel(panel, "GameFontNormal")
  panel.title:SetPoint("TOPLEFT", 12, -12)
  panel.said = makeLabel(panel, "GameFontHighlightSmall")
  panel.said:SetPoint("TOPLEFT", 12, -32)
  panel.said:SetWidth(206)
  panel.said:SetHeight(46)
  panel.said:SetJustifyH("LEFT")
  panel.said:SetJustifyV("TOP")
  panel.said:SetWordWrap(true)
  panel.hint = makeLabel(panel, "GameFontNormalSmall")
  panel.hint:SetPoint("TOPLEFT", 12, -82)
  panel.hint:SetWidth(206)
  panel.hint:SetJustifyH("LEFT")
  panel.topics = {}
  for i, a in ipairs(ns.ANSWERS) do
    local b = makeButton(panel, a.label, 206, 22)
    b:SetPoint("TOPLEFT", 12, -100 - (i - 1) * 25)
    b.key = a.key
    b:SetScript("OnClick", function() if talkingTo then act(ns.Answer, talkingTo, a.key) end end)
    b:SetScript("OnEnter", function(self)
      local p = talkingTo and TorchcallDB.prospects[talkingTo]
      local text = a.key == "discord" and TorchcallDB.reply or TorchcallDB.answers[a.key]
      if p and text then showTooltip(self, a.label, ns.Render(text, p), "One whisper. This answer goes to a player once.") end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.topics[i] = b
  end
  local y = -100 - #ns.ANSWERS * 25 - 8
  panel.invite = makeButton(panel, "Send the guild invite", 206, 24)
  panel.invite:SetPoint("TOPLEFT", 12, y)
  panel.invite:SetScript("OnClick", function() if talkingTo then act(ns.Invite, talkingTo) end end)
  panel.skip = makeButton(panel, "They said no", 100, 22)
  panel.skip:SetPoint("TOPLEFT", 12, y - 28)
  panel.skip:SetScript("OnClick", function()
    if talkingTo then act(ns.Skip, talkingTo) end
    talkingTo = nil
    UI.Refresh()
  end)
  panel.close = makeButton(panel, "Close", 100, 22)
  panel.close:SetPoint("LEFT", panel.skip, "RIGHT", 6, 0)
  panel.close:SetScript("OnClick", function() talkingTo = nil; UI.Refresh() end)
  panel:Hide()
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
  f:SetSize(700, 500)
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

  local function levelsChanged(self, userInput)
    if not userInput then return end
    local lo, hi = tonumber(f.lo:GetText()), tonumber(f.hi:GetText())
    if lo and hi and lo >= 1 and hi >= lo then
      ns.SetLevels(lo, hi)
      UI.Refresh()
    end
  end
  f.lo:SetScript("OnTextChanged", levelsChanged)
  f.hi:SetScript("OnTextChanged", levelsChanged)

  f.zone = makeButton(f, "", 120)
  f.zone:SetPoint("LEFT", f.hi, "RIGHT", 12, 0)
  f.zone:SetScript("OnClick", function() zoneOnly = not zoneOnly; UI.Refresh() end)
  f.latin = makeButton(f, "", 120)
  f.latin:SetPoint("LEFT", f.zone, "RIGHT", 6, 0)
  f.latin:SetScript("OnClick", function() opts.latin = not opts.latin; UI.Refresh() end)
  f.latin:SetScript("OnEnter", function(self)
    showTooltip(self, "Names",
      "Latin names: hides players whose name is written in another alphabet, such as Cyrillic or Korean.",
      "It is a rough hint for a guild that plays in one language. It cannot tell English from Portuguese.")
  end)
  f.latin:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.search = makeButton(f, "Search", 170)
  f.search:SetPoint("LEFT", f.latin, "RIGHT", 6, 0)
  f.search:SetScript("OnClick", startSearch)
  f.search:SetScript("OnEnter", function(self)
    showTooltip(self, "Search",
      "Asks the game who is online in that level range, for the classes you picked, and keeps the players with no guild.",
      "One search returns at most 50 players. A busy range is split by level, then class, then race, and each search needs its own press.",
      "You can bind a key to this under Options, Keybindings, AddOns.")
  end)
  f.search:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- class row: nothing picked means every class
  local classLabel = makeLabel(f, "GameFontNormalSmall", "Class")
  classLabel:SetPoint("TOPLEFT", 16, -91)
  f.classes = {}
  for i, token in ipairs(ns.CLASSES) do
    local b = makeButton(f, ns.ClassName(token), 64, 20)
    b:SetPoint("TOPLEFT", 52 + (i - 1) * 66, -86)
    b:SetScript("OnClick", function() ns.ToggleClass(token) end)
    b.token = token
    f.classes[i] = b
  end
  f.allClasses = makeButton(f, "All", 34, 20)
  f.allClasses:SetPoint("TOPLEFT", 52 + #ns.CLASSES * 66, -86)
  f.allClasses:SetScript("OnClick", function() ns.ToggleClass(nil) end)

  f.note = makeLabel(f, "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", 16, -114)
  f.note:SetPoint("TOPRIGHT", -16, -114)
  f.note:SetJustifyH("LEFT")
  f.note:SetWordWrap(false)

  f.tabs = {}
  for i, label in ipairs({ "Prospects", "Contacted", "Message", "Answers" }) do
    local b = makeButton(f, label, 120)
    b:SetPoint("TOPLEFT", 14 + (i - 1) * 124, -132)
    b:SetScript("OnClick", function()
      currentTab, offset = i, 0
      UI.Refresh()
    end)
    f.tabs[i] = b
  end
  f.group = makeButton(f, "Add my group", 150)
  f.group:SetPoint("TOPRIGHT", -16, -132)
  f.group:SetScript("OnClick", function() act(ns.AddGroup) end)
  f.group:SetScript("OnEnter", function(self)
    showTooltip(self, "Add my group",
      "Puts everyone in your party or raid who has no guild on the list, at the top.",
      "Someone you have just played with is far more likely to say yes than a stranger, and they get their own opening line.",
      "Adding them contacts nobody. You still press Whisper or Invite for each one.")
  end)
  f.group:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local list = CreateFrame("Frame", nil, f)
  list:SetPoint("TOPLEFT", 16, -162)
  list:SetPoint("TOPRIGHT", -16, -162)
  list:SetHeight((ROWS + 1) * ROW_HEIGHT + 4)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - delta * 3
    UI.Refresh()
  end)
  f.list = list
  local x = 0
  f.heads = {}
  for i, col in ipairs(COLS) do
    -- a column title is a button: press it to sort by that column, press again to reverse
    local head = CreateFrame("Button", nil, list)
    head:SetPoint("TOPLEFT", x, 0)
    head:SetSize(col[2], ROW_HEIGHT - 2)
    head.label = makeLabel(head, "GameFontNormalSmall", col[1])
    head.label:SetAllPoints()
    head.label:SetJustifyH(col[3])
    head:SetScript("OnClick", function() offset = 0; ns.SetSort(col[4]) end)
    f.heads[i] = head
    x = x + col[2] + 8
  end
  f.rows = {}
  for r = 1, ROWS do f.rows[r] = buildRow(list, r) end
  f.empty = makeLabel(list, "GameFontDisable")
  f.empty:SetPoint("CENTER", 0, 0)
  f.count = makeLabel(f, "GameFontDisableSmall")
  f.count:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, -2)

  f.message = buildMessagePanel(f)
  f.answers = buildAnswersPanel(f)
  f.talk = buildTalkPanel(f)

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
      "Every press is one whisper or one invite to one player. Nothing is sent on its own.",
      "You can bind a key to Next under Options, Keybindings, AddOns.")
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
  local t = ns.TemplateStat(ns.TemplateKey(template))
  if t.sent > 0 then
    panel.results:SetText(("%sThis message:|r sent %d, answered %d (%d%%), joined %d"):format(GOLD, t.sent, t.replied,
      math.floor(t.replied * 100 / t.sent + 0.5), t.joined))
  else
    panel.results:SetText(GREY .. "This message has not been sent yet|r")
  end
  local replyLength = #ns.Render(db.reply, sample)
  panel.replyCount:SetText(("%s%d of 255 characters|r"):format(replyLength > 255 and "|cffff4040" or GREY, replyLength))
  local welcomeLength = #ns.Render(db.welcome, sample)
  panel.welcomeCount:SetText(("%s%d of 255 characters|r"):format(welcomeLength > 255 and "|cffff4040" or GREY, welcomeLength))
end

function UI.RefreshAnswers()
  if not main then return end
  local panel, lines = main.answers, editableLines()
  lineAt = math.max(1, math.min(lineAt, #lines))
  local line = lines[lineAt]
  panel.title:SetText(("%s  %s(%d of %d)|r"):format(line.label, GREY, lineAt, #lines))
  local sample = (talkingTo and TorchcallDB.prospects[talkingTo]) or ns.NextTarget()
    or { name = "Thrall Doomhammer", level = 12, classStr = "Shaman", zone = "The Barrens" }
  local rendered = ns.Render(line.get() or "", sample)
  panel.preview:SetText(rendered)
  local over = #rendered > 255
  panel.count:SetText(("%s%d of 255 characters with %s's name in it%s|r"):format(over and "|cffff4040" or GREY,
    #rendered, sample.name, over and ". Too long, the game will not send it." or ""))

  local f = ns.Funnel()
  local function pct(v) return v and (v .. "%") or "no data" end
  local function kept(path)
    local n = path.stayed + path.left
    return n > 0 and (", %d of %d still here a week later"):format(path.stayed, n) or ""
  end
  local out = {
    ("%sWhispers|r  %d sent, %d answered (%s)"):format(GOLD, f.whispered, f.replied, pct(f.replyRate)),
    ("%sInvites after a conversation|r  %d sent, %d joined (%s)%s"):format(GOLD, f.warm.invited, f.warm.joined, pct(f.warm.rate), kept(f.warm)),
    ("%sInvites with no conversation|r  %d sent, %d joined (%s)%s"):format(GOLD, f.cold.invited, f.cold.joined, pct(f.cold.rate), kept(f.cold)),
    ("%sAnswers sent|r %d    %sCheck-ins sent|r %d"):format(GOLD, TorchcallDB.stats.answers, GOLD, TorchcallDB.stats.checkins),
    "",
    f.advice,
  }
  panel.funnel:SetText(table.concat(out, "\n"))
end

local function refreshTalk()
  local panel = main.talk
  local p = talkingTo and TorchcallDB.prospects[talkingTo]
  local left = p and ns.AnswersLeft(p.name) or {}
  if not p or not p.replied or (p.status ~= "whispered" and p.status ~= "invited" and p.status ~= "joined") then
    talkingTo = nil
    panel:Hide()
    return
  end
  local open = {}
  for _, key in ipairs(left) do open[key] = true end
  panel.title:SetText(classColored(p.name, p.class))
  panel.said:SetText(p.said and ('"' .. p.said .. '"') or (GREY .. "They wrote back.|r"))
  local suggestion = ns.Suggest(p.said)
  if suggestion == "invite" then panel.hint:SetText(GREEN .. "Sounds like a yes.|r")
  elseif suggestion == "skip" then panel.hint:SetText(ORANGE .. "Sounds like a no. Leave it there.|r")
  elseif suggestion and open[suggestion] then panel.hint:SetText(GOLD .. "Suggested: " .. ns.AnswerTopic(suggestion).label .. "|r")
  elseif #left == 0 then panel.hint:SetText(GREY .. "That is enough from the addon. Type to them.|r")
  else panel.hint:SetText(GREY .. "Pick what answers them.|r") end
  for _, b in ipairs(panel.topics) do
    if open[b.key] then b:Enable() else b:Disable() end
    if suggestion == b.key and open[b.key] then b:LockHighlight() else b:UnlockHighlight() end
  end
  if ns.CanInvite() and p.status == "whispered" then
    panel.invite:Enable()
    if suggestion == "invite" then panel.invite:LockHighlight() else panel.invite:UnlockHighlight() end
  else
    panel.invite:Disable()
    panel.invite:UnlockHighlight()
  end
  panel.invite:SetText(p.status == "whispered" and "Send the guild invite" or (p.status == "joined" and "Joined" or "Invited"))
  if p.status == "whispered" then panel.skip:Show() else panel.skip:Hide() end
  panel:Show()
end

function UI.Refresh()
  if not main or not main:IsShown() then return end
  local db, c = TorchcallDB, ns.Counts()
  local hiddenNote = c.hidden > 0 and (GREY .. " (+" .. c.hidden .. " filtered out)|r") or ""
  main.summary:SetText(("%sWaiting|r %s%d|r%s    %sAnswered|r %s%d|r    %sWhispered|r %s%d|r    %sInvited|r %s%d|r    %sJoined|r %s%d|r    %shour %d/%d, day %d%s|r")
    :format(GOLD, WHITE, c.new, hiddenNote, GOLD, WHITE, c.replied, GOLD, WHITE, db.stats.whispered, GOLD, WHITE, db.stats.invited,
            GOLD, WHITE, db.stats.joined, GREY, ns.SentThisHour(), opts.hourly, ns.SentToday(), opts.daily > 0 and ("/" .. opts.daily) or " (no daily limit)"))
  main.note:SetText(ns.searchNote or "")

  main.zone:SetText(zoneOnly and "My zone only" or "Any zone")
  main.latin:SetText(opts.latin and "Latin names" or "Any names")
  local picked = ns.PickedClasses()
  for _, b in ipairs(main.classes) do
    local on = #picked == 0 or opts.classes[b.token]
    b:SetText(on and classColored(ns.ClassName(b.token), b.token) or (GREY .. ns.ClassName(b.token) .. "|r"))
    if #picked > 0 and opts.classes[b.token] then b:LockHighlight() else b:UnlockHighlight() end
  end
  for i, head in ipairs(main.heads) do
    local arrow = COLS[i][4] == opts.sort and (opts.sortUp and " ^" or " v") or ""
    head.label:SetText(COLS[i][1] .. arrow)
  end
  local queued = ns.QueueSize()
  local wait = ns.SearchWait()
  if ns.SearchPending() then
    main.search:SetText("Searching...")
  elseif wait > 0 and queued > 0 then
    -- the game takes one who search every few seconds: count it down on the button
    main.search:SetText(("Next search in %d"):format(wait))
    if not main.counting then
      main.counting = true
      C_Timer.After(1, function() main.counting = false UI.Refresh() end)
    end
  elseif queued > 0 and select(4, searchInputs()) == planKey then
    main.search:SetText(("Next search (%d left)"):format(queued))
  else
    main.search:SetText("Search")
  end

  for i, b in ipairs(main.tabs) do
    if i == currentTab then b:LockHighlight() else b:UnlockHighlight() end
  end
  local due = #ns.DueCheckIns()
  main.tabs[2]:SetText(due > 0 and ("Contacted " .. ORANGE .. "(" .. due .. " due)|r") or "Contacted")
  local messageTab, answersTab = currentTab == 3, currentTab == 4
  if messageTab then main.message:Show() else main.message:Hide() end
  if answersTab then main.answers:Show() else main.answers:Hide() end
  if messageTab or answersTab then main.list:Hide() else main.list:Show() end
  refreshTalk()

  local canInvite = ns.CanInvite()
  if messageTab then
    main.count:SetText("")
    if not main.message.edit:HasFocus() then main.message.edit:SetText(db.templates[opts.template] or "") end
    if not main.message.reply:HasFocus() then main.message.reply:SetText(db.reply or "") end
    if not main.message.welcome:HasFocus() then main.message.welcome:SetText(db.welcome or "") end
    main.message.rotate:SetText(opts.rotate and "Trying every opener: on" or "Trying every opener: off")
    UI.RefreshMessage()
  elseif answersTab then
    main.count:SetText("")
    local line = editableLines()[math.max(1, math.min(lineAt, #editableLines()))]
    if not main.answers.edit:HasFocus() then main.answers.edit:SetText(line.get() or "") end
    UI.RefreshAnswers()
  else
    local rows, hidden = ns.List(currentTab == 1 and "new" or "contacted")
    offset = math.max(0, math.min(offset, math.max(0, #rows - ROWS)))
    for r = 1, ROWS do
      local row, p = main.rows[r], rows[r + offset]
      if p then
        row.name = p.name
        local answered = ns.Answered(p)
        row.cells[1]:SetText(classColored(p.name, p.class))
        row.cells[2]:SetText(p.level and p.level > 0 and tostring(p.level) or "")
        row.cells[3]:SetText(p.classStr or (p.class and ns.ClassName(p.class)) or "")
        row.cells[4]:SetText(p.zone or "")
        local status = STATUS_LABEL[p.status] or p.status
        if answered then status = ORANGE .. "ANSWERED|r" end
        if p.status == "new" and ns.Needed(p) then status = GOLD .. "class we need|r" end
        if p.status == "new" and p.ran then status = GREEN .. "played with|r" end
        if p.stayed == false then status = GREY .. "joined, then left|r" end
        row.cells[5]:SetText(status .. GREY .. " " .. ago(p.status == "new" and p.seen or p.t) .. "|r")
        -- one button per row, for the one thing worth doing next with this player
        local talking = p.replied and (p.status == "whispered" or p.status == "invited" or p.status == "joined")
        if p.status == "new" then row.action = "whisper"
        elseif p.status == "joined" and not p.welcomed and canInvite then row.action = "welcome"
        elseif ns.CheckInDue(p) then row.action = "checkin"
        elseif talking and #ns.AnswersLeft(p.name) > 0 then row.action = "talk"
        else row.action = nil end
        if row.action then
          row.whisper:SetText(({ whisper = "Whisper", welcome = "Welcome", checkin = "Check in", talk = "Reply" })[row.action])
          row.whisper:Show()
        else
          row.whisper:Hide()
        end
        if canInvite and (p.status == "new" or p.status == "whispered") then row.invite:Show() else row.invite:Hide() end
        if p.status == "new" or p.status == "whispered" then row.skip:Show() else row.skip:Hide() end
        row:Show()
      else
        row.name = nil
        row:Hide()
      end
    end
    if #rows == 0 then
      if currentTab ~= 1 then
        main.empty:SetText("Nobody contacted yet.")
      elseif hidden > 0 then
        main.empty:SetText(("Nobody matches your level and class filters. %d waiting are hidden by them."):format(hidden))
      else
        main.empty:SetText("Nobody waiting. Run a search.")
      end
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
  local due = #ns.DueCheckIns()
  if due > 0 then tt:AddLine(("%d recruit%s due a check-in"):format(due, due == 1 and "" or "s"), 1, 0.5, 0.04) end
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
  print("  /torchcall class mage priest     only these classes (class all to clear)    /torchcall level 20-40")
  print("  /torchcall next            whisper or invite the next player on the list")
  print("  /torchcall group           add everyone in your party or raid who has no guild")
  print("  /torchcall answer <topic> <name>   one answer to someone who wrote back (topics: /torchcall answer)")
  print("  /torchcall checkin <name>  a how-is-it-going whisper to a recruit who joined a few days ago (no name: who is due)")
  print("  /torchcall rotate          try every opener and lean on the best, on or off")
  print("  /torchcall stats           your totals and what is working")
  print("  /torchcall guild           the guild window's Info text and message of the day, and what Torchcall would put there")
  print("  /torchcall skip <name>     never contact this player    /torchcall forget <name>   drop them from the list")
  print("  /torchcall cap <number>    new people you may contact per hour (now " .. opts.hourly .. ")")
  print("  /torchcall cap day <number|off>   and per day (now " .. (opts.daily > 0 and opts.daily or "no limit") .. ")")
  print("  /torchcall autowelcome     welcome your recruit in guild chat by itself when they join, on or off (now " .. (opts.autowelcome and "on" or "off") .. ")")
  print("  /torchcall pitch           whisper the opener before an invite to someone new, on or off (now " .. (opts.pitch and "on" or "off") .. ")")
  print("  /torchcall need <classes>  classes the guild is short of (healers, tanks, priest mage, off): they come first")
  print("  /torchcall warm            who answered and is still waiting    /torchcall board   recruiters this week")
  print("  /torchcall recruits        your recruits and their first week   /torchcall step <name> discord")
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
      if main then main.lo:SetText(tostring(opts.lo)); main.hi:SetText(tostring(opts.hi)) end
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
    local f = ns.Funnel()
    local function line(label, path)
      local n = path.stayed + path.left
      print(("  %s: %d sent, %d joined%s%s"):format(label, path.invited, path.joined, path.rate and (" (" .. path.rate .. "%)") or "",
        n > 0 and (", %d of %d still here a week later"):format(path.stayed, n) or ""))
    end
    print(("  Whispers: %d sent, %d answered%s"):format(f.whispered, f.replied, f.replyRate and (" (" .. f.replyRate .. "%)") or ""))
    line("Invites after a conversation", f.warm)
    line("Invites with no conversation", f.cold)
    print("  " .. f.advice)
    local insights = ns.Insights()
    if #insights > 0 then
      print("  Where it works best so far:")
      for _, text in ipairs(insights) do print("    " .. text) end
    end
  elseif cmd == "need" then
    if rest ~= "" then
      local unknown = ns.SetNeed(rest)
      if #unknown > 0 then ns.Print("Not a class I know: " .. table.concat(unknown, ", ") .. ". Try class names, healers or tanks.") end
    end
    local list = ns.NeedList()
    if #list == 0 then
      ns.Print("No class is marked as needed. /torchcall need healers, /torchcall need priest mage, /torchcall need off.")
    else
      local names = {}
      for i, token in ipairs(list) do names[i] = ns.ClassName(token) end
      ns.Print("The guild needs: " .. table.concat(names, ", ") .. ". They come first on the list and get the opener written for it. That opener is on the Answers tab, after the answers.")
    end
    UI.Refresh()
  elseif cmd == "board" then
    ns.Print("Recruiters, this week first:")
    for i, row in ipairs(ns.Board()) do
      print(("  %d. %s%s|r  %d this week, %d all time, %d still here after a week"):format(i, row.me and GOLD or WHITE, row.name, row.week, row.joined, row.stayed))
    end
    print("  Other recruiters show up here once they are online with Torchcall 1.4 or newer.")
  elseif cmd == "recruits" then
    local list = ns.Recruits()
    if #list == 0 then
      ns.Print("Nobody you recruited has joined in the last three weeks.")
    else
      ns.Print("Your recruits, newest first:")
      for _, p in ipairs(list) do
        local parts = {}
        for _, step in ipairs(ns.STEPS) do
          parts[#parts + 1] = ((p.steps and p.steps[step[1]]) and GREEN .. "yes|r " or GREY .. "not yet|r ") .. step[2]
        end
        print(("  %s, joined %s: %s"):format(p.name, ago(p.t), table.concat(parts, ", ")))
      end
      print("  Tick one yourself: /torchcall step <name> discord   (hello and run are noticed by the addon)")
    end
  elseif cmd == "step" then
    local name, key = rest:match("^(.-)%s+(%a+)$")
    local ok, result = false, "Like this: /torchcall step <name> discord"
    if name and name ~= "" then ok, result = ns.Step(name, key:lower()) end
    if ok then
      ns.Print(("%s: %s is now %s."):format(result.name, key:lower(), result.steps[key:lower()] and "ticked" or "unticked"))
    else
      ns.Print(result)
    end
  elseif cmd == "warm" then
    local list = ns.FollowUps()
    if #list == 0 then
      ns.Print("Nobody is waiting on an answer from you.")
    else
      ns.Print("Answered you and still waiting, longest first:")
      for _, p in ipairs(list) do print(("  %s (%s): %s"):format(p.name, ago(p.replied), p.said or "")) end
    end
  elseif cmd == "group" then
    act(ns.AddGroup)
  elseif cmd == "guild" then
    local which = rest:lower()
    if which == "info" or which == "motd" then
      local state = ns.GuildText(which)
      if act(ns.SetGuildText, which) then
        ns.Print(state.label .. " written." .. (state.now and not state.empty and " What was there before is kept in the saved file." or ""))
      end
    else
      for _, key in ipairs({ "info", "motd" }) do
        local state = ns.GuildText(key)
        ns.Print(state.label .. (state.same and ": already set." or (state.can and (": /torchcall guild " .. key .. " writes this:") or ": your rank cannot edit it. It would say:")))
        if not state.same then
          for line in state.want:gmatch("[^\n]+") do print("    " .. line) end
          print("  Now: " .. ((state.now == nil and "could not be read") or (state.empty and "empty") or state.now:gsub("\n", " / ")))
        end
      end
    end
  elseif cmd == "autowelcome" then
    if rest:lower() == "on" then opts.autowelcome = true elseif rest:lower() == "off" then opts.autowelcome = false else opts.autowelcome = not opts.autowelcome end
    ns.Print(opts.autowelcome and "When someone you recruited joins, the welcome line goes to guild chat by itself."
      or "The welcome line is now only sent when you press Welcome.")
  elseif cmd == "pitch" then
    if rest:lower() == "on" then opts.pitch = true elseif rest:lower() == "off" then opts.pitch = false else opts.pitch = not opts.pitch end
    ns.Print(opts.pitch and "An invite to someone you have not spoken to now sends the opener first, then the invite."
      or "An invite is now only the invite, with no whisper before it.")
    UI.Refresh()
  elseif cmd == "rotate" then
    opts.rotate = not opts.rotate
    ns.Print(opts.rotate and "Trying every opener, then leaning on the one that gets answers." or "Every whisper now uses the opener showing on the Message tab.")
    UI.Refresh()
  elseif cmd == "answer" then
    local key, who = rest:match("^(%S+)%s+(.+)$")
    local p = who and ns.FindProspect(who)
    if not key or not ns.AnswerTopic(key:lower()) then
      local keys = {}
      for _, a in ipairs(ns.ANSWERS) do keys[#keys + 1] = a.key end
      ns.Print("Topics: " .. table.concat(keys, ", ") .. ". Example: /torchcall answer raids Bob Smith")
    elseif not p then
      ns.Print("Nobody called '" .. who .. "' is on the list. Names are case sensitive.")
    else
      act(ns.Answer, p.name, key:lower())
    end
  elseif cmd == "checkin" then
    local p = rest ~= "" and ns.FindProspect(rest)
    if p then
      act(ns.CheckIn, p.name)
    else
      local due, names = ns.DueCheckIns(), {}
      for _, d in ipairs(due) do names[#names + 1] = d.name end
      ns.Print(#due > 0 and ("Due a check-in: " .. table.concat(names, ", ") .. ".") or "Nobody is due a check-in.")
    end
  elseif cmd == "class" or cmd == "classes" then
    if rest == "" or rest:lower() == "all" or rest:lower() == "any" then
      ns.ToggleClass(nil)
    else
      for k in pairs(opts.classes) do opts.classes[k] = nil end
      for word in rest:gmatch("%a+") do
        for _, token in ipairs(ns.CLASSES) do
          if token:lower():find(word:lower(), 1, true) == 1 or ns.ClassName(token):lower():find(word:lower(), 1, true) == 1 then
            opts.classes[token] = true
          end
        end
      end
    end
    local names = {}
    for _, token in ipairs(ns.PickedClasses()) do names[#names + 1] = ns.ClassName(token) end
    ns.Print("Classes: " .. (#names > 0 and table.concat(names, ", ") or "all of them") .. ".")
    UI.Refresh()
  elseif cmd == "level" or cmd == "levels" then
    local lo, hi = rest:match("^(%d+)%s*%-%s*(%d+)$")
    if not lo then lo = rest:match("^(%d+)$"); hi = lo end
    if lo then
      ns.SetLevels(lo, hi)
      if main then main.lo:SetText(tostring(opts.lo)); main.hi:SetText(tostring(opts.hi)) end
      UI.Refresh()
    end
    ns.Print(("Levels %d to %d."):format(opts.lo, opts.hi))
  elseif cmd == "welcome" then
    local p = ns.FindProspect(rest)
    if p then act(ns.Welcome, p.name) else ns.Print("Nobody called '" .. rest .. "' is on the list.") end
  elseif cmd == "skip" or cmd == "forget" then
    local p = ns.FindProspect(rest)
    if not p then
      ns.Print("Nobody called '" .. rest .. "' is on the list. Names are case sensitive.")
    elseif cmd == "skip" then
      ns.Skip(p.name)
      ns.Print(p.name .. " will not be contacted.")
    else
      local ok, why = ns.Forget(p.name)
      ns.Print(ok and (p.name .. " is off the list.") or why)
    end
  elseif cmd == "cap" and rest:lower():find("^day") then
    -- the daily limit is yours to set: a number, or off for none
    local value = rest:lower():match("^day%s*(%S*)")
    local n = tonumber(value)
    if value == "off" or value == "none" then
      opts.daily = 0
      ns.Print("No daily limit. The hourly limit of " .. opts.hourly .. " still holds.")
      UI.Refresh()
    elseif n and n >= 1 and n <= 5000 then
      opts.daily = math.floor(n)
      ns.Print("You can now contact " .. opts.daily .. " new people a day.")
      UI.Refresh()
    else
      ns.Print("Give a number from 1 to 5000, or off. It is " .. (opts.daily > 0 and opts.daily or "off") .. " now.")
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

-- Key bindings (Options, Keybindings, AddOns). A key press is one action, same as a click.
BINDING_HEADER_TORCHCALL = "Torchcall"
BINDING_NAME_TORCHCALL_NEXT = "Whisper or invite the next player"
BINDING_NAME_TORCHCALL_SEARCH = "Send the next who search"
BINDING_NAME_TORCHCALL_TOGGLE = "Open or close the window"

function Torchcall_KeyNext()
  if not (TorchcallDB and opts) then return end
  local target = ns.NextTarget()
  if act(ns.Next) and target and not (main and main:IsShown()) then
    ns.Print((opts.mode == "invite" and "Invited " or "Whispered ") .. target.name .. ".")
  end
end

function Torchcall_KeySearch()
  if not (TorchcallDB and opts) then return end
  startSearch()
  if not (main and main:IsShown()) then ns.Print(ns.searchNote) end
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
  -- a reminder is only a line of text: nothing is sent to anyone
  if C_Timer and C_Timer.After then
    C_Timer.After(20, function()
      local due = TorchcallDB and #ns.DueCheckIns() or 0
      if due > 0 then
        ns.Print(("%d recruit%s joined a few days ago. A quick check-in is what keeps them: open the Contacted tab."):format(due, due == 1 and "" or "s"))
      end
      for _, key in ipairs({ "info", "motd" }) do
        local state = TorchcallDB and ns.GuildText(key)
        if state and state.can and state.empty then
          ns.Print("Your " .. state.label:lower() .. " is empty. /torchcall guild shows what it could say, with the Discord and the site.")
        end
      end
    end)
  end
end
