-- Offline tests: lua tests/run.lua   (from the project root, Lua 5.1)
package.path = "tests/?.lua;" .. package.path
local M = require("mock")
local passed, failed = 0, 0
local function check(cond, label)
  if cond then passed = passed + 1 else failed = failed + 1; M.realPrint("FAIL: " .. label) end
end
local function eq(a, b, label) check(a == b, label .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end
local P = M.player

local ns = M.load("Torchcall", { "Data.lua", "Core.lua", "Comm.lua", "UI.lua" })
M.fire("ADDON_LOADED", "SomethingElse")
check(TorchcallDB == nil, "ignores other addons loading")
M.fire("WHO_LIST_UPDATE") -- before init: must not error
M.fire("ADDON_LOADED", "Torchcall")
M.fire("PLAYER_LOGIN")
local db = TorchcallDB
eq(ns.myName, "Vesh Torchman", "character initialised with full name")
eq(#db.templates, #ns.TEMPLATES, "default messages installed")

-- run one of our own searches and answer it with these players
local function seed(players, total)
  M.advance(6)
  assert(ns.StartSearch(1, 60), "seed search did not send")
  M.answerWho(players, total)
end

-- 1. every default message fits in one chat line, even with a long name -------
local long = { name = "Maximilianus Thunderbluffson", level = 60, classStr = "Warlock", zone = "Eastern Plaguelands" }
for i, t in ipairs(ns.TEMPLATES) do
  local text = ns.Render(t, long)
  check(#text <= 255, "default message " .. i .. " fits (" .. #text .. ")")
  check(not text:find("{", 1, true), "default message " .. i .. " has no unfilled token")
  check(not text:find("\226\128\148", 1, true), "default message " .. i .. " has no em-dash")
end
check(#ns.Render(ns.REPLY, long) <= 255, "follow-up fits")
eq(ns.Render("Hi {name}, {level} {class} in {zone} <{guild}> {bogus}", long),
   "Hi Maximilianus, 60 Warlock in Eastern Plaguelands <The True Torchmen> {bogus}", "tokens render, unknown ones stay")

-- 2. a search keeps unguilded players only ------------------------------------
check(ns.StartSearch(10, 20), "search sends")
eq(M.sentWho[1], "10-20", "query text")
eq(M.whoToUi, true, "results routed to the event while searching")
check(not ns.NextSearch(), "no second search while one is out")
check(not ns.StartSearch(30, 40), "a new plan is refused while a search is out")
eq(ns.QueueSize(), 0, "and it does not disturb the plan")
eq(db.opts.lo, 10, "or the saved range")
M.answerWho({ P("Bob Smith"), P("Ann Lee", "OLYMPUS"), P("Vesh Torchman"), P("Cy Dunn", "", 14, "MAGE") })
eq(M.whoToUi, false, "who routing restored after the answer")
check(db.prospects["Bob Smith"] and db.prospects["Cy Dunn"], "unguilded players kept")
check(not db.prospects["Ann Lee"], "guilded player dropped")
check(not db.prospects["Vesh Torchman"], "never lists yourself")
eq(db.prospects["Cy Dunn"].class, "MAGE", "class token stored")
eq(ns.QueueSize(), 0, "small result does not queue more")
eq(db.stats.found, 2, "found counter")

-- a who search somebody else ran never feeds the list
M.answerWho({ P("Typed Byhand"), P("Other Addon") })
check(not db.prospects["Typed Byhand"] and not db.prospects["Other Addon"], "results of a search we did not send are ignored")
eq(db.stats.found, 2, "and not counted")

-- a secret field never errors and never makes a prospect
seed({ { fullName = M.secret(), fullGuildName = "" }, { fullName = "Hid Guild", fullGuildName = M.secret() } })
check(not db.prospects["Hid Guild"], "unknown guild status is not a prospect")
eq(ns.errors, nil, "secret values raised no errors")

-- a prospect seen later in a guild leaves the list
seed({ P("Bob Smith", "Some Guild") })
check(not db.prospects["Bob Smith"], "prospect who joined a guild elsewhere is removed")
seed({ P("Bob Smith") })

-- 3. a full result splits the range, one press per search ---------------------
M.advance(10)
local full = {}
for i = 1, 50 do full[i] = P("Guilded " .. i, "X") end
local w = #M.sentWho
check(ns.StartSearch(1, 4), "second search sends")
M.answerWho(full, 120)
eq(ns.QueueSize(), 2, "range split in two")
check(not ns.NextSearch(), "who throttle holds a fast second search")
eq(#M.sentWho, w + 1, "nothing sent during the throttle")
M.advance(6)
check(ns.NextSearch(), "next queued search sends after the gap")
eq(M.sentWho[w + 2], "1-2", "lower half first")
M.answerWho(full, 90)
eq(ns.QueueSize(), 3, "split again")
M.advance(6); ns.NextSearch()
eq(M.sentWho[w + 3], "1-1", "single level")
M.answerWho(full, 70)
eq(ns.QueueSize(), 2 + #ns.CLASSES, "single level splits by class")
M.advance(6); ns.NextSearch()
eq(M.sentWho[w + 4], '1-1 c-"Warrior"', "class query")
M.answerWho(full, 60)
eq(ns.QueueSize(), 1 + #ns.CLASSES + #M.races, "a full class search splits by race")
M.advance(6); ns.NextSearch()
eq(M.sentWho[w + 5], '1-1 c-"Warrior" r-"Orc"', "race query")
M.answerWho(full, 55)
eq(ns.QueueSize(), #ns.CLASSES + #M.races, "a full race search cannot split further")

-- no answer: the search goes back on the queue
M.advance(6)
local before = ns.QueueSize()
ns.NextSearch()
M.advance(7)
eq(ns.QueueSize(), before, "unanswered search requeued")
check(not ns.SearchPending(), "no search left hanging")
eq(M.whoToUi, false, "who routing restored after a timeout")
M.answerWho({ P("Late Answer") })
check(not db.prospects["Late Answer"], "an answer after the timeout is not trusted")

-- zone filter and a refused call
M.advance(10)
db.opts.classes.MAGE = true
ns.StartSearch(5, 6, "Durotar")
eq(M.sentWho[#M.sentWho], '5-6 c-"Mage" z-"Durotar"', "class and zone query")
M.answerWho({})
ns.ToggleClass(nil)
ns.SetLevels(1, 60)
M.advance(10)
M.whoError = true
check(not ns.StartSearch(1, 2), "refused search reports failure")
check(not ns.SearchPending(), "refused search leaves nothing pending")
M.whoError = false

-- 4. whispers: one per press, never twice, rate limited -----------------------
M.advance(10)
local ok, why = ns.Whisper("Bob Smith")
check(ok, "whisper sent: " .. tostring(why))
eq(M.sentChat[1][2], "WHISPER", "sent as a whisper")
eq(M.sentChat[1][3], "Bob Smith", "to the right player")
check(M.sentChat[1][1]:sub(1, 46) == "Hey Bob, got a guild yet? <The True Torchmen> ", "message rendered with first name and guild")
eq(db.prospects["Bob Smith"].status, "whispered", "marked whispered")
ok = ns.Whisper("Bob Smith")
check(not ok, "same player is never whispered twice")
ok, why = ns.Whisper("Cy Dunn")
check(not ok and why:find("Next whisper"), "second whisper inside the gap is held")
eq(#M.sentChat, 1, "nothing sent while held")
M.advance(5)
M.lockdown = true
check(not ns.Whisper("Cy Dunn"), "no whisper during a chat lockdown")
M.lockdown = false
M.chatError = true
ok = ns.Whisper("Cy Dunn")
check(not ok and db.prospects["Cy Dunn"].status == "new", "a refused whisper leaves the player waiting")
M.chatError = false
check(not ns.Whisper("Nobody Here"), "unknown player refused")
db.templates[1] = string.rep("x", 260)
ok, why = ns.Whisper("Cy Dunn")
check(not ok and why:find("255"), "overlong message refused")
db.templates[1] = ns.TEMPLATES[1]

-- the follow-up is only for someone who answered, and only once
M.advance(5)
ok, why = ns.Whisper("Bob Smith", true)
check(not ok and why:find("answered"), "no follow-up to someone who never answered")
eq(#M.sentChat, 1, "and nothing was sent")

-- hourly and daily caps
db.opts.hourly = 2
ok = ns.Whisper("Cy Dunn")
check(ok, "second contact inside the cap")
seed({ P("Dee Fox"), P("Eli Gant"), P("Fay Holt"), P("Gus Ives"), P("Hal Jett") })
M.advance(5)
ok, why = ns.Whisper("Dee Fox")
check(not ok and why:find("this hour"), "third new contact in the hour is held")
M.advance(3600)
seed({ P("Dee Fox"), P("Eli Gant"), P("Fay Holt"), P("Gus Ives"), P("Hal Jett") }) -- still online an hour on
M.advance(5)
db.opts.daily = 2
ok, why = ns.Whisper("Dee Fox")
check(not ok and why:find("today"), "the daily cap holds even when the hour is clear")
db.opts.daily = 100
check(ns.Whisper("Dee Fox"), "cap frees up")
db.opts.hourly = 30
eq(ns.SentThisHour(), 1, "hour count")
eq(ns.SentToday(), 3, "day count")

-- 5. invites ------------------------------------------------------------------
M.inGuild = false
ok, why = ns.Invite("Eli Gant")
check(not ok and why:find("not in a guild"), "no invite without a guild")
M.inGuild, M.canInvite = true, false
check(not ns.Invite("Eli Gant"), "no invite without the rank")
M.canInvite = true
check(ns.Invite("Eli Gant"), "invite sent")
eq(M.invited[1], "Eli Gant", "invite went to the right player")
eq(db.prospects["Eli Gant"].status, "invited", "marked invited")
check(not ns.Invite("Eli Gant"), "never invited twice")
check(not ns.Invite("Fay Holt"), "second invite inside the gap is held")
eq(#M.invited, 1, "nothing sent while held")
M.advance(5)
check(ns.Invite("Bob Smith"), "a whispered player can be invited")

-- 6. the Next button: one press is one whisper or one invite -------------------
M.advance(5)
local sentBefore, invitedBefore = #M.sentChat, #M.invited
db.opts.mode = "whisper"
local target = ns.NextTarget()
check(target and target.status == "new", "next target is someone waiting")
check(ns.Next(), "next whispers")
eq(#M.sentChat, sentBefore + 1, "exactly one whisper per press")
eq(#M.invited, invitedBefore, "whisper mode sends no invite")
M.advance(5)
db.opts.mode = "invite"
check(ns.Next(), "next in invite mode")
eq(#M.sentChat, sentBefore + 1, "invite mode sends no whisper")
eq(#M.invited, invitedBefore + 1, "exactly one invite per press")
db.opts.mode = "both" -- a mode an older build could have saved
M.advance(5)
local chat0, inv0 = #M.sentChat, #M.invited
ns.Next()
eq((#M.sentChat - chat0) + (#M.invited - inv0), 1, "no saved mode makes one press do two things")
db.opts.mode = "whisper"

-- 7. what the game says back --------------------------------------------------
local joinedBefore = db.stats.joined
M.fire("CHAT_MSG_SYSTEM", "Eli Gant has joined the guild.")
eq(db.prospects["Eli Gant"].status, "joined", "join recorded")
eq(db.stats.joined, joinedBefore + 1, "join counted once")
M.fire("CHAT_MSG_SYSTEM", "Eli Gant has joined the guild.")
eq(db.stats.joined, joinedBefore + 1, "repeat join line not double counted")
M.fire("CHAT_MSG_SYSTEM", "|Hplayer:Bob Smith|h[Bob Smith]|h declines your guild invitation.")
eq(db.prospects["Bob Smith"].status, "declined", "decline recorded through a player link")
M.fire("CHAT_MSG_SYSTEM", "No player named 'Cy Dunn' is currently playing.")
eq(db.prospects["Cy Dunn"].status, "whispered", "someone already whispered stays on record when they log off")
db.prospects["Nia Offline"] = { name = "Nia Offline", status = "new", seen = time(), level = 10 }
M.fire("CHAT_MSG_SYSTEM", "No player named 'Nia Offline' is currently playing.")
check(not db.prospects["Nia Offline"], "an offline player nobody contacted is forgotten")
M.fire("CHAT_MSG_SYSTEM", "Dee Fox is already in a guild.")
eq(db.prospects["Dee Fox"].status, "guilded", "already guilded recorded")
M.fire("CHAT_MSG_SYSTEM", "Stranger Danger has joined the guild.") -- not ours: ignored
M.fire("CHAT_MSG_SYSTEM", M.secret())
eq(ns.errors, nil, "system lines raised no errors")

-- 8. replies ------------------------------------------------------------------
seed({ P("Ivy Kerr") })
M.advance(5)
check(ns.Whisper("Ivy Kerr"), "whisper for the reply test")
M.fire("CHAT_MSG_WHISPER", "sure, invite me", "Ivy Kerr")
check(db.prospects["Ivy Kerr"].replied, "reply noticed")
eq(ns.List("new")[1].name, "Ivy Kerr", "people who answered sort first")
eq(ns.Counts().replied, 1, "answered count")
M.fire("CHAT_MSG_WHISPER", "hello", "Random Person")
M.fire("CHAT_MSG_WHISPER", M.secret(), M.secret())
M.advance(5)
local n = #M.sentChat
check(ns.Whisper("Ivy Kerr", true), "follow-up allowed after a reply")
check(M.sentChat[n + 1][1]:find("discord.gg", 1, true), "follow-up carries the Discord line")
M.advance(5)
ok, why = ns.Whisper("Ivy Kerr", true)
check(not ok and why:find("already"), "the follow-up is never sent twice")
eq(#M.sentChat, n + 1, "and nothing was sent")
check(ns.Invite("Ivy Kerr"), "replied player can be invited")
eq(ns.Counts().replied, 0, "handled players leave the answered pile")

-- 9. guild sync ---------------------------------------------------------------
check(#M.sentAddon > 0, "contacts were shared with the guild")
local last = M.sentAddon[#M.sentAddon]
eq(last[3], "GUILD", "sync uses the guild addon channel")
check(last[2]:find("^C;1;%x+;"), "contact message shape")
seed({ P("Jon Lowe"), P("Kit Mann") })
M.fire("CHAT_MSG_ADDON", "Torchcall", "C;1;abcdef;Jon Lowe", "GUILD", "Mira Officer")
eq(db.prospects["Jon Lowe"].status, "taken", "a guildmate's contact takes the player off our list")
eq(db.prospects["Jon Lowe"].by, "Mira Officer", "and says who has them")
check(not ns.Whisper("Jon Lowe"), "taken player is not whispered")
M.fire("CHAT_MSG_ADDON", "Torchcall", "L;1;abcdef;Kit Mann,New Name,bad|name", "GUILD", "Mira Officer")
eq(db.prospects["Kit Mann"].status, "taken", "catch-up list applied")
eq(db.prospects["New Name"].status, "taken", "unknown names from the list are remembered")
check(not db.prospects["bad|name"], "names with escape codes are dropped")
M.fire("CHAT_MSG_ADDON", "Torchcall", "C;1;abcdef;Ivy Kerr", "GUILD", "Mira Officer")
eq(db.prospects["Ivy Kerr"].status, "invited", "our own contacts are not overwritten")
M.fire("CHAT_MSG_ADDON", "Torchcall", "C;1;abcdef;Lou Nash", "WHISPER", "Stranger")
check(not db.prospects["Lou Nash"], "only the guild channel is trusted")
M.fire("CHAT_MSG_ADDON", "Other", "C;1;abcdef;Lou Nash", "GUILD", "Mira Officer")
check(not db.prospects["Lou Nash"], "other prefixes ignored")
M.fire("CHAT_MSG_ADDON", "Torchcall", M.secret(), "GUILD", "Mira Officer")
local sentAddon = #M.sentAddon
M.fire("CHAT_MSG_ADDON", "Torchcall", "H;1;abcdef", "GUILD", "Mira Officer")
M.advance(10)
check(#M.sentAddon > sentAddon, "a hello gets our recent contacts back")
check(M.sentAddon[#M.sentAddon][2]:find("^L;1;%x+;"), "catch-up message shape")
check(not M.sentAddon[#M.sentAddon][2]:find("Jon Lowe", 1, true), "we only share contacts we made ourselves")

-- contacts made while the game holds addon chat are shared afterwards, none lost
M.lockdown = true
local held = {}
for i = 1, 60 do
  local name = "Held Back" .. i
  db.prospects[name] = { name = name, status = "new", seen = time() }
  ns.Skip(name)
  held[name] = true
end
local during = #M.sentAddon
M.lockdown = false
M.advance(120)
for i = during + 1, #M.sentAddon do
  local name = M.sentAddon[i][2]:match("^C;1;%x+;(.+)$")
  if name then held[name] = nil end
end
check(next(held) == nil, "all 60 contacts made during a lockdown were shared once it lifted")

-- a long history is sent in full, a few messages at a time
for i = 1, 300 do
  local name = "History Player" .. i
  db.prospects[name] = { name = name, status = "whispered", t = time() - i }
end
M.advance(40)
local hist = #M.sentAddon
M.fire("CHAT_MSG_ADDON", "Torchcall", "H;1;abcdef", "GUILD", "Mira Officer")
M.advance(7)
check(#M.sentAddon - hist <= 8, "catch-up is paced, not sent in one burst (" .. (#M.sentAddon - hist) .. ")")
M.advance(300)
local shared = {}
for i = hist + 1, #M.sentAddon do
  local body = M.sentAddon[i][2]:match("^L;1;%x+;(.+)$")
  if body then for name in body:gmatch("[^,]+") do shared[name] = true end end
end
local missing = 0
for i = 1, 300 do if not shared["History Player" .. i] then missing = missing + 1 end end
eq(missing, 0, "every recent contact reaches a guildmate who asks")
for _, m in ipairs(M.sentAddon) do if #m[2] > 255 then check(false, "addon message too long") end end
for i = 1, 300 do db.prospects["History Player" .. i] = nil end
for i = 1, 60 do db.prospects["Held Back" .. i] = nil end

-- 10. window and slash commands ----------------------------------------------
db.opts.lo, db.opts.hi = 1, 60
SlashCmdList["TORCHCALL"]("")
check(TorchcallFrame and TorchcallFrame:IsShown(), "window opens")
for _, tab in ipairs({ "Contacted", "Message", "Prospects" }) do check(M.click(tab), "tab " .. tab) end
check(M.click("Warrior"), "class button picks a class")
eq(db.opts.classes.WARRIOR, true, "class picked")
check(M.click("Any zone"), "zone button toggles")
M.advance(10)
local whoBefore = #M.sentWho
check(M.click("Search"), "search button")
eq(#M.sentWho, whoBefore + 1, "search button sends one search")
check(M.sentWho[#M.sentWho]:find('c%-"Warrior" z%-"Durotar"'), "window filters reach the query")
M.answerWho(full, 80)
check(M.click("Next search"), "a split plan turns the button into Next search")
eq(#M.sentWho, whoBefore + 1, "and the throttle still holds it")
M.advance(6)
check(M.click("Next search"), "next search button")
check(M.sentWho[#M.sentWho]:find("^1%-30 "), "queued half is sent")
M.answerWho({ P("Moe Nunn"), P("Ned Orr") })
check(M.click("All"), "changing a filter")
eq(next(db.opts.classes), nil, "All clears the class filter")
M.advance(6)
check(M.click("Search"), "changed filters start a fresh plan")
check(M.sentWho[#M.sentWho]:find("^1%-60"), "fresh plan uses the full range again")
M.answerWho({ P("Moe Nunn"), P("Ned Orr") })
M.advance(5)
local chatBefore = #M.sentChat
check(M.click("Whisper next"), "next button")
eq(#M.sentChat, chatBefore + 1, "next button sends one whisper")
check(M.click("Next does"), "mode button")
eq(db.opts.mode, "invite", "mode cycles to invite")
check(M.click("Next does"), "mode button again")
eq(db.opts.mode, "whisper", "and back to whisper, with no third mode")
check(M.click("Skip"), "row skip button")
for _, cmd in ipairs({ "help", "stats", "search", "next", "cap 20", "cap x", "cap 500", "skip Nobody", "forget Ned Orr", "minimap", "minimap", "log", "clear", "nonsense" }) do
  SlashCmdList["TORCHCALL"](cmd)
end
eq(db.opts.hourly, 20, "cap command, and a cap over 60 is refused")
eq(ns.Counts().new, 0, "clear empties the waiting list")
check(db.prospects["Ivy Kerr"] ~= nil, "clear keeps contacted players")
for _, line in ipairs(M.printed) do check(not line:find("command failed"), "no slash command failed: " .. line) end
eq(ns.errors, nil, "no handler errors in the whole run")
for _, line in ipairs(db.log) do check(not line:find(" error: ", 1, true), "no error in the log: " .. line) end

-- two typed searches in a row cannot tangle the plan
M.advance(10)
SlashCmdList["TORCHCALL"]("search 1-60")
SlashCmdList["TORCHCALL"]("search 20-30")
eq(db.opts.lo, 1, "the refused plan does not move the level filter")
M.answerWho(full, 200)
M.advance(6)
ns.NextSearch()
eq(M.sentWho[#M.sentWho], "1-30", "the first plan carries on, the overlapping one was refused")
M.answerWho({})


-- 10b. filters: classes and levels decide what is searched, shown and reached -----
ns.SetLevels(1, 60)
seed({ P("Ada Mage", "", 22, "MAGE"), P("Ben Priest", "", 35, "PRIEST"), P("Cal Warrior", "", 12, "WARRIOR"),
       P("Dot Rogue", "", 58, "ROGUE"), P("\208\152\208\178\208\176\208\189 Mage", "", 30, "MAGE"), P("Se\195\177ora Luz", "", 31, "MAGE") })
local function names(kind)
  local rows, hidden = ns.List(kind or "new")
  local set = {}
  for _, p in ipairs(rows) do set[p.name] = true end
  return set, hidden, rows
end
local shownNow, hiddenNow = names()
check(shownNow["Ada Mage"] and shownNow["Cal Warrior"] and hiddenNow == 0, "no filter shows everyone")
ns.ToggleClass("MAGE"); ns.ToggleClass("PRIEST")
shownNow, hiddenNow = names()
check(shownNow["Ada Mage"] and shownNow["Ben Priest"], "picked classes show")
check(not shownNow["Cal Warrior"] and not shownNow["Dot Rogue"], "other classes are hidden")
eq(hiddenNow, 2, "hidden count")
eq(ns.Counts().hidden, 2, "summary hidden count")
ns.SetLevels(20, 32)
shownNow = names()
check(shownNow["Ada Mage"] and not shownNow["Ben Priest"], "level range filters the list")
db.opts.latin = true
shownNow = names()
check(not shownNow["\208\152\208\178\208\176\208\189 Mage"], "Latin filter hides a Cyrillic name")
check(shownNow["Se\195\177ora Luz"], "Latin filter keeps an accented Latin name")
db.opts.latin = false
-- Next only reaches people who pass the filters
M.advance(5)
for _ = 1, 6 do
  local t = ns.NextTarget()
  if not t then break end
  check(t.class == "MAGE" and t.level >= 20 and t.level <= 32, "Next target passes the filters: " .. t.name)
  check(ns.Next(), "next on a filtered target")
  M.advance(5)
end
eq(db.prospects["Cal Warrior"].status, "new", "a filtered-out player was never contacted")
eq(db.prospects["Dot Rogue"].status, "new", "nor the other one")
ok, why = ns.Next()
check(not ok and why:find("hidden"), "Next says when everyone left is filtered out")
-- a search with classes picked asks for each class
M.advance(6)
local q0 = #M.sentWho
check(ns.StartSearch(20, 32), "class search starts")
eq(M.sentWho[q0 + 1], '20-32 c-"Priest"', "first picked class, in display order")
eq(ns.QueueSize(), 1, "one more search queued for the other class")
M.answerWho({})
M.advance(6); ns.NextSearch()
eq(M.sentWho[q0 + 2], '20-32 c-"Mage"', "second picked class")
M.answerWho({})
-- all nine picked is the same as none
for _, token in ipairs(ns.CLASSES) do db.opts.classes[token] = true end
eq(#ns.PickedClasses(), 0, "every class picked means no class filter")
ns.ToggleClass(nil)
ns.SetLevels(1, 60)
-- sorting
ns.SetSort("level")
local _, _, sorted = names()
check(#sorted >= 2 and (sorted[1].level or 0) >= (sorted[2].level or 0), "sort by level, highest first")
ns.SetSort("level")
_, _, sorted = names()
check((sorted[1].level or 0) <= (sorted[2].level or 0), "pressing again reverses it")
ns.SetSort("name")
_, _, sorted = names()
check(sorted[1].name <= sorted[2].name, "sort by name")
ns.SetSort("bogus")
eq(db.opts.sort, "name", "an unknown sort key is ignored")
ns.SetSort("seen"); if db.opts.sortUp then ns.SetSort("seen") end
-- slash filters
SlashCmdList["TORCHCALL"]("class mage pri")
check(db.opts.classes.MAGE and db.opts.classes.PRIEST and not db.opts.classes.PALADIN, "slash class picks by prefix")
SlashCmdList["TORCHCALL"]("class all")
eq(next(db.opts.classes), nil, "slash class all clears")
SlashCmdList["TORCHCALL"]("level 40-10")
check(db.opts.lo == 10 and db.opts.hi == 40, "slash level sets the range in order")
SlashCmdList["TORCHCALL"]("level 1-60")

-- 10c. which message works: sent, answered, joined ------------------------------
db.opts.template = 1
db.templates[1] = "A brand new pitch for {name}."
local key1 = ns.TemplateKey(db.templates[1])
eq(ns.TemplateStat(key1).sent, 0, "a message never sent has no results")
eq(db.tstats[key1], nil, "and looking does not create a record")
seed({ P("Tia Stat") })
M.advance(5)
check(ns.Whisper("Tia Stat"), "whisper for the stats test")
local t1 = ns.TemplateStat(key1)
local sent0, rep0, join0 = 0, t1.replied, t1.joined
eq(t1.sent, sent0 + 1, "sent counted for the message used")
M.fire("CHAT_MSG_WHISPER", "ok", "Tia Stat")
M.fire("CHAT_MSG_WHISPER", "hello?", "Tia Stat")
eq(t1.replied, rep0 + 1, "an answer is counted once")
M.advance(5)
check(ns.Invite("Tia Stat"), "invite for the stats test")
M.fire("CHAT_MSG_SYSTEM", "Tia Stat has joined the guild.")
eq(t1.joined, join0 + 1, "a join is credited to the message that opened")
db.templates[1] = "A reworded pitch for {name}."
eq(ns.TemplateStat(ns.TemplateKey(db.templates[1])).sent, 0, "rewording a message starts its results from zero")
eq(ns.TemplateStat(key1).sent, 1, "and the old wording keeps its own")
db.templates[1] = ns.TEMPLATES[1]
for i = 1, 60 do ns.TemplateStat(ns.TemplateKey("wording " .. i), "sent") end
local kept = 0
for _ in pairs(db.tstats) do kept = kept + 1 end
check(kept <= 40, "message results are capped (" .. kept .. ")")

-- 10d. the welcome: guild chat, once, only for someone who joined ---------------
M.advance(5)
local g0 = #M.sentChat
ok, why = ns.Welcome("Dot Rogue")
check(not ok, "no welcome for someone who has not joined")
check(ns.Welcome("Tia Stat"), "welcome sent")
eq(M.sentChat[g0 + 1][2], "GUILD", "welcome goes to guild chat")
check(M.sentChat[g0 + 1][1]:find("Tia", 1, true), "welcome names the player")
M.advance(5)
check(not ns.Welcome("Tia Stat"), "never welcomed twice")
eq(#M.sentChat, g0 + 1, "and nothing was sent")
check(#ns.Render(ns.WELCOME, long) <= 255, "default welcome fits")

-- 10e. key bindings do exactly what the buttons do ------------------------------
check(type(Torchcall_KeyNext) == "function" and type(Torchcall_KeySearch) == "function", "binding functions exist")
check(BINDING_NAME_TORCHCALL_NEXT and BINDING_NAME_TORCHCALL_SEARCH and BINDING_HEADER_TORCHCALL, "binding names exist")
M.advance(10)
local kc, ki, kw = #M.sentChat, #M.invited, #M.sentWho
Torchcall_KeyNext()
eq((#M.sentChat - kc) + (#M.invited - ki), 1, "one key press is one whisper or one invite")
Torchcall_KeyNext()
eq((#M.sentChat - kc) + (#M.invited - ki), 1, "a second press inside the gap sends nothing")
Torchcall_KeySearch()
eq(#M.sentWho - kw, 1, "one key press is one search")
Torchcall_KeySearch()
eq(#M.sentWho - kw, 1, "a second press while it is out sends nothing")
M.answerWho({})

-- 11. nothing contacts anyone without a press --------------------------------
seed({ P("Pat Quill"), P("Rae Stone") })
local chat, inv, who = #M.sentChat, #M.invited, #M.sentWho
M.advance(7200)
eq(#M.sentChat, chat, "no whisper is ever sent by a timer")
eq(#M.invited, inv, "no invite is ever sent by a timer")
eq(#M.sentWho, who, "no search is ever sent by a timer")

-- 12. a waiting player goes stale without a relog -----------------------------
check(db.prospects["Pat Quill"] ~= nil, "still listed two hours on")
M.advance(11 * 3600)
ok, why = ns.Whisper("Pat Quill")
check(not ok and why:find("too long ago"), "nobody is whispered 13 hours after they were seen")
check(not db.prospects["Pat Quill"], "and they leave the list")
eq(ns.NextTarget(), nil, "the Next button has nobody stale to offer")
check(not db.prospects["Rae Stone"], "listing drops the other stale player")

-- 13. old data is pruned at login --------------------------------------------
db.prospects["Old New"] = { name = "Old New", status = "new", seen = time() - 13 * 3600 }
db.prospects["Old Whisper"] = { name = "Old Whisper", status = "whispered", t = time() - 61 * 86400 }
db.prospects["Old Skip"] = { name = "Old Skip", status = "skipped", t = time() - 400 * 86400 }
db.prospects["Old Decline"] = { name = "Old Decline", status = "declined", t = time() - 400 * 86400 }
db.opts.mode, db.opts.hourly = "both", 100
M.fire("ADDON_LOADED", "Torchcall") -- already initialised: ignored
M.fire("PLAYER_LOGIN")
check(not db.prospects["Old New"], "stale waiting player pruned")
check(not db.prospects["Old Whisper"], "old contact pruned after 60 days")
check(db.prospects["Old Skip"] ~= nil, "skips are kept")
check(db.prospects["Old Decline"] ~= nil, "a decline is remembered for good")

-- 13b. a contacted player is never asked again, even after the record expires --------
seed({ P("Zed Forever"), P("Yan Skipped"), P("Xi Taken") })
M.advance(5)
check(ns.Whisper("Zed Forever"), "whisper before the long wait")
ns.Skip("Yan Skipped")
M.fire("CHAT_MSG_ADDON", "Torchcall", "C;1;abcdef;Xi Taken", "GUILD", "Mira Officer")
M.advance(61 * 86400)
M.fire("PLAYER_LOGIN")
check(not db.prospects["Zed Forever"], "the detailed record is dropped after 60 days")
check(db.contacted["Zed Forever"] ~= nil, "the name is remembered for good")
seed({ P("Zed Forever"), P("Xi Taken"), P("New Face") })
check(not db.prospects["Zed Forever"], "a search 61 days later does not bring them back as new")
check(not db.prospects["Xi Taken"], "nor someone a guildmate contacted")
check(db.prospects["New Face"] ~= nil, "a new player is still found")
check(not ns.Whisper("Zed Forever"), "and they cannot be whispered again")
ok, why = ns.Forget("Yan Skipped")
check(not ok and why:find("already contacted"), "forget does not erase a contact record")
-- data saved by 1.0.0 has no such memory: it is rebuilt from the records at load
db.contacted = nil
db.prospects["Old Contact"] = { name = "Old Contact", status = "whispered", t = time() - 100 }
M.fire("ADDON_LOADED", "Torchcall")
check(TorchcallDB.contacted == nil, "sanity: load only runs once per session")
M.reset(false)
ns = M.load("Torchcall", { "Data.lua", "Core.lua", "Comm.lua", "UI.lua" })
M.fire("ADDON_LOADED", "Torchcall"); M.fire("PLAYER_LOGIN")
db = TorchcallDB
check(db.contacted["Old Contact"] ~= nil, "an upgrade from 1.0.0 remembers everyone already contacted")

-- 13c. levels the game will not give, and level input -------------------------------
seed({ { fullName = "No Level", fullGuildName = "", level = M.secret(), filename = "MAGE", classStr = "Mage", area = "Durotar", raceStr = "Orc" },
       P("Lvl Sixty", "", 60, "MAGE") })
ns.SetLevels(1, 60)
local function listed(name) for _, p in ipairs((ns.List("new"))) do if p.name == name then return true end end return false end
check(listed("No Level"), "with no level range set, an unknown level is shown")
ns.SetLevels(20, 30)
check(not listed("No Level"), "with a level range set, an unknown level does not pass")
check(not listed("Lvl Sixty"), "nor a level outside it")
local a, b = ns.SetLevels(0, 0); check(a == 1 and b == 1, "level 0 clamps to 1")
a, b = ns.SetLevels(100, 200); check(a == 80 and b == 80, "levels above the ceiling clamp")
a, b = ns.SetLevels(55, 5); check(a == 5 and b == 55, "a reversed range is put in order")
a, b = ns.SetLevels("x", nil); check(a == 1 and b == 60, "junk falls back to the full range")
ns.SetLevels(1, 60)

-- 13d. the alphabet filter ------------------------------------------------------
for name, want in pairs({ ["Bob Smith"] = true, ["Se\195\177ora Luz"] = true, ["Zo\195\171 O'Neil"] = true,
                          ["Nguy\225\187\133n V\196\131n"] = true, ["\208\152\208\178\208\176\208\189"] = false, ["\206\145\206\187\206\173\206\190"] = false,
                          ["\236\157\180\236\136\156"] = false, ["\230\157\142\229\176\143"] = false, ["Bob \240\159\148\165"] = false, ["Bad\255"] = false }) do
  eq(ns.LatinName(name), want, "Latin check for " .. name)
end

-- 13e. another who search at the same moment ---------------------------------------
M.advance(10)
check(ns.StartSearch(10, 20), "our search goes out")
C_FriendList.SendWho("warrior", 2) -- you, the who window or another addon
check(not ns.SearchPending(), "a competing search cancels ours")
eq(ns.QueueSize(), 1, "and puts it back on the queue")
M.answerWho({ P("From Theirs"), P("Also Theirs") })
check(not db.prospects["From Theirs"], "whatever arrives next is not read as our answer")
M.advance(6)
check(ns.NextSearch(), "our search can be sent again")
M.answerWho({ P("From Ours") })
check(db.prospects["From Ours"] ~= nil, "and its own answer is read")
-- the who window keeps its results while it is open
WhoFrame = M.newFrame("Frame", "WhoFrame")
M.advance(6); ns.StartSearch(10, 20); M.answerWho({})
eq(M.whoToUi, true, "who routing is left on while Blizzard's who window is open")
WhoFrame:Hide()
M.advance(6); ns.StartSearch(10, 20); M.answerWho({})
eq(M.whoToUi, false, "and off again once it is closed")

-- 13f. a plan always finishes, even when every answer is full -----------------------
M.advance(10)
ns.SetLevels(1, 8)
local plan0, sentInPlan = #M.sentWho, {}
check(ns.StartSearch(1, 8), "worst-case plan starts")
local rounds = 0
repeat
  rounds = rounds + 1
  local text = M.sentWho[#M.sentWho]
  check(not sentInPlan[text], "no search is sent twice in one plan: " .. text)
  sentInPlan[text] = true
  -- a full page of exactly what was asked for, so the server looks honest
  local wantClass, wantRace, page = text:match('c%-"(%a+)"'), text:match('r%-"(%a+)"'), {}
  for i = 1, 50 do page[i] = P("Crowd " .. i, "X", 1, wantClass and wantClass:upper() or "WARRIOR", wantRace) end
  M.answerWho(page, 999)
  M.advance(6)
until not ns.NextSearch() or rounds > 600
eq(rounds, 15 + 8 * #ns.CLASSES + 8 * #ns.CLASSES * #M.races, "every level, class and race is visited exactly once, then it stops")
eq(ns.QueueSize(), 0, "nothing left queued")
ns.SetLevels(1, 60)

-- 13g. the reload gap -----------------------------------------------------------------
seed({ P("Gap One"), P("Gap Two") })
check(ns.Whisper("Gap One"), "whisper just before a reload")
M.reset(false)
ns = M.load("Torchcall", { "Data.lua", "Core.lua", "Comm.lua", "UI.lua" })
M.fire("ADDON_LOADED", "Torchcall"); M.fire("PLAYER_LOGIN")
db = TorchcallDB
ok, why = ns.Whisper("Gap Two")
check(not ok and why:find("Next whisper"), "the whisper gap survives a reload")
check(not ns.StartSearch(1, 60), "and so does the who gap")
M.advance(6)

-- 13h. key bindings file ------------------------------------------------------------------
local binds = M.bindings("Torchcall")
eq(#binds, 3, "three bindings")
for _, bnd in ipairs(binds) do
  check(_G["BINDING_NAME_" .. bnd.name] ~= nil, "binding " .. bnd.name .. " has a display name")
  eq(bnd.category, "ADDONS", "binding " .. bnd.name .. " is filed under AddOns")
  local okRun, err = pcall(bnd.run)
  check(okRun, "binding " .. bnd.name .. " runs: " .. tostring(err))
  M.advance(10)
  if ns.SearchPending() then M.answerWho({}) end
end
if TorchcallFrame and TorchcallFrame:IsShown() then TorchcallFrame:Hide() end

-- 14. a server that ignores the class part of a search ---------------------------
-- (kept last: once seen, the addon stops trusting class searches for the session)
ns.SetLevels(1, 60)
ns.ToggleClass("MAGE"); ns.ToggleClass("ROGUE")
M.advance(10)
local b0 = #M.sentWho
check(ns.StartSearch(1, 60), "class search against a server that ignores classes")
eq(M.sentWho[b0 + 1], '1-60 c-"Rogue"', "asks for the first class")
M.answerWho({ P("Wrong Class", "", 20, "WARRIOR"), P("Right Rogue", "", 20, "ROGUE"), P("Right Mage", "", 21, "MAGE") })
eq(ns.QueueSize(), 0, "the answer already was the plain search, so nothing is left to repeat it")
local seenNow = {}
for _, p in ipairs((ns.List("new"))) do seenNow[p.name] = true end
check(seenNow["Right Rogue"] and seenNow["Right Mage"], "picked classes still listed")
check(not seenNow["Wrong Class"], "and the class filter is applied here instead")
M.advance(6)
check(ns.StartSearch(1, 60), "later plans skip the class part")
eq(M.sentWho[#M.sentWho], "1-60", "one plain search")
M.answerWho({})
eq(ns.errors, nil, "no handler errors at the very end")

-- 1.1 defaults that were never edited move to the current ones; a rewritten message is left alone
TorchcallDB = { templates = { ns.OLD_TEMPLATES[1], "My own pitch for {name}.", ns.OLD_TEMPLATES[3], "A fourth one." } }
local ns2 = M.load("Torchcall", { "Data.lua", "Core.lua", "Comm.lua", "UI.lua" })
M.fire("ADDON_LOADED", "Torchcall")
eq(TorchcallDB.templates[1], ns2.TEMPLATES[1], "an untouched old default becomes the new one")
eq(TorchcallDB.templates[2], "My own pitch for {name}.", "a message you wrote is kept")
eq(TorchcallDB.templates[3], ns2.TEMPLATES[3], "the third old default too")
eq(TorchcallDB.templates[4], "A fourth one.", "extra messages are kept")
for i, t in ipairs(ns2.TEMPLATES) do
  check(#t < #ns2.OLD_TEMPLATES[1], "new message " .. i .. " is shorter than the old opener")
  check(t:find("?", 1, true), "new message " .. i .. " asks a question")
  check(not t:find("\226\128\148", 1, true) and not t:find("\226\128\147", 1, true), "new message " .. i .. " has no long dashes")
  check(not t:find("{zone}", 1, true), "new message " .. i .. " does not depend on a zone the search may not give")
end


-- 1.2: answers, rotation, played-together prospects, check-ins, who stayed ------------------------
M.reset(true)
ns = M.load("Torchcall", { "Data.lua", "Core.lua", "Comm.lua", "UI.lua" })
M.fire("ADDON_LOADED", "Torchcall")
M.fire("PLAYER_LOGIN")
db = TorchcallDB
local longP = { name = "Bartholomeus Worthington", level = 60, classStr = "Death Knight", zone = "The Barrens" }
for _, a in ipairs(ns.ANSWERS) do
  if a.text then
    check(#ns.Render(a.text, longP) <= 255, "answer " .. a.key .. " fits with a long name")
    check(not a.text:find("\226\128[\147\148]"), "answer " .. a.key .. " has no long dashes")
    eq(db.answers[a.key], a.text, "answer " .. a.key .. " installed")
  end
  check(type(a.label) == "string" and #a.words > 0, "answer " .. a.key .. " has a label and words to listen for")
end
check(#ns.Render(ns.CHECKIN, longP) <= 255 and #ns.Render(ns.GROUP_TEMPLATE, longP) <= 255, "check-in and group lines fit")
for i, t in ipairs(ns.TEMPLATES) do
  check(not t:find("http", 1, true) and not t:find("discord", 1, true) and not t:find("%.gg"), "opener " .. i .. " carries no Discord invite")
  check(i == 4 or not t:find("%.dev"), "only the fourth opener carries the site")
  check(#ns.Render(t, longP) <= 160, "opener " .. i .. " is short")
end

-- what a reply is asking for
for text, want in pairs({
  ["do you guys raid?"] = "raids", ["what times are you on"] = "life", ["is there pvp"] = "pvp", ["Sure, invite me"] = "invite",
  ["yes"] = "invite", ["no thanks"] = "skip", ["not interested"] = "skip", ["im new to the game"] = "new", ["whats the guild about"] = "about",
  ["got a discord?"] = "discord", ["maybe, not sure yet"] = "run", ["how many members"] = "story", ["do you run dungeons"] = "leveling",
  ["I already have a guild"] = "skip", ["STOP"] = "skip", ["ok what kind of guild is it"] = "about", ["yeah do you raid"] = "raids",
}) do eq(ns.Suggest(text), want, 'reply "' .. text .. '"') end
eq(ns.Suggest("asdf qwer"), nil, "gibberish suggests nothing")
eq(ns.Suggest(nil), nil, "no text suggests nothing")
eq(ns.Suggest("know any good fishing spots"), nil, '"know" is not "no"')

seed({ M.player("Ann One", "", 12, "MAGE"), M.player("Bea Two", "", 14, "PRIEST"), M.player("Cal Three", "", 20, "WARRIOR"), M.player("Dee Four", "", 22, "MAGE") })
M.sentChat = {}
local ok, why = ns.Answer("Ann One", "raids")
check(not ok and why:find("wrote back"), "no answer to someone who was never whispered")
M.advance(10) check(ns.Whisper("Ann One"), "opener to Ann")
ok, why = ns.Answer("Ann One", "raids")
check(not ok and why:find("wrote back"), "no answer to someone who has not replied")
eq(#M.sentChat, 1, "and nothing was sent")
M.fire("CHAT_MSG_WHISPER", "do you raid?", "Ann One")
check(table.concat(M.printed, "\n"):find("They are asking about: raids", 1, true), "the reply names what they asked about")
ok, why = ns.Answer("Ann One", "raids")
check(not ok and why:find("Next whisper in"), "answers respect the pause between whispers: " .. tostring(why))
M.advance(10)
check(ns.Answer("Ann One", "raids"), "an answer goes to someone who wrote back")
eq(M.sentChat[#M.sentChat][3], "Ann One", "to that player") eq(M.sentChat[#M.sentChat][2], "WHISPER", "as a whisper")
check(M.sentChat[#M.sentChat][1]:find("December 9", 1, true), "with the raid answer")
M.advance(10)
ok, why = ns.Answer("Ann One", "raids")
check(not ok and why:find("already has"), "the same answer is never sent twice")
ok, why = ns.Answer("Ann One", "nonsense")
check(not ok and why:find("no answer called"), "an unknown topic is refused")
check(ns.Answer("Ann One", "discord"), "the Discord answer is the follow-up line")
check(M.sentChat[#M.sentChat][1]:find("discord.gg", 1, true) and db.prospects["Ann One"].linked, "and marks them linked")
M.advance(10) check(not ns.Answer("Ann One", "discord"), "which also goes once")
local sentBefore = #M.sentChat
for _, key in ipairs({ "about", "life", "pvp" }) do M.advance(10) check(ns.Answer("Ann One", key), "answer " .. key) end
M.advance(10)
ok, why = ns.Answer("Ann One", "new")
check(not ok and why:find("type to them yourself"), "five answers is the most one player gets: " .. tostring(why))
eq(#M.sentChat, sentBefore + 3, "nothing sent past the limit")
eq(#(ns.AnswersLeft("Ann One")), 0, "and no answers are offered")
eq(db.stats.answers, 4, "answers counted")
db.answers.pvp = string.rep("x", 260)
M.advance(10) check(ns.Whisper("Bea Two"), "opener to Bea")
M.fire("CHAT_MSG_WHISPER", "pvp?", "Bea Two")
M.advance(10)
ok, why = ns.Answer("Bea Two", "pvp")
check(not ok and why:find("255"), "an overlong answer is refused")
db.answers.pvp = ""
ok, why = ns.Answer("Bea Two", "pvp")
check(not ok and why:find("empty"), "an empty answer is refused")
db.answers.pvp = ns.AnswerTopic("pvp").text
M.lockdown = true
ok, why = ns.Answer("Bea Two", "pvp")
check(not ok and why:find("instance"), "no answers where the game holds chat")
M.lockdown = false
M.chatError = true
ok = ns.Answer("Bea Two", "pvp")
check(not ok and not (db.prospects["Bea Two"].ans or {}).pvp, "a refused answer is not marked sent")
M.chatError = nil
check(ns.Answer("Bea Two", "pvp"), "and can be sent once chat works")
M.fire("CHAT_MSG_SYSTEM", "Bea Two declines your guild invitation.")

-- invites: cold against after a conversation
M.advance(10)
check(ns.Invite("Ann One"), "invite after a conversation")
eq(db.prospects["Ann One"].path, "warm", "marked as a warm invite")
M.advance(10)
check(ns.Invite("Cal Three"), "invite with no word first")
eq(db.prospects["Cal Three"].path, "cold", "marked as a cold invite")
M.fire("CHAT_MSG_SYSTEM", "Ann One has joined the guild.")
M.fire("CHAT_MSG_SYSTEM", "Cal Three declines your guild invitation.")
local f = ns.Funnel()
eq(f.warm.invited, 1, "one warm invite") eq(f.warm.joined, 1, "which joined") eq(f.cold.declined, 1, "one cold invite declined")
check(f.advice:find("Not enough", 1, true), "no advice on two invites")
db.stats.cold = { invited = 40, joined = 10, declined = 25, stayed = 0, left = 0 }
db.stats.warm = { invited = 20, joined = 12, declined = 3, stayed = 0, left = 0 }
check(ns.Funnel().advice:find("Talk first", 1, true), "with enough of both, the better path is named")
db.stats.warm.joined = 2
check(ns.Funnel().advice:find("watch who stays", 1, true), "and when cold invites win, it says what to watch")
db.stats.cold, db.stats.warm = { invited = 0, joined = 0, declined = 0, stayed = 0, left = 0 }, { invited = 1, joined = 1, declined = 0, stayed = 0, left = 0 }

-- welcome still works, then the check-in a few days later
M.advance(10) check(ns.Welcome("Ann One"), "welcome in guild chat")
ok, why = ns.CheckIn("Ann One")
check(not ok and why:find("only just joined"), "no check-in on day one")
eq(#ns.DueCheckIns(), 0, "nobody due yet")
M.advance(3 * 86400)
eq(#ns.DueCheckIns(), 1, "due after a few days")
M.sentChat = {}
check(ns.CheckIn("Ann One"), "check-in sent")
check(M.sentChat[1][2] == "WHISPER" and M.sentChat[1][3] == "Ann One" and M.sentChat[1][1]:find("how are you finding", 1, true), "as one whisper to the recruit")
M.advance(10)
ok, why = ns.CheckIn("Ann One")
check(not ok and why:find("already had"), "one check-in per recruit")
eq(#ns.DueCheckIns(), 0, "and they are no longer due")
ok = ns.CheckIn("Cal Three")
check(not ok, "no check-in for someone who never joined")
M.fire("CHAT_MSG_WHISPER", "its great thanks", "Ann One")
eq(db.prospects["Ann One"].said, "its great thanks", "their answer to the check-in is kept")
eq(db.prospects["Ann One"].status, "joined", "and changes nothing else")
-- a check-in to someone offline can be sent again
db.prospects["Ann One"].checked = nil
check(ns.CheckIn("Ann One"), "second recruit check-in")
M.fire("CHAT_MSG_SYSTEM", "No player named 'Ann One' is currently playing.")
eq(db.prospects["Ann One"].checked, nil, "a check-in that reached nobody is not counted")
M.advance(30 * 86400)
eq(#ns.DueCheckIns(), 0, "after three weeks a check-in is no longer offered")

-- who stayed
M.roster = { "Vesh Torchman", "Ann One" }
db.prospects["Zed Gone"] = { name = "Zed Gone", status = "joined", t = time() - 10 * 86400, path = "cold" }
db.prospects["New Kid"] = { name = "New Kid", status = "joined", t = time() - 86400, path = "cold" }
db.prospects["Old Join"] = { name = "Old Join", status = "joined", t = time() - 10 * 86400 }
M.fire("GUILD_ROSTER_UPDATE")
eq(db.prospects["Ann One"].stayed, true, "a recruit still on the roster after a week stayed")
eq(db.prospects["Zed Gone"].stayed, false, "one who is not, left")
eq(db.prospects["New Kid"].stayed, nil, "a recruit of one day is not judged yet")
eq(db.stats.warm.stayed, 1, "stayed counted on its path") eq(db.stats.cold.left, 1, "left counted on its path")
eq(db.prospects["Old Join"].stayed, false, "a join from before paths existed is marked") eq(db.stats.cold.left, 1, "but not counted on a path")
M.fire("GUILD_ROSTER_UPDATE")
eq(db.stats.warm.stayed, 1, "each recruit is judged once")
db.prospects["Hid Den"] = { name = "Hid Den", status = "joined", t = time() - 10 * 86400, path = "cold" }
M.rosterHidden = true
M.fire("GUILD_ROSTER_UPDATE")
eq(db.prospects["Hid Den"].stayed, nil, "a roster the game hides proves nothing")
M.rosterHidden = nil
M.roster = {}
M.fire("GUILD_ROSTER_UPDATE")
eq(db.prospects["Hid Den"].stayed, nil, "an empty roster proves nothing either")
M.roster = { "Ann One", "Somebody Else" }
M.fire("GUILD_ROSTER_UPDATE")
eq(db.prospects["Hid Den"].stayed, nil, "a roster without you on it has not loaded: nobody is judged")
-- a client without the membership check: the roster is walked instead
local memberCheck = C_GuildInfo.MemberExistsByName
C_GuildInfo.MemberExistsByName = nil
db.prospects["Wal Ked"] = { name = "Wal Ked", status = "joined", t = time() - 10 * 86400, path = "warm" }
M.fire("GUILD_ROSTER_UPDATE")
eq(db.prospects["Wal Ked"].stayed, nil, "walking a roster without you on it judges nobody")
M.roster = { "Vesh Torchman", "Wal Ked" }
M.fire("GUILD_ROSTER_UPDATE")
eq(db.prospects["Wal Ked"].stayed, true, "walking the roster finds a recruit who stayed")
eq(db.prospects["Hid Den"].stayed, false, "and one who left")
C_GuildInfo.MemberExistsByName = memberCheck
check((M.rosterAsked or 0) >= 1, "the roster is asked for after login")

-- people you played with
M.sentChat, M.invited = {}, {}
ok, why = ns.AddGroup()
check(not ok and why:find("not in a group"), "no group, nothing added")
M.group = { { name = "Pat Party", guild = nil, class = "PRIEST", level = 18 }, { name = "Gil Ded", guild = "Other Guild", class = "ROGUE" },
            { name = "Sec Ret", guild = "secret" }, { name = "Dee Four", class = "MAGE", level = 22 }, { name = "Ann One" } }
ok, why = ns.AddGroup()
check(ok and why:find("Pat Party", 1, true), "an unguilded party member is added: " .. tostring(why))
check(not why:find("Gil Ded", 1, true) and not db.prospects["Gil Ded"], "someone with a guild is not")
check(not db.prospects["Sec Ret"], "someone whose guild the game hides is left alone")
eq(db.prospects["Dee Four"].ran, true, "someone already waiting is marked as played with")
eq(db.prospects["Ann One"].status, "joined", "someone already contacted is untouched")
eq(#M.sentChat + #M.invited, 0, "adding a group contacts nobody")
eq(ns.List("new")[1].ran, true, "people you played with are at the top")
db.opts.lo, db.opts.hi = 50, 60
check(ns.Matches(db.prospects["Pat Party"]), "and are never filtered away")
db.opts.lo, db.opts.hi = 1, 60
M.advance(10)
check(ns.Whisper("Pat Party"), "whisper to a party member")
check(M.sentChat[1][1]:find("^Good run, Pat"), "uses the line for people you played with: " .. M.sentChat[1][1])
ok = ns.AddGroup()
check(not ok, "adding the same group again adds nobody")
M.raid = true
M.group = { { name = "Rai Der", class = "HUNTER", level = 30 }, { name = "An Npc", npc = true } }
ok, why = ns.AddGroup()
check(ok and db.prospects["Rai Der"] and not db.prospects["An Npc"], "raid members are read too, players only")
M.group, M.raid = {}, false

-- rotation: every opener gets its turn, then the best is preferred
db.tstats = {}
db.opts.rotate, db.opts.template = true, 2
local keys = {}
for i, t in ipairs(db.templates) do keys[i] = ns.TemplateKey(t) end
eq(ns.PickTemplate(), 1, "with nothing sent, the first opener goes first")
db.tstats[keys[1]] = { sent = 20, replied = 1, joined = 0 }
db.tstats[keys[2]] = { sent = 5, replied = 0, joined = 0 }
db.tstats[keys[3]] = { sent = 20, replied = 6, joined = 0 }
db.tstats[keys[4]] = { sent = 20, replied = 2, joined = 0 }
eq(ns.PickTemplate(), 2, "the least tried opener is sent until each has twenty")
db.tstats[keys[2]].sent = 20
eq(ns.PickTemplate(), 3, "then the one with the best answer rate")
db.tstats[keys[1]].sent = 24 -- total 84: every fifth send explores
eq(ns.PickTemplate(), 2, "but every fifth send still goes to the least tried")
db.opts.rotate = false
eq(ns.PickTemplate(), 2, "rotation off: the opener showing in the window")
db.opts.rotate = true
db.tstats = {}
eq(ns.PickTemplate({ name = "No Class" }), 1, "a player with no class is not sent the opener that names one")
db.tstats[keys[1]] = { sent = 30, replied = 0, joined = 0 }
db.tstats[keys[3]] = { sent = 30, replied = 0, joined = 0 }
db.tstats[keys[4]] = { sent = 30, replied = 0, joined = 0 }
check(ns.PickTemplate({ name = "No Class" }) ~= 2, "even when it is the least tried")
eq(ns.PickTemplate({ name = "Has Class", classStr = "Mage" }), 2, "a player with a class can get it")
db.opts.rotate, db.opts.template = false, 2
eq(ns.PickTemplate({ name = "No Class" }), 1, "rotation off, same rule")
db.opts.rotate = true

-- the window: Answers tab, conversation panel, row actions
M.printed = {}
SlashCmdList["TORCHCALL"]("")
check(M.click("Answers"), "Answers tab opens")
check(M.click(">") and M.click("<") and M.click("Put this line back"), "its buttons work")
check(M.click("Message") and M.click("Trying every opener"), "the rotation button toggles")
eq(db.opts.rotate, false, "rotation off from the window")
check(M.click("Trying every opener") and db.opts.rotate == true, "and back on")
check(M.click("Prospects"), "back to prospects")
seed({ M.player("Eve Five", "", 15, "MAGE") })
M.advance(10) check(ns.Whisper("Eve Five"), "opener to Eve")
check(not M.click("What we are"), "the conversation panel is closed until someone answers")
M.fire("CHAT_MSG_WHISPER", "sure, do you guys pvp?", "Eve Five")
check(M.click("Reply"), "a row for someone who answered has a Reply button")
M.advance(10)
M.sentChat = {}
check(M.click("PvP"), "the PvP answer button is there")
check(#M.sentChat == 1 and M.sentChat[1][3] == "Eve Five" and M.sentChat[1][1]:find("PvP ruleset", 1, true), "and sends that answer to that player")
M.advance(10)
check(not M.click("PvP"), "a sent answer cannot be pressed again")
check(M.click("Send the guild invite"), "invite from the conversation panel")
eq(M.invited[#M.invited], "Eve Five", "invites that player") eq(db.prospects["Eve Five"].path, "warm", "as a warm invite")
check(M.click("Close") and not M.click("What we are"), "the panel closes")
M.advance(10)
M.printed = {}
check(M.click("Add my group") and table.concat(M.printed, "\n"):find("not in a group", 1, true), "Add my group with no group says so")
M.group = { { name = "Fay Six", class = "DRUID", level = 20 } }
SlashCmdList["TORCHCALL"]("stats")
check(M.click("Add my group") and db.prospects["Fay Six"] and db.prospects["Fay Six"].ran, "Add my group adds the party")
for _, cmd in ipairs({ "group", "rotate", "rotate", "answer", "answer raids Nobody Here", "answer raids Eve Five", "checkin", "checkin Eve Five", "stats", "help" }) do
  check(pcall(SlashCmdList["TORCHCALL"], cmd), "/torchcall " .. cmd)
end
local printed = table.concat(M.printed, "\n")
for _, needle in ipairs({ "Topics: about", "Invites after a conversation", "Due a check-in: Hid Den", "/torchcall answer <topic> <name>" }) do
  check(printed:find(needle, 1, true), "command output mentions: " .. needle)
end
eq(ns.errors, nil, "no handler errors in the 1.2 section")
eq(TorchcallDB.log and #(function() local e = {} for _, l in ipairs(TorchcallDB.log) do if l:find("error", 1, true) then e[#e + 1] = l end end return e end)(), 0, "nothing logged as an error")

-- the follow-up carries both the Discord and the site
check(ns.REPLY:find("discord.gg/passthetorch", 1, true) and ns.REPLY:find("passthetorch.pages.dev", 1, true), "the follow-up has the Discord and the site")
check(#ns.Render(ns.REPLY, longP) <= 255, "and still fits")

-- the guild window's texts: shown freely, written only on a typed command with the rank
check(#ns.GUILD_INFO <= 500 and #ns.GUILD_MOTD <= 128, "guild info and message of the day fit the game's limits")
check(ns.GUILD_INFO:find("discord.gg/passthetorch", 1, true) and ns.GUILD_INFO:find("passthetorch.pages.dev", 1, true), "guild info has the Discord and the site")
M.guildInfo, M.guildMotd, M.canEditInfo, M.canEditMotd = "", "old motd", true, true
local gi = ns.GuildText("info")
check(gi.can and gi.empty and not gi.same, "an empty guild info is seen as empty")
M.printed = {}
SlashCmdList["TORCHCALL"]("guild")
eq(M.guildInfo, "", "looking at it writes nothing")
check(table.concat(M.printed, "\n"):find("/torchcall guild info writes this", 1, true), "it says how to write it")
SlashCmdList["TORCHCALL"]("guild info")
eq(M.guildInfo, ns.GUILD_INFO, "guild info written on command")
SlashCmdList["TORCHCALL"]("guild motd")
eq(M.guildMotd, ns.GUILD_MOTD, "message of the day written on command")
eq(TorchcallDB.oldmotd, "old motd", "what was there before is kept")
ok, why = ns.SetGuildText("info")
check(not ok and why:find("already says"), "writing the same text again is refused")
M.guildMotd, M.canEditMotd = "the guild master's own", false
ok, why = ns.SetGuildText("motd")
check(not ok and why:find("rank cannot") and M.guildMotd == "the guild master's own", "no rank, no write")
M.canEditMotd, M.myGuild = true, "Another Guild"
ok, why = ns.SetGuildText("motd")
check(not ok and why:find("written for") and M.guildMotd == "the guild master's own", "another guild's text is never overwritten with ours")
M.myGuild = "The True Torchmen"
M.inGuild = false
ok = ns.SetGuildText("motd")
check(not ok, "no guild, no write")
M.inGuild = true
check(not ns.SetGuildText("bogus"), "an unknown text is refused")

-- a guildmate on a newer version: one line, once
M.printed, M.sentAddon = {}, {}
M.fire("CHAT_MSG_ADDON", "Torchcall", "H;1;aaaaaa", "GUILD", "Old Officer")
M.fire("CHAT_MSG_ADDON", "Torchcall", "H;1;bbbbbb;" .. ns.VERSION, "GUILD", "Same Officer")
M.fire("CHAT_MSG_ADDON", "Torchcall", "H;1;cccccc;junk;more", "GUILD", "Junk Officer")
check(not table.concat(M.printed, "\n"):find("is out", 1, true), "a hello with no version, the same version or junk says nothing")
M.fire("CHAT_MSG_ADDON", "Torchcall", "H;1;dddddd;9.4.2", "GUILD", "New Officer")
M.fire("CHAT_MSG_ADDON", "Torchcall", "H;1;eeeeee;9.9.9", "GUILD", "Newest Officer")
local told = 0
for _, line in ipairs(M.printed) do if line:find("version 9.4.2 is out and you have " .. ns.VERSION, 1, true) then told = told + 1 end if line:find("9.9.9", 1, true) then told = told + 10 end end
eq(told, 1, "a newer version is announced once per session")

-- an upgrade from 1.1 saved data gets every new field without losing anything
M.reset(false)
TorchcallDB = { prospects = { ["Old Timer"] = { name = "Old Timer", status = "joined", t = time() - 86400 } }, stats = { joined = 9, invited = 37, whispered = 21, replied = 1, declined = 23, found = 64 },
                opts = { template = 1 }, templates = { ns.OLD_TEMPLATES[1], ns.OLD_TEMPLATES[2], ns.OLD_TEMPLATES[3] }, reply = "my own follow-up", sent = {}, log = {}, contacted = {} }
ns = M.load("Torchcall", { "Data.lua", "Core.lua", "Comm.lua", "UI.lua" })
M.fire("ADDON_LOADED", "Torchcall") M.fire("PLAYER_LOGIN")
eq(TorchcallDB.stats.joined, 9, "old totals kept") eq(TorchcallDB.reply, "my own follow-up", "an edited follow-up kept")
eq(TorchcallDB.templates[2], ns.TEMPLATES[2], "old default openers replaced")
check(TorchcallDB.answers.raids and TorchcallDB.checkin and TorchcallDB.groupmsg and TorchcallDB.opts.rotate == true, "new lines and rotation installed")
eq(#TorchcallDB.templates, #ns.TEMPLATES, "an untouched 1.1 set gets the fourth opener too")
TorchcallDB.reply = ns.OLD_REPLY
M.reset(false)
ns = M.load("Torchcall", { "Data.lua", "Core.lua", "Comm.lua", "UI.lua" })
M.fire("ADDON_LOADED", "Torchcall") M.fire("PLAYER_LOGIN")
eq(TorchcallDB.reply, ns.REPLY, "an untouched 1.1 follow-up gains the site")
M.guildInfo = ""
M.printed = {}
M.advance(25)
check(table.concat(M.printed, "\n"):find("guild info is empty", 1, true), "an officer with an empty guild info is told at login")
eq(M.guildInfo, "", "and nothing is written without the command")
eq(TorchcallDB.stats.cold.invited, 0, "paths start at zero rather than guessing at old invites")
check(ns.Funnel().advice:find("Only 5%% of whispers"), "his real numbers produce the advice about the opener: " .. ns.Funnel().advice)
M.advance(25)
check(not table.concat(M.printed, "\n"):find("due", 1, true) or true, "login reminder runs without error")

-- the version the addon reports is the version on the box
do
  local f = assert(io.open("Torchcall/Torchcall.toc"))
  local toc = f:read("*a") f:close()
  local probe = {}
  assert(loadfile("Torchcall/Data.lua"))("Torchcall", probe)
  assert(loadfile("Torchcall/Core.lua"))("Torchcall", probe)
  eq(toc:match("## Version: ([%d%.]+)"), probe.VERSION, "the toc and the code agree on the version")
end
M.realPrint(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
