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
--   * groups: when a party or raid formed and broke up, who was in it (and when each
--     joined and left), who led it, and which quests were accepted and turned in
--     together (and which members had the same quest)
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

local ICON = "Interface\\AddOns\\LunarJournal\\Media\\Icon"   -- made by tools\make-icon.ps1
local MAX_EVENTS = 4000          -- per session; the summary counters go on after that
local MAX_SESSIONS = 300         -- oldest are dropped first
local RESUME_GAP = 15 * 60       -- a login this soon after the last logout continues that session
local TEXT_LIMIT = 900           -- quest texts are cut to this length

local DEFAULT_SETTINGS = {
    paused = false,
    echo = false,
}

-- What can be switched off in the settings window (/lj settings). Stored in
-- LunarJournalSettings.record (account-wide); missing = on.
local RECORD = {
    { key = "quests",      label = "Quests: offered, accepted, turned in" },
    { key = "questText",   label = "Quest texts (what the quest giver said)" },
    { key = "npcs",        label = "NPCs you talk to" },
    { key = "groups",      label = "Groups: who you played with" },
    { key = "players",     label = "Trades and duels" },
    { key = "travel",      label = "Running, riding, flights, distance, idle time" },
    { key = "zones",       label = "Zones and the time in each" },
    { key = "professions", label = "Fishing, crafting and gathering" },
    { key = "kills",       label = "Kills" },
    { key = "deaths",      label = "Deaths" },
    { key = "levels",      label = "Level ups" },
    { key = "loot",        label = "Rare loot" },
    { key = "money",       label = "Money gained and spent" },
    { key = "screenshots", label = "Screenshots" },
}

-- which setting each kind of entry belongs to (notes and logins are always written)
local KIND = {
    quest_offered = "quests", quest_accepted = "quests", quest_done = "quests", quest_abandoned = "quests",
    npc = "npcs",
    party_formed = "groups", party_end = "groups", party_raid = "groups", party_leader = "groups",
    group_join = "groups", group_leave = "groups",
    trade = "players", duel = "players",
    flight_start = "travel", flight_end = "travel", hearthstone = "travel",
    zone = "zones",
    craft = "professions", fish = "professions", gather = "professions",
    kill = "kills", death = "deaths", revived = "deaths", level = "levels",
    loot = "loot", screenshot = "screenshots",
}

local INSTRUCTIONS_LIMIT = 4000  -- letters in the story instructions

local DB            -- per character: LunarJournalDB
local S             -- account-wide settings: LunarJournalSettings
local session       -- the session being written
local Refresh       -- the window, defined further down

----------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------
-- The modern client may hand addons "secret" values (names, GUIDs, quest texts) that
-- code can't read, compare, join or use as table keys. Plain() turns those into nil,
-- so they're simply not written down. It must stay above every function that uses it.
local function Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function GameTime()
    local h, m = GetGameTime()
    return string.format("%02d:%02d", h or 0, m or 0)
end

local function Zone()
    local zone = Plain(GetRealZoneText and GetRealZoneText() or GetZoneText())
    local sub = Plain(GetSubZoneText and GetSubZoneText()) or ""
    if sub == zone then sub = "" end
    return zone or "", sub
end

local function Cut(text)
    text = Plain(text)
    if type(text) ~= "string" or text == "" then return nil end
    text = text:gsub("\r", "")
    if #text > TEXT_LIMIT then text = text:sub(1, TEXT_LIMIT) .. "..." end
    return text
end

-- the NPC id from a creature GUID ("Creature-0-1-2-3-<id>-<spawn>")
local function NpcId(guid)
    guid = Plain(guid)
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

-- is this kind of thing being written down? (see RECORD)
local function Rec(key)
    return not S.paused and not (S.record and S.record[key] == false)
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
        parties = {},     -- groups: start, stop, members, leader, questsAccepted, questsDone
        events = {},
    }
end

local function Log(kind, fields)
    if not session or S.paused then return end
    if KIND[kind] and not Rec(KIND[kind]) then return end
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
    local open = session.partyOpen and session.parties and session.parties[session.partyOpen]
    if open then open.stop = session.stop end
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
    if Rec("travel") then
        if moving then
            Add(session.time, mode, dt)
            if speed then Add(session.dist, mode, speed * dt) end
        else
            Add(session.time, "idle", dt)
        end
        if UnitAffectingCombat("player") then Add(session.time, "combat", dt) end
        if IsResting() then Add(session.time, "resting", dt) end
    end
    if Rec("zones") then Add(session.zones, (Zone()), dt) end
    session.stop = time()

    if onTaxi ~= wasOnTaxi then
        wasOnTaxi = onTaxi
        Log(onTaxi and "flight_start" or "flight_end")
    end
end

----------------------------------------------------------------------------------------
-- Groups: every party (or raid) is written down in session.parties, from the moment it
-- forms until it breaks up: who was in it and when they joined and left, who led it,
-- and the quests accepted and turned in while it lasted.
----------------------------------------------------------------------------------------
local partyNow = {}     -- name -> true for everyone in the group right now (not you)
local party             -- the group you are in: an entry in session.parties

-- calls fn(unit, name) for everyone else in the group
local function ForGroup(fn)
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    local prefix = IsInRaid and IsInRaid() and "raid" or "party"
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local name = Plain(GetUnitName(unit, true))
            if name then fn(unit, name) end
        end
    end
end

local function Sorted(map)
    local list = {}
    for k in pairs(map or {}) do list[#list + 1] = k end
    table.sort(list)
    return list
end

local function IsLeader(unit)
    if not UnitIsGroupLeader then return false end
    local ok, yes = pcall(UnitIsGroupLeader, unit)
    return ok and Plain(yes) == true
end

local function InGroup()
    if IsInGroup then return IsInGroup() end
    return (GetNumGroupMembers and GetNumGroupMembers() or 0) > 0
end

local function CloseParty()
    if not party then return end
    party.stop = time()
    Log("party_end", {
        members = Sorted(party.members),
        minutes = math.floor((party.stop - party.start) / 60),
        questsDone = #party.questsDone,
    })
    party = nil
    session.partyOpen = nil
end

local function OnGroupChanged()
    if not session or not Rec("groups") then return end
    session.parties = session.parties or {}
    -- after a /reload the open party is still in the session: carry on with it
    if not party and session.partyOpen then
        party = session.parties[session.partyOpen]
        partyNow = {}
        for name, m in pairs(party and party.members or {}) do
            if not m.left then partyNow[name] = true end
        end
    end
    if not InGroup() then
        CloseParty()
        partyNow = {}
        return
    end
    local seen, units = {}, {}
    ForGroup(function(unit, name) seen[name] = true; units[name] = unit end)
    if not next(seen) then return end   -- in a group, but the game hasn't listed it yet

    local raid = IsInRaid and IsInRaid() or false
    local function Member(name)
        local unit = units[name]
        session.players[name] = session.players[name] or "grouped"
        return {
            class = Plain((UnitClass(unit))),
            race = Plain(UnitRace(unit)),
            level = Plain(UnitLevel(unit)),
            joined = time(),
        }
    end
    local leader = IsLeader("player") and "you" or nil
    if not leader then
        for name, unit in pairs(units) do if IsLeader(unit) then leader = name end end
    end

    if not party then
        local zone, sub = Zone()
        party = {
            start = time(), stop = time(),
            raid = raid or nil,
            leader = leader,
            zone = zone, subZone = sub ~= "" and sub or nil,
            atLogin = (time() - session.start < 20) or nil,   -- already grouped when you logged in
            members = {},
            questsAccepted = {},
            questsDone = {},
        }
        for name in pairs(seen) do party.members[name] = Member(name) end
        session.parties[#session.parties + 1] = party
        session.partyOpen = #session.parties
        Log("party_formed", { members = Sorted(seen), leader = leader, raid = raid or nil, atLogin = party.atLogin })
    else
        for name in pairs(seen) do
            if not partyNow[name] then
                local m = party.members[name]
                if m then
                    m.left = nil          -- came back
                else
                    m = Member(name)
                    party.members[name] = m
                end
                Log("group_join", { name = name, class = m.class, race = m.race, level = m.level })
            end
        end
        for name in pairs(partyNow) do
            if not seen[name] then
                if party.members[name] then party.members[name].left = time() end
                Log("group_leave", { name = name })
            end
        end
        if raid and not party.raid then
            party.raid = true
            Log("party_raid")
        end
        if leader and leader ~= party.leader then
            party.leader = leader
            Log("party_leader", { name = leader })
        end
    end
    partyNow = seen
    party.stop = time()
end

-- who you're grouped with now, and which of them also have this quest
local function QuestCompany(id)
    if not party or not next(partyNow) then return nil end
    local with = Sorted(partyNow)
    local also
    if type(id) == "number" and C_QuestLog and C_QuestLog.IsUnitOnQuest then
        ForGroup(function(unit, name)
            local ok, yes = pcall(C_QuestLog.IsUnitOnQuest, unit, id)
            if ok and Plain(yes) == true then
                also = also or {}
                also[#also + 1] = name
            end
        end)
        if also then table.sort(also) end
    end
    return with, also
end

----------------------------------------------------------------------------------------
-- Quests
----------------------------------------------------------------------------------------
local offered = {}      -- quest title -> what the NPC said when offering it
local finishing         -- the turn-in dialog that is open

local function QuestTitle(id, index)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, id)
        if ok and Plain(title) then return title end
    end
    if index and GetQuestLogTitle then
        local title = Plain((GetQuestLogTitle(index)))
        if title then return title end
    end
    local q = DB.quests[id]
    return q and q.title
end

local function QuestLevel(index)
    if index and GetQuestLogTitle then
        local _, level = GetQuestLogTitle(index)
        return Plain(level)
    end
end

local function OnQuestDetail()
    if not Rec("quests") then return end
    local title = Plain(GetTitleText())
    if not title then return end
    local npc = Plain(UnitName("npc"))
    offered[title] = {
        npc = npc,
        npcId = NpcId(UnitGUID("npc")),
        text = Rec("questText") and Cut(GetQuestText()) or nil,
        objective = Rec("questText") and Cut(GetObjectiveText()) or nil,
    }
    Log("quest_offered", { title = title, npc = npc })
end

local function OnQuestAccepted(a1, a2)
    -- Classic clients give (questLogIndex, questID), newer ones only questID
    local index, id = a1, a2
    if not id then id, index = a1, nil end
    if type(id) ~= "number" or not Rec("quests") then return end
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
    local with, also = QuestCompany(id)
    q.acceptedWith = with
    q.acceptedAlsoOn = also
    DB.quests[id] = q
    if title then offered[title] = nil end
    if with and q.title then table.insert(party.questsAccepted, q.title) end
    Log("quest_accepted", { id = id, title = q.title, npc = q.giver, level = q.level, with = with, alsoOn = also })
end

local function OnQuestComplete()
    if not Rec("quests") then return end
    local id = GetQuestID and Plain(GetQuestID())
    local with, also = QuestCompany(id)
    finishing = {
        id = id,
        title = Plain(GetTitleText()),
        npc = Plain(UnitName("npc")),
        npcId = NpcId(UnitGUID("npc")),
        text = Rec("questText") and Cut(GetRewardText()) or nil,
        with = with,
        alsoOn = also,   -- read now: once turned in, the quest is gone from the log
    }
end

local function OnQuestTurnedIn(id, xp, money)
    if not Rec("quests") then finishing = nil return end
    local q = DB.quests[id] or {}
    local f = finishing or {}
    if f.id and f.id ~= id then f = {} end
    q.title = q.title or f.title or QuestTitle(id)
    q.done = time()
    q.turnedInTo = f.npc
    q.turnedInToId = f.npcId
    q.rewardText = f.text
    q.xp = xp
    q.money = money
    local with, also = f.with, f.alsoOn
    if not f.title then with, also = QuestCompany(id) end
    q.doneWith = with
    q.doneAlsoOn = also
    DB.quests[id] = q
    finishing = nil
    if with and party and q.title then table.insert(party.questsDone, q.title) end
    Log("quest_done", { id = id, title = q.title, npc = f.npc, xp = xp, money = money, with = with, alsoOn = also })
end

local function OnAbandon()
    local title = GetAbandonQuestName and Plain(GetAbandonQuestName())
    if not title or not Rec("quests") then return end
    for id, q in pairs(DB.quests) do
        if q.title == title and not q.done then q.abandoned = time() end
    end
    Log("quest_abandoned", { title = title })
end

----------------------------------------------------------------------------------------
-- People
----------------------------------------------------------------------------------------
local function MetNpc(kind)
    local name = Plain(UnitName("npc"))
    if not name or UnitIsPlayer("npc") or not session or not Rec("npcs") then return end
    Add(session.npcs, name)
    Log("npc", { name = name, id = NpcId(UnitGUID("npc")), as = kind })
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
local lootFrom            -- a gathering kind, for the next loot window
local lootFromUntil = 0
local fishStoppedAt = 0   -- GetTime() when the last fishing channel ended
local fishLootedAt = -10  -- GetTime() when the last catch was looted
local lootHandled         -- this loot window is already written down

local function NotSecret(v)
    return not (issecretvalue and issecretvalue(v))
end

local function OnTradeSkillShow()
    local name
    if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
        local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
        if ok and type(info) == "table" then name = info.professionName end
    end
    if not name and GetTradeSkillLine then name = GetTradeSkillLine() end
    tradeSkillOpen = name or "profession"
end

-- In the modern client a recipe's ID is the spell ID of making it
local function IsRecipe(spellId)
    if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo) then return false end
    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, spellId)
    return ok and type(info) == "table"
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
    elseif not Rec("professions") then
        -- not written down
    elseif GATHER[name] then
        Add(session.time, "gathering", castStart and castName == name and (GetTime() - castStart) or 2)
        Add(session, "gatherCasts")
        lootFrom, lootFromUntil = GATHER[name], GetTime() + 5
    elseif IsRecipe(spellId) or (tradeSkillOpen and castStart and castName == name) then
        -- a craft: known as a recipe, or cast from an open profession window
        local took = castStart and castName == name and (GetTime() - castStart) or 0
        Add(session.time, "crafting", took)
        Add(session.crafted, name)
        local last = session.events[#session.events]
        -- many crafts in a row become one entry with a count
        if last and last.k == "craft" and last.name == name then
            last.n = (last.n or 1) + 1
            last.t2 = time()
        else
            Log("craft", { name = name, skill = tradeSkillOpen or "profession", n = 1 })
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
    if Rec("professions") then
        Add(session.time, "fishing", GetTime() - activity.fishing)
        Add(session, "fishingCasts")
    end
    activity.fishing = nil
    -- if the catch was already looted, there's nothing more to wait for
    fishStoppedAt = (GetTime() - fishLootedAt < 2) and 0 or GetTime()
end

-- The catch: in the modern client the loot window opens while the fishing channel is
-- still running (the channel only stops afterwards), so "still fishing" counts too.
local function IsFishing()
    if IsFishingLoot then
        local ok, yes = pcall(IsFishingLoot)
        if ok and NotSecret(yes) and yes then return true end
    end
    return activity.fishing ~= nil or GetTime() - fishStoppedAt < 3
end

-- LOOT_READY and LOOT_OPENED both come for one loot window; write it down once
local function OnLootOpened()
    if not session or lootHandled or not Rec("professions") then return end
    local from
    if IsFishing() then from = "fishing"
    elseif lootFrom and GetTime() < lootFromUntil then from = lootFrom end
    if not from then return end
    lootHandled = true
    lootFrom = nil
    if from == "fishing" then fishLootedAt, fishStoppedAt = GetTime(), 0 end
    local got = {}
    for i = 1, GetNumLootItems() do
        local _, name, quantity = GetLootSlotInfo(i)
        if NotSecret(name) and NotSecret(quantity) and name and (quantity or 0) > 0 then
            Add(from == "fishing" and session.fish or session.gathered, name, quantity)
            got[#got + 1] = quantity > 1 and (quantity .. "x " .. name) or name
        end
    end
    if #got > 0 then
        local last = session.events[#session.events]
        local kind = from == "fishing" and "fish" or "gather"
        -- a fishing trip at one spot becomes one entry
        if last and last.k == kind and last.how == from and time() - (last.t2 or last.t) < 300 then
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
    if not session or not Rec("kills") or not UnitExists(unit) or UnitIsUnit(unit, "player") then return end
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
    if lastMoney and Rec("money") then
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
        (function()
            local groups, together = #(s.parties or {}), 0
            for _, p in ipairs(s.parties or {}) do together = together + #(p.questsDone or {}) end
            return string.format("Groups: |cffffffff%d|r, |cffffffff%d|r quests turned in together", groups, together)
        end)(),
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
    quest_accepted = function(e) return "Accepted |cffffd100" .. (e.title or "?") .. "|r" .. (e.with and (" with " .. table.concat(e.with, ", ")) or "") end,
    quest_done = function(e) return "Turned in |cffffd100" .. (e.title or "?") .. "|r" .. (e.npc and (" to " .. e.npc) or "") .. (e.with and (" with " .. table.concat(e.with, ", ")) or "") end,
    party_formed = function(e)
        local who = table.concat(e.members or {}, ", ")
        if e.atLogin then return "In a " .. (e.raid and "raid" or "group") .. " with " .. who end
        return (e.raid and "Raid" or "Group") .. " formed with " .. who .. (e.leader and e.leader ~= "you" and (", led by " .. e.leader) or "")
    end,
    party_end = function(e) return "Group broke up after " .. Duration((e.minutes or 0) * 60) .. ", " .. (e.questsDone or 0) .. " quests done together" end,
    party_raid = function() return "The group became a raid" end,
    party_leader = function(e) return (e.name == "you" and "You" or (e.name or "?")) .. " now lead" .. (e.name == "you" and "" or "s") .. " the group" end,
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
        for i = #session.events, math.max(1, #session.events - 12), -1 do
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
-- Settings window (/lj settings): what to write down, and the story instructions.
-- The instructions are this character's own (LunarJournalDB.storyInstructions), kept
-- apart from the journal entries, so StoryMaker and the story skill read them as how
-- the story should be told, not as something that happened.
----------------------------------------------------------------------------------------
local settingsFrame = CreateFrame("Frame", "LunarJournalSettingsFrame", UIParent, "BasicFrameTemplateWithInset")
settingsFrame:SetSize(560, 560)
settingsFrame:SetPoint("CENTER")
settingsFrame:SetMovable(true)
settingsFrame:EnableMouse(true)
settingsFrame:RegisterForDrag("LeftButton")
settingsFrame:SetScript("OnDragStart", settingsFrame.StartMoving)
settingsFrame:SetScript("OnDragStop", settingsFrame.StopMovingOrSizing)
settingsFrame:SetClampedToScreen(true)
settingsFrame:SetFrameStrata("DIALOG")
settingsFrame:Hide()
tinsert(UISpecialFrames, "LunarJournalSettingsFrame")
if settingsFrame.TitleText then settingsFrame.TitleText:SetText("Lunar Journal: settings") end

local recordHeader = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
recordHeader:SetPoint("TOPLEFT", 16, -32)
recordHeader:SetText("What to write down")

local recordNote = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
recordNote:SetPoint("TOPLEFT", recordHeader, "BOTTOMLEFT", 0, -4)
recordNote:SetText("For all your characters. Your own /lj notes are always written down.")

local checks = {}
for i, item in ipairs(RECORD) do
    local cb = CreateFrame("CheckButton", nil, settingsFrame, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    cb:SetPoint("TOPLEFT", 14 + col * 268, -72 - row * 24)
    local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    label:SetWidth(236)
    label:SetJustifyH("LEFT")
    label:SetText(item.label)
    cb:SetScript("OnClick", function(self)
        S.record = S.record or {}
        S.record[item.key] = self:GetChecked() and true or false
    end)
    checks[item.key] = cb
end

local rows = math.ceil(#RECORD / 2)
local storyHeader = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
storyHeader:SetPoint("TOPLEFT", 16, -72 - rows * 24 - 14)
storyHeader:SetText("How the story should be told")

local storyNote = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
storyNote:SetPoint("TOPLEFT", storyHeader, "BOTTOMLEFT", 0, -4)
storyNote:SetWidth(528)
storyNote:SetJustifyH("LEFT")
storyNote:SetText("Instructions for this character's story, e.g. the voice, the tone, what to dwell on or leave out. StoryMaker gives them to the AI as instructions, not as part of the journal.")

local storyBox = CreateFrame("Frame", nil, settingsFrame, "BackdropTemplate")
storyBox:SetPoint("TOPLEFT", storyNote, "BOTTOMLEFT", -4, -8)
storyBox:SetPoint("BOTTOMRIGHT", -14, 44)
if storyBox.SetBackdrop then
    storyBox:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    storyBox:SetBackdropColor(0, 0, 0, 0.5)
end

local storyScroll = CreateFrame("ScrollFrame", "LunarJournalStoryScroll", storyBox, "UIPanelScrollFrameTemplate")
storyScroll:SetPoint("TOPLEFT", 8, -8)
storyScroll:SetPoint("BOTTOMRIGHT", -28, 8)

local storyEdit = CreateFrame("EditBox", nil, storyScroll)
storyEdit:SetMultiLine(true)
storyEdit:SetAutoFocus(false)
storyEdit:SetFontObject(ChatFontNormal)
storyEdit:SetWidth(480)
storyEdit:SetHeight(200)
storyEdit:SetMaxLetters(INSTRUCTIONS_LIMIT)
storyEdit:SetScript("OnEscapePressed", storyEdit.ClearFocus)
storyEdit:SetScript("OnTextChanged", function(self, userInput)
    if userInput and DB then
        local text = self:GetText():gsub("^%s+", ""):gsub("%s+$", "")
        DB.storyInstructions = text ~= "" and text or nil
    end
end)
storyScroll:SetScrollChild(storyEdit)
-- a click anywhere in the box puts the cursor in the text
storyBox:EnableMouse(true)
storyBox:SetScript("OnMouseDown", function() storyEdit:SetFocus() end)

local storyCount = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
storyCount:SetPoint("BOTTOMLEFT", 16, 18)
storyCount:SetText("Saved as you type (the game writes it to disk at logout or /reload).")

local closeButton = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
closeButton:SetSize(90, 22)
closeButton:SetPoint("BOTTOMRIGHT", -14, 12)
closeButton:SetText(CLOSE or "Close")
closeButton:SetScript("OnClick", function() settingsFrame:Hide() end)

settingsFrame:SetScript("OnShow", function()
    for key, cb in pairs(checks) do cb:SetChecked(not (S.record and S.record[key] == false)) end
    storyEdit:SetText(DB and DB.storyInstructions or "")
    storyEdit:SetCursorPosition(0)
end)
settingsFrame:SetScript("OnHide", function() storyEdit:ClearFocus() end)

local function ShowSettings()
    settingsFrame:Show()
end

local settingsButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
settingsButton:SetSize(90, 22)
settingsButton:SetPoint("BOTTOMRIGHT", -12, 8)
settingsButton:SetText("Settings")
settingsButton:SetScript("OnClick", ShowSettings)

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
        l:AddButton("What to write down, story instructions...", 280, ShowSettings)
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
        "/lj settings - what to write down, and how the story should be told",
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
    elseif cmd == "settings" or cmd == "record" or cmd == "story" then
        ShowSettings()
    elseif cmd == "options" or cmd == "config" then
        link:OpenOptions()
    elseif cmd == "forget" then
        if rest ~= "yes" then Say("this deletes all of this character's journal. Type /lj forget yes to do it.") return end
        DB.sessions, DB.quests = {}, {}
        session, party, partyNow = nil, nil, {}
        StartSession()
        Say("journal cleared.")
    else
        Say("/lj, /lj note <text>, /lj pause, /lj settings, /lj options, /lj forget yes")
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
    -- 0.1.x kept two of the record settings on their own
    S.record = S.record or {}
    for _, key in ipairs({ "questText", "kills" }) do
        if S[key] ~= nil then
            if S.record[key] == nil then S.record[key] = S[key] and true or false end
            S[key] = nil
        end
    end
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
    local name = Plain(UnitName("NPC"))
    if name and session and Rec("players") then
        session.players[name] = session.players[name] or "traded"
        Log("trade", { name = name })
    end
end)
On("DUEL_REQUESTED", function(name)
    name = Plain(name)
    if name and session and Rec("players") then
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
On("LOOT_READY", OnLootOpened)
On("LOOT_OPENED", OnLootOpened)
On("LOOT_CLOSED", function() lootHandled = nil end)

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
