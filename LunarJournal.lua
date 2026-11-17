-- Lunar Journal
--
-- Keeps a journal of what a character does, so a story can be written from it later
-- (outside the game: see agent\ and skill\ in this repository).
--
-- What is written down, per play session:
--   * quests: offered (by whom, where, the quest text), accepted, turned in (to whom,
--     XP and money), abandoned
--   * people met: NPCs talked to (quest givers, vendors, trainers, flight masters,
--     innkeepers, bankers), players grouped with, traded with or duelled
--   * time spent running, riding, swimming, on flight paths, dead, in combat, idle,
--     and the distance covered; time spent fishing, crafting and gathering, and what
--     came of it (fish caught, items made, herbs and ore gathered)
--   * zones visited and time in each, level ups, deaths (and what killed you),
--     hearthstone trips, flights, kills (rare and elite ones named), rare loot,
--     money gained and spent, screenshots
--   * your own notes: /lj note <text>
-- Every entry has the real date and time and the in-game (server) time of day.
--
-- Nothing is sent anywhere. The game writes the journal to
-- WTF\Account\<account>\<realm>\<character>\SavedVariables\LunarJournal.lua when you
-- log out or /reload. Chat is never recorded.

local ADDON_NAME, ns = ...

local ICON = "Interface\\Icons\\INV_Misc_Book_09"
local MAX_EVENTS = 4000          -- per session; the summary counters go on after that
local MAX_SESSIONS = 300         -- oldest are dropped first
local RESUME_GAP = 15 * 60       -- a login this soon after the last logout continues that session
local TEXT_LIMIT = 900           -- quest texts are cut to this length

local DEFAULT_SETTINGS = {
    paused = false,
    questText = true,
    kills = true,
    echo = false,
}

local DB            -- per character: LunarJournalDB
local S             -- account-wide settings: LunarJournalSettings
local session       -- the session being written
local Refresh       -- the window, defined further down

----------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------
local function GameTime()
    local h, m = GetGameTime()
    return string.format("%02d:%02d", h or 0, m or 0)
end

local function Zone()
    local zone = GetRealZoneText and GetRealZoneText() or GetZoneText()
    local sub = GetSubZoneText and GetSubZoneText() or ""
    if sub == zone then sub = "" end
    return zone or "", sub
end

local function Cut(text)
    if type(text) ~= "string" or text == "" then return nil end
    text = text:gsub("\r", "")
    if #text > TEXT_LIMIT then text = text:sub(1, TEXT_LIMIT) .. "..." end
    return text
end

-- the NPC id from a creature GUID ("Creature-0-1-2-3-<id>-<spawn>")
local function NpcId(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, id)
        if ok and name then return name end
    end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

local function Add(map, key, n)
    if not key or key == "" then return end
    map[key] = (map[key] or 0) + (n or 1)
end

local function Duration(sec)
    sec = math.floor(sec or 0)
    if sec < 60 then return sec .. "s" end
    local h, m = math.floor(sec / 3600), math.floor(sec % 3600 / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return m .. "m"
end

local function Money(copper)
    copper = math.floor(copper or 0)
    local g, s, c = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c) end
    if s > 0 then return string.format("%ds %dc", s, c) end
    return c .. "c"
end

local function Say(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cffc8a2ffLunar Journal|r: " .. text)
end

----------------------------------------------------------------------------------------
-- Sessions and entries
----------------------------------------------------------------------------------------
local function CharacterInfo()
    local _, class = UnitClass("player")
    local race = UnitRace("player")
    local guild = GetGuildInfo and GetGuildInfo("player")
    return {
        name = UnitName("player"),
        realm = GetRealmName(),
        level = UnitLevel("player"),
        race = race,
        class = (UnitClass("player")),
        classFile = class,
        sex = UnitSex("player") == 3 and "female" or "male",
        faction = (UnitFactionGroup("player")),
        guild = guild,
    }
end

local function NewSession()
    local now = time()
    local zone, sub = Zone()
    return {
        id = now,
        start = now,
        stop = now,
        startGameTime = GameTime(),
        startZone = zone, startSubZone = sub,
        levelStart = UnitLevel("player"),
        level = UnitLevel("player"),
        moneyStart = GetMoney(),
        moneyGained = 0, moneySpent = 0,
        time = {},        -- seconds: running, riding, swimming, taxi, ghost, idle, combat, fishing, crafting, gathering, resting
        dist = {},        -- yards: running, riding, swimming, taxi, ghost
        zones = {},       -- zone -> seconds
        kills = {},       -- creature name -> count
        fish = {},        -- item -> count
        crafted = {},     -- recipe -> count
        gathered = {},    -- item -> count
        npcs = {},        -- NPC name -> times talked to
        players = {},     -- player name -> how we met
        events = {},
    }
end

local function Log(kind, fields)
    if not session or S.paused then return end
    local zone, sub = Zone()
    local e = fields or {}
    e.k = kind
    e.t = time()
    e.g = GameTime()
    e.z = zone
    if sub ~= "" then e.s = sub end
    if #session.events < MAX_EVENTS then
        session.events[#session.events + 1] = e
    else
        session.truncated = true
    end
    session.stop = e.t
    if S.echo then Say(kind .. (e.title and (": " .. e.title) or e.name and (": " .. e.name) or "")) end
    if Refresh then Refresh() end
    return e
end

local function StartSession()
    DB.sessions = DB.sessions or {}
    DB.quests = DB.quests or {}
    DB.character = CharacterInfo()
    local last = DB.sessions[#DB.sessions]
    if last and last.stop and time() - last.stop < RESUME_GAP then
        session = last          -- a /reload or a quick relog: same session
        session.resumes = (session.resumes or 0) + 1
    else
        session = NewSession()
        DB.sessions[#DB.sessions + 1] = session
        while #DB.sessions > MAX_SESSIONS do table.remove(DB.sessions, 1) end
        Log("login", { level = UnitLevel("player") })
    end
end

local function EndSession()
    if not session then return end
    session.stop = time()
    session.level = UnitLevel("player")
    session.moneyEnd = GetMoney()
    -- drop empty blink-sessions (logged in and straight out again)
    if session.stop - session.start < 30 and #session.events <= 1 and DB.sessions[#DB.sessions] == session then
        DB.sessions[#DB.sessions] = nil
    end
end

----------------------------------------------------------------------------------------
-- Movement and time: sampled once a second
----------------------------------------------------------------------------------------
local wasOnTaxi = false
local activity = { fishing = nil, crafting = nil, gathering = nil }  -- start times of what's going on

local function Tick()
    if not session or S.paused then return end
    local dt = 1
    local speed = GetUnitSpeed and GetUnitSpeed("player") or 0
    local mode
    local onTaxi = UnitOnTaxi("player")
    if onTaxi then mode = "taxi"
    elseif UnitIsDeadOrGhost("player") then mode = "ghost"
    elseif IsSwimming and IsSwimming() then mode = "swimming"
    elseif IsMounted() then mode = "riding"
    else mode = "running" end
    -- The game may hand out speed as a "secret" value (one addon code can't compare
    -- or do sums with). Then fall back to IsPlayerMoving for time and skip distance.
    local moving
    if issecretvalue and issecretvalue(speed) then
        local m = IsPlayerMoving and IsPlayerMoving()
        moving = not issecretvalue(m) and m == true
        speed = nil
    else
        moving = speed > 0
    end
    if moving then
        Add(session.time, mode, dt)
        if speed then Add(session.dist, mode, speed * dt) end
    else
        Add(session.time, "idle", dt)
    end
    if UnitAffectingCombat("player") then Add(session.time, "combat", dt) end
    if IsResting() then Add(session.time, "resting", dt) end
    local zone = Zone()
    Add(session.zones, zone, dt)
    session.stop = time()

    if onTaxi ~= wasOnTaxi then
        wasOnTaxi = onTaxi
        Log(onTaxi and "flight_start" or "flight_end")
    end
end

----------------------------------------------------------------------------------------
-- Quests
----------------------------------------------------------------------------------------
local offered = {}      -- quest title -> what the NPC said when offering it
local finishing         -- the turn-in dialog that is open

local function QuestTitle(id, index)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, id)
        if ok and title then return title end
    end
    if index and GetQuestLogTitle then
        local title = GetQuestLogTitle(index)
        if title then return title end
    end
    local q = DB.quests[id]
    return q and q.title
end

local function QuestLevel(index)
    if index and GetQuestLogTitle then
        local _, level = GetQuestLogTitle(index)
        return level
    end
end

local function OnQuestDetail()
    local title = GetTitleText()
    if not title then return end
    local npc = UnitName("npc")
    offered[title] = {
        npc = npc,
        npcId = NpcId(UnitGUID("npc")),
        text = S.questText and Cut(GetQuestText()) or nil,
        objective = S.questText and Cut(GetObjectiveText()) or nil,
    }
    Log("quest_offered", { title = title, npc = npc })
end

local function OnQuestAccepted(a1, a2)
    -- Classic clients give (questLogIndex, questID), newer ones only questID
    local index, id = a1, a2
    if not id then id, index = a1, nil end
    if type(id) ~= "number" then return end
    local title = QuestTitle(id, index)
    local o = title and offered[title] or {}
    local zone, sub = Zone()
    local q = DB.quests[id] or {}
    q.title = title or q.title
    q.level = QuestLevel(index) or q.level
    q.giver = o.npc or q.giver
    q.giverId = o.npcId or q.giverId
    q.zone = zone
    q.subZone = sub ~= "" and sub or nil
    q.text = o.text or q.text
    q.objective = o.objective or q.objective
    q.accepted = time()
    q.abandoned = nil
    DB.quests[id] = q
    if title then offered[title] = nil end
    Log("quest_accepted", { id = id, title = q.title, npc = q.giver, level = q.level })
end

local function OnQuestComplete()
    finishing = {
        title = GetTitleText(),
        npc = UnitName("npc"),
        npcId = NpcId(UnitGUID("npc")),
        text = S.questText and Cut(GetRewardText()) or nil,
    }
end

local function OnQuestTurnedIn(id, xp, money)
    local q = DB.quests[id] or {}
    local f = finishing or {}
    q.title = q.title or f.title or QuestTitle(id)
    q.done = time()
    q.turnedInTo = f.npc
    q.turnedInToId = f.npcId
    q.rewardText = f.text
    q.xp = xp
    q.money = money
    DB.quests[id] = q
    finishing = nil
    Log("quest_done", { id = id, title = q.title, npc = f.npc, xp = xp, money = money })
end

local function OnAbandon()
    local title = GetAbandonQuestName and GetAbandonQuestName()
    if not title then return end
    for id, q in pairs(DB.quests) do
        if q.title == title and not q.done then q.abandoned = time() end
    end
    Log("quest_abandoned", { title = title })
end

----------------------------------------------------------------------------------------
-- People
----------------------------------------------------------------------------------------
local function MetNpc(kind)
    local name = UnitName("npc")
    if not name or UnitIsPlayer("npc") or not session or S.paused then return end
    Add(session.npcs, name)
    Log("npc", { name = name, id = NpcId(UnitGUID("npc")), as = kind })
end

local partyNow = {}
local function OnGroupChanged()
    if not session then return end
    local seen = {}
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    local prefix = IsInRaid and IsInRaid() and "raid" or "party"
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local name = GetUnitName(unit, true)
            if name then
                seen[name] = true
                if not partyNow[name] then
                    local _, class = UnitClass(unit)
                    session.players[name] = session.players[name] or "grouped"
                    Log("group_join", { name = name, class = (UnitClass(unit)), race = UnitRace(unit), level = UnitLevel(unit) })
                end
            end
        end
    end
    for name in pairs(partyNow) do
        if not seen[name] then Log("group_leave", { name = name }) end
    end
    partyNow = seen
end

----------------------------------------------------------------------------------------
-- Fishing, crafting, gathering (spell names are read from the game, so they work in
-- any language)
----------------------------------------------------------------------------------------
local FISHING, GATHER = {}, {}
local function LoadSpellNames()
    for _, id in ipairs({ 7620, 7731, 7732, 18248 }) do
        local n = SpellName(id); if n then FISHING[n] = true end
    end
    for _, pair in ipairs({ { 2575, "mining" }, { 2366, "herbalism" }, { 8613, "skinning" } }) do
        local n = SpellName(pair[1]); if n then GATHER[n] = pair[2] end
    end
end

local tradeSkillOpen      -- name of the open profession window
local castStart, castName
local lootFrom            -- "fishing" or a gathering kind, for the next loot window
local lootFromUntil = 0

local function OnTradeSkillShow()
    local name
    if GetTradeSkillLine then name = GetTradeSkillLine() end
    tradeSkillOpen = name or "profession"
end

local function OnCraftShow()
    local name = GetCraftDisplaySkillLine and GetCraftDisplaySkillLine() or (GetCraftName and GetCraftName())
    tradeSkillOpen = name or "profession"
end

local function OnCastStart(unit, _, spellId)
    if unit ~= "player" then return end
    castStart, castName = GetTime(), SpellName(spellId)
end

local function OnCastSucceeded(unit, _, spellId)
    if unit ~= "player" or not session then return end
    local name = SpellName(spellId)
    if not name then return end
    if spellId == 8690 then
        Log("hearthstone", { to = GetBindLocation and GetBindLocation() })
    elseif GATHER[name] then
        Add(session.time, "gathering", castStart and castName == name and (GetTime() - castStart) or 2)
        Add(session, "gatherCasts")
        lootFrom, lootFromUntil = GATHER[name], GetTime() + 5
    elseif tradeSkillOpen and castStart and castName == name then
        Add(session.time, "crafting", GetTime() - castStart)
        Add(session.crafted, name)
        local last = session.events[#session.events]
        -- many crafts in a row become one entry with a count
        if last and last.k == "craft" and last.name == name then
            last.n = (last.n or 1) + 1
        else
            Log("craft", { name = name, skill = tradeSkillOpen, n = 1 })
        end
    end
    castStart, castName = nil, nil
end

local function OnChannelStart(unit, _, spellId)
    if unit ~= "player" then return end
    local name = SpellName(spellId)
    if name and FISHING[name] then activity.fishing = GetTime() end
end

local function OnChannelStop(unit)
    if unit ~= "player" or not activity.fishing or not session then return end
    Add(session.time, "fishing", GetTime() - activity.fishing)
    Add(session, "fishingCasts")
    activity.fishing = nil
    lootFrom, lootFromUntil = "fishing", GetTime() + 3
end

local function OnLootOpened()
    if not session then return end
    local from
    if IsFishingLoot and IsFishingLoot() then from = "fishing"
    elseif lootFrom and GetTime() < lootFromUntil then from = lootFrom end
    lootFrom = nil
    if not from then return end
    local got = {}
    for i = 1, GetNumLootItems() do
        local _, name, quantity = GetLootSlotInfo(i)
        if name and (quantity or 0) > 0 then
            Add(from == "fishing" and session.fish or session.gathered, name, quantity)
            got[#got + 1] = quantity > 1 and (quantity .. "x " .. name) or name
        end
    end
    if #got > 0 then
        local last = session.events[#session.events]
        local kind = from == "fishing" and "fish" or "gather"
        -- a fishing trip at one spot becomes one entry
        if last and last.k == kind and last.how == from and time() - last.t < 300 then
            for _, item in ipairs(got) do last.items[#last.items + 1] = item end
            last.t2 = time()
            last.g2 = GameTime()
        else
            Log(kind, { how = from, items = got })
        end
    end
end

----------------------------------------------------------------------------------------
-- Combat: kills, deaths and what killed you. The modern client doesn't let addons read
-- the combat log, so this watches the units the game shows: your target, focus, mouse-
-- over and nameplates. A unit counts as your kill when it dies while you were on its
-- threat list and it wasn't tapped by someone outside your group.
----------------------------------------------------------------------------------------
local playerGUID
local lastFoe            -- the last enemy that was attacking you
local CLASSIFICATION = { elite = "elite", rare = "rare", rareelite = "rare elite", worldboss = "boss" }
local engaged, engagedCount = {}, 0    -- GUID -> true while fighting it
local counted = {}                     -- GUIDs already counted as dead

local function Secret(v)
    return issecretvalue and issecretvalue(v)
end

local function WatchUnit(unit)
    if not session or not S.kills or not UnitExists(unit) or UnitIsUnit(unit, "player") then return end
    local guid = UnitGUID(unit)
    if not guid or Secret(guid) or UnitIsFriend("player", unit) then return end
    if UnitIsDead(unit) then
        if engaged[guid] and not counted[guid] and not (UnitIsTapDenied and UnitIsTapDenied(unit)) then
            counted[guid] = true
            local name = UnitName(unit)
            if Secret(name) then return end
            local isPlayer = UnitIsPlayer(unit)
            Add(session.kills, (isPlayer and "player: " or "") .. (name or "?"))
            local c = CLASSIFICATION[UnitClassification(unit)]
            if isPlayer then
                Log("kill", { name = name, player = true })
            elseif c then
                Log("kill", { name = name, rank = c, level = UnitLevel(unit) })
            end
        end
        return
    end
    local threat = UnitThreatSituation and UnitThreatSituation("player", unit)
    if threat then
        if not engaged[guid] then
            engaged[guid] = true
            engagedCount = engagedCount + 1
            if engagedCount > 400 then engaged, counted, engagedCount = {}, {}, 0 end
        end
        if threat >= 2 then
            local name = UnitName(unit)
            if not Secret(name) then lastFoe = name end
        end
    end
end

local function SafeWatch(unit)
    pcall(WatchUnit, unit)
end

local function WatchAll()
    SafeWatch("target"); SafeWatch("focus"); SafeWatch("mouseover")
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then SafeWatch(unit) end
    end
end

local function OnUnitChanged(unit)
    if type(unit) == "string" and (unit == "target" or unit == "focus" or unit == "mouseover" or unit:find("^nameplate")) then
        SafeWatch(unit)
    end
end

local function OnDead()
    Log("death", { by = lastFoe })
    lastFoe = nil
end

----------------------------------------------------------------------------------------
-- Loot and money
----------------------------------------------------------------------------------------
local QUALITY = { ["ff0070dd"] = "rare", ["ffa335ee"] = "epic", ["ffff8000"] = "legendary" }
local lootSelf

local function OnLootMessage(msg)
    if not session or Secret(msg) or type(msg) ~= "string" then return end
    -- only our own loot ("You receive loot: ..."), never other players'
    if not lootSelf then
        local a = LOOT_ITEM_SELF and LOOT_ITEM_SELF:gsub("%%s.*", "") or "You receive loot"
        local b = LOOT_ITEM_PUSHED_SELF and LOOT_ITEM_PUSHED_SELF:gsub("%%s.*", "") or "You receive item"
        lootSelf = { a, b }
    end
    if msg:sub(1, #lootSelf[1]) ~= lootSelf[1] and msg:sub(1, #lootSelf[2]) ~= lootSelf[2] then return end
    local color, name = msg:match("|c(%x%x%x%x%x%x%x%x)|Hitem:[^|]+|h%[(.-)%]|h|r")
    local quality = color and QUALITY[color:lower()]
    if quality then Log("loot", { name = name, quality = quality }) end
end

local lastMoney
local function OnMoney()
    if not session then return end
    local now = GetMoney()
    if lastMoney then
        local d = now - lastMoney
        if d > 0 then session.moneyGained = session.moneyGained + d
        elseif d < 0 then session.moneySpent = session.moneySpent - d end
    end
    lastMoney = now
end

----------------------------------------------------------------------------------------
-- Summary (window, tooltip)
----------------------------------------------------------------------------------------
local function Count(map)
    local n = 0
    for _, v in pairs(map or {}) do n = n + (type(v) == "number" and v or 1) end
    return n
end

local function Keys(map)
    local n = 0
    for _ in pairs(map or {}) do n = n + 1 end
    return n
end

local function SessionLines()
    local s = session
    if not s then return { "Not started yet." } end
    local t, d = s.time, s.dist
    local acc, done = 0, 0
    for _, e in ipairs(s.events) do
        if e.k == "quest_accepted" then acc = acc + 1 elseif e.k == "quest_done" then done = done + 1 end
    end
    local lines = {
        string.format("This session: |cffffffff%s|r (started %s, in-game %s)", Duration(s.stop - s.start), date("%H:%M", s.start), s.startGameTime),
        string.format("Quests: |cffffffff%d|r accepted, |cffffffff%d|r turned in", acc, done),
        string.format("People: |cffffffff%d|r NPCs talked to, |cffffffff%d|r players met", Keys(s.npcs), Keys(s.players)),
        string.format("Running |cffffffff%s|r (%d yd), riding |cffffffff%s|r, swimming |cffffffff%s|r, flying |cffffffff%s|r",
            Duration(t.running), (d.running or 0), Duration(t.riding), Duration(t.swimming), Duration(t.taxi)),
        string.format("Fishing |cffffffff%s|r (%d caught), crafting |cffffffff%s|r (%d made), gathering |cffffffff%s|r",
            Duration(t.fishing), Count(s.fish), Duration(t.crafting), Count(s.crafted), Duration(t.gathering)),
        string.format("In combat |cffffffff%s|r, %d kills; idle |cffffffff%s|r", Duration(t.combat), Count(s.kills), Duration(t.idle)),
        string.format("Money: +%s / -%s", Money(s.moneyGained), Money(s.moneySpent)),
    }
    if S.paused then table.insert(lines, 1, "|cffff8040Paused: nothing is being written down.|r") end
    return lines
end

local DESCRIBE = {
    login = function(e) return "Logged in (level " .. (e.level or "?") .. ")" end,
    quest_offered = function(e) return "Offered |cffffd100" .. (e.title or "?") .. "|r by " .. (e.npc or "?") end,
    quest_accepted = function(e) return "Accepted |cffffd100" .. (e.title or "?") .. "|r" end,
    quest_done = function(e) return "Turned in |cffffd100" .. (e.title or "?") .. "|r" .. (e.npc and (" to " .. e.npc) or "") end,
    quest_abandoned = function(e) return "Abandoned " .. (e.title or "?") end,
    npc = function(e) return "Talked to " .. (e.name or "?") .. " (" .. (e.as or "?") .. ")" end,
    group_join = function(e) return "Grouped with " .. (e.name or "?") end,
    group_leave = function(e) return (e.name or "?") .. " left the group" end,
    craft = function(e) return "Made " .. (e.n or 1) .. "x " .. (e.name or "?") end,
    fish = function(e) return "Caught " .. table.concat(e.items or {}, ", ") end,
    gather = function(e) return "Gathered " .. table.concat(e.items or {}, ", ") end,
    kill = function(e) return "Killed " .. (e.name or "?") .. (e.rank and (" (" .. e.rank .. ")") or "") end,
    death = function(e) return "|cffff4040Died|r" .. (e.by and (", killed by " .. e.by) or "") end,
    level = function(e) return "|cff40ff40Reached level " .. (e.level or "?") .. "|r" end,
    zone = function(e) return "Arrived in " .. (e.z or "?") end,
    flight_start = function(e) return "Took a flight from " .. (e.s or e.z or "?") end,
    flight_end = function(e) return "Landed in " .. (e.s or e.z or "?") end,
    hearthstone = function(e) return "Hearthstone to " .. (e.to or "?") end,
    loot = function(e) return "Looted " .. (e.name or "?") .. " (" .. (e.quality or "") .. ")" end,
    note = function(e) return "Note: " .. (e.text or "") end,
    screenshot = function() return "Took a screenshot" end,
    trade = function(e) return "Traded with " .. (e.name or "?") end,
    duel = function(e) return "Duel with " .. (e.name or "?") end,
}

local function Describe(e)
    local f = DESCRIBE[e.k]
    return f and f(e) or e.k
end

local function SummaryTooltip(tt)
    for _, line in ipairs(SessionLines()) do tt:AddLine(line, 1, 0.82, 0, true) end
    if DB and DB.sessions then tt:AddLine(#DB.sessions .. " sessions in the journal", 0.6, 0.6, 0.6) end
end

----------------------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------------------
local frame = CreateFrame("Frame", "LunarJournalFrame", UIParent, "BasicFrameTemplateWithInset")
frame:SetSize(470, 420)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetClampedToScreen(true)
frame:Hide()
tinsert(UISpecialFrames, "LunarJournalFrame")  -- Escape closes it
if frame.TitleText then frame.TitleText:SetText("Lunar Journal") end

local summaryText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
summaryText:SetPoint("TOPLEFT", 14, -32)
summaryText:SetWidth(440)
summaryText:SetJustifyH("LEFT")
summaryText:SetSpacing(3)

local recentHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
recentHeader:SetPoint("TOPLEFT", summaryText, "BOTTOMLEFT", 0, -12)
recentHeader:SetText("Latest entries")

local recentText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
recentText:SetPoint("TOPLEFT", recentHeader, "BOTTOMLEFT", 0, -6)
recentText:SetWidth(440)
recentText:SetJustifyH("LEFT")
recentText:SetJustifyV("TOP")
recentText:SetSpacing(2)

local noteHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
noteHint:SetPoint("BOTTOMLEFT", 14, 12)
noteHint:SetText("/lj note <text> adds your own line to the journal")

Refresh = function()
    if not frame:IsShown() then return end
    summaryText:SetText(table.concat(SessionLines(), "\n"))
    local lines = {}
    if session then
        for i = #session.events, math.max(1, #session.events - 13), -1 do
            local e = session.events[i]
            lines[#lines + 1] = "|cff999999" .. date("%H:%M", e.t) .. " (" .. (e.g or "") .. ")|r  " .. Describe(e)
        end
    end
    recentText:SetText(#lines > 0 and table.concat(lines, "\n") or "Nothing yet.")
end
frame:SetScript("OnShow", Refresh)

local function ToggleWindow()
    frame:SetShown(not frame:IsShown())
end

----------------------------------------------------------------------------------------
-- Minimap button and options page (LunarLink.lua)
----------------------------------------------------------------------------------------
local link = ns.NewLunarLink({
    name    = ADDON_NAME,
    title   = "Lunar Journal",
    icon    = ICON,
    angle   = 250,
    db      = function() return LunarJournalSettings end,
    open    = ToggleWindow,
    hint    = "Left-click: show or hide the journal",
    tooltip = SummaryTooltip,
    options = function(l)
        l:AddHeader("What to write down")
        l:AddCheckbox("Pause the journal (write nothing down)",
            function() return S.paused end, function(on) S.paused = on end)
        l:AddCheckbox("Save the quest texts (what the quest giver said)",
            function() return S.questText end, function(on) S.questText = on end)
        l:AddCheckbox("Count kills",
            function() return S.kills end, function(on) S.kills = on end)
        l:AddCheckbox("Print a chat line for every entry",
            function() return S.echo end, function(on) S.echo = on end)
        l:AddText(function()
            local n = DB and DB.sessions and #DB.sessions or 0
            local q = 0
            for _ in pairs(DB and DB.quests or {}) do q = q + 1 end
            return string.format("This character's journal: %d sessions, %d quests. It is saved when you log out or /reload.", n, q)
        end, "GameFontHighlightSmall")
        l:AddButton("Show the journal", 150, function() frame:Show() end)
    end,
    help = {
        "/lj - show or hide the journal",
        "/lj note <text> - write your own line in the journal",
        "/lj pause - pause or resume the journal",
        "/lj options - this page",
        "/lj forget yes - delete this character's whole journal",
    },
})

----------------------------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------------------------
SLASH_LUNARJOURNAL1 = "/lj"
SLASH_LUNARJOURNAL2 = "/journal"
SlashCmdList.LUNARJOURNAL = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ToggleWindow()
    elseif cmd == "note" then
        if rest == "" then Say("write something after /lj note") return end
        if S.paused then Say("the journal is paused (/lj pause)") return end
        Log("note", { text = rest })
        Say("noted.")
    elseif cmd == "pause" then
        S.paused = not S.paused
        Say(S.paused and "paused. Nothing is written down until /lj pause again." or "writing again.")
        if Refresh then Refresh() end
    elseif cmd == "options" or cmd == "config" then
        link:OpenOptions()
    elseif cmd == "forget" then
        if rest ~= "yes" then Say("this deletes all of this character's journal. Type /lj forget yes to do it.") return end
        DB.sessions, DB.quests = {}, {}
        session = nil
        StartSession()
        Say("journal cleared.")
    else
        Say("/lj, /lj note <text>, /lj pause, /lj options, /lj forget yes")
    end
end

----------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------
local events = CreateFrame("Frame")
local handlers = {}

local function On(event, func)
    handlers[event] = func
    pcall(events.RegisterEvent, events, event)  -- some events don't exist in every client
end

events:SetScript("OnEvent", function(_, event, ...)
    local f = handlers[event]
    if not f then return end
    local ok, err = pcall(f, ...)
    if not ok then geterrorhandler()(err) end
end)

On("ADDON_LOADED", function(name)
    if name ~= ADDON_NAME then return end
    LunarJournalSettings = LunarJournalSettings or {}
    S = LunarJournalSettings
    for k, v in pairs(DEFAULT_SETTINGS) do if S[k] == nil then S[k] = v end end
    LunarJournalDB = LunarJournalDB or {}
    DB = LunarJournalDB
    DB.version = 1
    events:UnregisterEvent("ADDON_LOADED")
end)

On("PLAYER_LOGIN", function()
    playerGUID = UnitGUID("player")
    LoadSpellNames()
    lastMoney = GetMoney()
    StartSession()
    C_Timer.NewTicker(1, function()
        local ok, err = pcall(Tick)
        if not ok then geterrorhandler()(err) end
        if session and not S.paused then WatchAll() end
    end)
    C_Timer.NewTicker(2, function() if frame:IsShown() then Refresh() end end)
end)

On("PLAYER_ENTERING_WORLD", function()
    link:Init()
    OnGroupChanged()
end)

On("PLAYER_LOGOUT", EndSession)

On("ZONE_CHANGED_NEW_AREA", function()
    local zone = Zone()
    local last = session and session.lastZone
    if session and zone ~= "" and zone ~= last then
        session.lastZone = zone
        Log("zone")
    end
end)

On("PLAYER_LEVEL_UP", function(level)
    if session then session.level = level end
    Log("level", { level = level })
    if DB.character then DB.character.level = level end
end)

On("QUEST_DETAIL", OnQuestDetail)
On("QUEST_ACCEPTED", OnQuestAccepted)
On("QUEST_COMPLETE", OnQuestComplete)
On("QUEST_TURNED_IN", OnQuestTurnedIn)
if AbandonQuest then hooksecurefunc("AbandonQuest", function() pcall(OnAbandon) end) end

On("GOSSIP_SHOW", function() MetNpc("talk") end)
On("QUEST_GREETING", function() MetNpc("quest giver") end)
On("MERCHANT_SHOW", function() MetNpc("vendor") end)
On("TRAINER_SHOW", function() MetNpc("trainer") end)
On("TAXIMAP_OPENED", function() MetNpc("flight master") end)
On("BANKFRAME_OPENED", function() MetNpc("banker") end)
On("PET_STABLE_SHOW", function() MetNpc("stable master") end)
On("AUCTION_HOUSE_SHOW", function() MetNpc("auctioneer") end)
On("CONFIRM_BINDER", function() MetNpc("innkeeper") end)

On("GROUP_ROSTER_UPDATE", OnGroupChanged)
On("TRADE_SHOW", function()
    local name = UnitName("NPC")
    if name and session then
        session.players[name] = session.players[name] or "traded"
        Log("trade", { name = name })
    end
end)
On("DUEL_REQUESTED", function(name)
    if name and session then
        session.players[name] = session.players[name] or "duel"
        Log("duel", { name = name })
    end
end)

On("TRADE_SKILL_SHOW", OnTradeSkillShow)
On("TRADE_SKILL_CLOSE", function() tradeSkillOpen = nil end)
On("CRAFT_SHOW", OnCraftShow)
On("CRAFT_CLOSE", function() tradeSkillOpen = nil end)
On("UNIT_SPELLCAST_START", OnCastStart)
On("UNIT_SPELLCAST_SUCCEEDED", OnCastSucceeded)
On("UNIT_SPELLCAST_CHANNEL_START", OnChannelStart)
On("UNIT_SPELLCAST_CHANNEL_STOP", OnChannelStop)
On("LOOT_OPENED", OnLootOpened)

-- (no COMBAT_LOG_EVENT_UNFILTERED: registering it is a protected action in the modern client)
On("PLAYER_TARGET_CHANGED", function() SafeWatch("target") end)
On("UNIT_HEALTH", OnUnitChanged)
On("UNIT_FLAGS", OnUnitChanged)
On("UNIT_THREAT_LIST_UPDATE", OnUnitChanged)
On("NAME_PLATE_UNIT_REMOVED", OnUnitChanged)
On("PLAYER_DEAD", OnDead)
On("PLAYER_UNGHOST", function() Log("revived") end)

On("CHAT_MSG_LOOT", OnLootMessage)
On("PLAYER_MONEY", OnMoney)
On("SCREENSHOT_SUCCEEDED", function() Log("screenshot") end)
