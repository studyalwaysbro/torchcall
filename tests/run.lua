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
check(M.sentChat[1][1]:find("^Hey Bob, <The True Torchmen>"), "message rendered with first name and guild")
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

M.realPrint(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
