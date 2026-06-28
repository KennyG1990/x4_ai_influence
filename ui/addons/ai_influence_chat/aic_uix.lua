---@diagnostic disable: undefined-global, need-check-nil, undefined-field
-- ============================================================================
-- AI INFLUENCE CHAT - HTTP Bridge Client (djfhe_http)
-- POST /v1/request  -> submit a player chat turn
-- GET  /v1/updates_pool -> drain completed replies, write to logbook
-- Poll is driven deterministically by an MD 1s loop raising "AIChat.poll".
-- ============================================================================

local LOAD_REVISION = "aichat-r1"
local BRIDGE_URL = "http://127.0.0.1:8713"

local function log(msg)
    if DebugError then DebugError("[AICHAT][UIX] " .. tostring(msg)) end
end
log("STARTING LOAD rev=" .. LOAD_REVISION)

-- Read Helper lazily — it is nil at file load (see X4_STANDALONE_MENU_SCHEMA / aic_menu.lua).
-- Caching the load-time value would leave Helper nil forever.
local Helper = rawget(_G, "Helper")
local function refreshHelper() if not Helper then Helper = rawget(_G, "Helper") end return Helper end

local ffi = require("ffi")
local C = ffi.C
ffi.cdef [[
    void AddPlayerLogEntry(const char* category, const char* title, const char* text);
    int64_t GetCurrentUTCDataTime(void);
]]

-- ---- djfhe http (CONSUMER API ONLY) ----------------------------------------
-- Require ONLY the request module and use the fluent API:
--   Request.new(METHOD):setUrl():setBody():send(callback)
-- The :send() enqueues into djfhe's own internal client, advanced by djfhe's MD poll.
-- Do NOT require "djfhe.http.client" (it's djfhe-internal) and do NOT add a broad
-- "extensions/?.lua" to package.path — either one poisons djfhe's module cache and
-- breaks its update loop forever ("loop or previous error loading module 'djfhe.http.client'").
-- djfhe registers its OWN package.path in its init.lua, so we just require its public
-- module — but LAZILY (on first use), NOT at file load. Our UI Lua can load before djfhe's
-- init.lua runs; by the time the player sends a chat, djfhe is loaded and the require resolves.
local Request, json = nil, nil
local function ensureDjfhe()
    if Request then return true end
    local ok_r, req = pcall(require, "djfhe.http.request")
    if ok_r and req then Request = req end
    if not json then local ok_j, js = pcall(require, "jsonlua.json"); if ok_j then json = js end end
    if Request then log("djfhe request module loaded (lazy).") end
    return Request ~= nil
end

local function newRequest(method)
    if not ensureDjfhe() then return nil end
    if Request and Request.new then return Request.new(method) end
    if type(Request) == "function" then return Request(method) end
    return nil
end

local function writeToLogbook(title, text)
    refreshHelper()
    pcall(function() C.AddPlayerLogEntry("news", title, text) end)
    if Helper and Helper.showNotification then
        Helper.showNotification({ title = title, text = text, icon = "npc_contact_01", priority = 1 })
    end
end

-- ---- public API ------------------------------------------------------------
if not AI_Influence then AI_Influence = {} end
AI_Influence.processedRequestIds = {}
AI_Influence._autoOpened = false

function AI_Influence.SendToBridge(payload, callback)
    local req = newRequest("POST")
    if not req then
        if callback then callback(false, nil, "djfhe request module missing") end
        return
    end
    req:setUrl(BRIDGE_URL .. "/v1/request")
    -- Keep the known-working body format (JSON string); djfhe sends it as-is.
    req:setBody((json and json.encode) and json.encode(payload) or payload)
    log("POST /v1/request request_id=" .. tostring(payload and payload.request_id))
    req:send(function(resp, err)
        if err then
            if callback then callback(false, nil, "HTTP Error: " .. tostring(err)) end
            return
        end
        local status = (resp and resp.getStatus) and resp:getStatus() or 0
        -- /v1/request returns 202 Accepted (not 200) — accept both.
        if status ~= 200 and status ~= 202 then
            if callback then callback(false, nil, "HTTP Status " .. tostring(status)) end
            return
        end
        local content, jerr = resp:getJson()
        if jerr or not (content and content.ok) then
            if callback then callback(false, nil, "Bridge rejected request") end
            return
        end
        if callback then callback(true, { request_id = content.request_id }, nil) end
    end)
end

function AI_Influence.PollUpdates(callback)
    local req = newRequest("GET")
    if not req then return end
    req:setUrl(BRIDGE_URL .. "/v1/updates_pool")
    req:send(function(resp, err)
        if err then return end
        local status = (resp and resp.getStatus) and resp:getStatus() or 0
        if status ~= 200 then return end
        local content, jerr = resp:getJson()
        if not jerr and content and content.updates and #content.updates > 0 then
            if callback then callback(true, content.updates, nil) end
        end
    end)
end

-- ---- NPC registry: index encounterable/named NPCs + the player into the bridge -------------
-- Param string (from MD): "save_id=...|player=...|npcs=Name~faction;Name~faction;". Posted to
-- /v1/npcs/index, which upserts identity WITHOUT clobbering any existing Player2 binding.
function AI_Influence.IndexNpcs(param)
    local req = newRequest("POST")
    if not req then return end
    local ctx = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "=")
        if eq then ctx[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    local npcs = {}
    for entry in string.gmatch(ctx.npcs or "", "([^;]+)") do
        local sep = string.find(entry, "~")
        if sep then
            npcs[#npcs + 1] = { name = string.sub(entry, 1, sep - 1), faction_id = string.sub(entry, sep + 1) }
        elseif entry ~= "" then
            npcs[#npcs + 1] = { name = entry }
        end
    end
    local body = { save_id = ctx.save_id or "unindexed", player = { name = ctx.player or "Player" }, npcs = npcs }
    req:setUrl(BRIDGE_URL .. "/v1/npcs/index")
    req:setBody((json and json.encode) and json.encode(body) or body)
    log("index_npcs POST count=" .. tostring(#npcs) .. " save=" .. tostring(ctx.save_id))
    req:send(function(resp, err) if err then log("index_npcs err: " .. tostring(err)) end end)
end

local function onIndexNpcs(_, param) AI_Influence.IndexNpcs(param) end

-- ---- ME-wheel suggestions: ask the bridge for short contextual openers, hand them to MD ------
-- MD raises "AIChat.suggest" with "faction_id=..|target_name=..|save_id=.." on conversation start
-- (pre-fetch). We GET /api/suggest and, when it returns ~4s later, push the {label,line} list back
-- to MD via AddUITriggeredEvent so the conversation wheel can build its choices.
function AI_Influence.RequestSuggestions(param)
    local req = newRequest("GET")
    if not req then return end
    local ctx = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "=")
        if eq then ctx[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    local function enc(s) return (string.gsub(tostring(s or ""), "[^%w%-_%.]", function(c)
        return string.format("%%%02X", string.byte(c)) end)) end
    req:setUrl(BRIDGE_URL .. "/api/suggest?save_id=" .. enc(ctx.save_id)
        .. "&faction_id=" .. enc(ctx.faction_id) .. "&npc_name=" .. enc(ctx.target_name))
    log("suggest GET npc=" .. tostring(ctx.target_name))
    req:send(function(resp, err)
        if err then return end
        local status = (resp and resp.getStatus) and resp:getStatus() or 0
        if status ~= 200 then return end
        local content = resp:getJson()
        local s = content and content.suggestions
        if type(s) ~= "table" then return end
        local out = { n = #s }
        for i = 1, #s do out["l" .. i] = s[i].label or ""; out["t" .. i] = s[i].line or "" end
        log("suggest <= " .. tostring(#s) .. " options")
        AddUITriggeredEvent("ai_influence", "suggestions", out)
    end)
end

local function onRequestSuggest(_, param) AI_Influence.RequestSuggestions(param) end

-- ---- world-model write-back: report a relation the dispatcher just changed in-game --------------
-- MD On_action raises "AIChat.relation_report" with "subject=..|object=..|relation=..|save_id=..".
function AI_Influence.ReportRelation(param)
    local req = newRequest("POST")
    if not req then return end
    local ctx = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "=")
        if eq then ctx[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    local body = { save_id = ctx.save_id, subject = ctx.subject, object = ctx.object,
                   relation = tonumber(ctx.relation) or 0, source = "mod_dispatch" }
    req:setUrl(BRIDGE_URL .. "/v1/relation_report")
    req:setBody((json and json.encode) and json.encode(body) or body)
    log("relation_report POST " .. tostring(ctx.subject) .. "->" .. tostring(ctx.object) .. " = " .. tostring(ctx.relation))
    req:send(function(resp, err) if err then log("relation_report err: " .. tostring(err)) end end)
end

local function onReportRelation(_, param) AI_Influence.ReportRelation(param) end

-- #66: a REAL combat event (a watched/ordered ship killed or was destroyed) -> POST a located hostile_event
-- to the event ledger. param = "attacker=..|victim=..|sector=..|kind=..|magnitude=..|save_id=..".
function AI_Influence.ReportHostile(param)
    local req = newRequest("POST")
    if not req then return end
    local ctx = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "=")
        if eq then ctx[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    local body = { save_id = ctx.save_id, events = { {
        attacker_faction = ctx.attacker, victim_faction = ctx.victim, sector = ctx.sector,
        event_kind = ctx.kind or "ship_destroyed", magnitude = tonumber(ctx.magnitude) or 1,
        linked_order_id = ctx.order, source = "game" } } }  -- #67: attribute the loss to the raid order
    req:setUrl(BRIDGE_URL .. "/v1/hostile_events")
    req:setBody((json and json.encode) and json.encode(body) or body)
    log("hostile_event POST " .. tostring(ctx.attacker) .. " vs " .. tostring(ctx.victim) .. " @ " .. tostring(ctx.sector))
    req:send(function(resp, err) if err then log("hostile_event err: " .. tostring(err)) end end)
end

local function onReportHostile(_, param) AI_Influence.ReportHostile(param) end

-- ---- sync-on-load: push the game's ACTUAL faction relations so the DB mirrors reality -----------
-- MD raises "AIChat.sync_relations" with "save_id=<sid>||idA~idB~rel;idA~idB~rel;..." on game load.
function AI_Influence.SyncRelations(param)
    local req = newRequest("POST")
    if not req then return end
    local sid, body = string.match(tostring(param or ""), "save_id=([^|]*)||(.*)")
    sid = (sid ~= nil and sid ~= "") and sid or "unindexed"
    local rels = {}
    for entry in string.gmatch(body or "", "([^;]+)") do
        local a, b, r = string.match(entry, "([^~]+)~([^~]+)~(.+)")
        if a and b and r then rels[#rels + 1] = { subject = a, object = b, relation = tonumber(r) or 0 } end
    end
    req:setUrl(BRIDGE_URL .. "/v1/relations_sync")
    local payload = { save_id = sid, relations = rels }
    req:setBody((json and json.encode) and json.encode(payload) or payload)
    log("relations_sync POST count=" .. tostring(#rels) .. " save=" .. tostring(sid))
    req:send(function(resp, err) if err then log("relations_sync err: " .. tostring(err)) end end)
    AI_Influence.SyncSectors(sid)
    AI_Influence._econTick = (AI_Influence._econTick or 0) + 1
    if AI_Influence._econTick == 1 or (AI_Influence._econTick % 8 == 0) then AI_Influence.SyncEconomy(sid); AI_Influence.SyncFleets(sid); AI_Influence.SyncLogbook(sid); AI_Influence.SyncFactions(sid) end
    if AI_Influence._econTick % 4 == 0 then AI_Influence.SyncInfluence(sid) end
    -- SPEC 1j: drain prominent faction->player comms ~every other tick (cheap GET; comms are rare + cooldown'd).
    if AI_Influence._econTick % 2 == 0 then AI_Influence.DrainPlayerComms(sid) end
end

local function onSyncRelations(_, param) AI_Influence.SyncRelations(param) end

-- ---- logbook: ingest the GAME'S OWN event log (news/alerts/diplomacy) as world memories --------
-- GetLogbook(startIndex,numQuery,category) (vanilla ego_detailmonitor/menu_playerinfo.lua) returns
-- newest-first {time,title,text,factionname,entityname}. POST only entries past a per-category time
-- cursor; the bridge dedups again (cursor resets on reload). Throttled with econ/fleets (~120s).
AI_Influence._logCursor = AI_Influence._logCursor or {}
local LOGBOOK_CATS = { "news", "alerts", "diplomacy" }
function AI_Influence.SyncLogbook(saveId)
    if not GetLogbook then return end
    local out = {}
    for _, cat in ipairs(LOGBOOK_CATS) do
        local ok, lb = pcall(GetLogbook, 1, 50, cat)
        if ok and type(lb) == "table" then
            local seen = AI_Influence._logCursor[cat] or 0
            local newest = seen
            for _, e in ipairs(lb) do
                local t = tonumber(e.time) or 0
                if t > seen then
                    out[#out + 1] = { category = cat, time = t,
                        title = tostring(e.title or ""), text = tostring(e.text or ""),
                        faction = tostring(e.factionname or ""), entity = tostring(e.entityname or "") }
                    if t > newest then newest = t end
                end
            end
            AI_Influence._logCursor[cat] = newest
        end
    end
    if #out > 0 then
        local req = newRequest("POST")
        if req then
            local body = { save_id = (saveId and saveId ~= "") and saveId or "unindexed", entries = out }
            req:setUrl(BRIDGE_URL .. "/v1/logbook_sync")
            req:setBody((json and json.encode) and json.encode(body) or body)
            req:send(function(resp, err) if err then log("logbook_sync err: " .. tostring(err)) end end)
        end
    end
    log("logbook sync new=" .. tostring(#out))
end

-- ---- faction representatives: the named per-faction NPC (the 'rememberer', SPEC 1c-C) ----------
-- C.GetFactionRepresentative(factionid) -> UniverseID; C.GetComponentName(id) -> name (vanilla
-- menu_diplomacy.lua). Static-ish; rides the econ throttle. POST /v1/factions_sync.
pcall(function() ffi.cdef[[ UniverseID GetFactionRepresentative(const char* factionid); ]] end)
local FACTION_LIST = {"argon","antigone","alliance","teladi","ministry","paranid","holyorder","split","freesplit","scaleplate","xenon","khaak","terran","pioneer","hatikvah","boron"}
function AI_Influence.SyncFactions(saveId)
    local out = {}
    for _, fid in ipairs(FACTION_LIST) do
        pcall(function()
            local rep = C.GetFactionRepresentative(fid)
            if rep ~= nil and tonumber(rep) and tonumber(rep) ~= 0 then
                local ok, nm = pcall(function() return ffi.string(C.GetComponentName(rep)) end)
                if ok and nm and nm ~= "" then
                    out[#out + 1] = { faction_id = fid, representative = nm }
                end
            end
        end)
    end
    if #out > 0 then
        local req = newRequest("POST")
        if req then
            local body = { save_id = (saveId and saveId ~= "") and saveId or "unindexed", factions = out }
            req:setUrl(BRIDGE_URL .. "/v1/factions_sync")
            req:setBody((json and json.encode) and json.encode(body) or body)
            req:send(function(resp, err) if err then log("factions_sync err: " .. tostring(err)) end end)
        end
    end
    log("factions sync reps=" .. tostring(#out))
end

-- ---- autonomous faction AI (SPEC 1d W1/1d-S): pull bridge decisions, post as in-game news --------
-- KEYSTONE (2026-06-26): pull PRE-GENERATED influence output via the FAST drain. The old path POSTed
-- /v1/influence_step, which ran LLM news + narrator SYNCHRONOUSLY (6-45s) and timed out this in-game request,
-- so news/actions/articles never arrived. Generation now runs in a bridge background daemon; this GET returns
-- instantly (no LLM in the request path) with the same {news, actions, articles} shape. Each news item =
-- { text=, category= }; the bridge marks its own text self-authored so SyncLogbook won't re-ingest it.
function AI_Influence.SyncInfluence(saveId)
    local req = newRequest("GET")
    if not req then return end
    local sid = (saveId and saveId ~= "") and saveId or "unindexed"
    req:setUrl(BRIDGE_URL .. "/v1/influence_drain?save_id=" .. sid)
    req:send(function(resp, err)
        if err then return end
        local status = (resp and resp.getStatus) and resp:getStatus() or 0
        if status ~= 200 then return end
        local content, jerr = resp:getJson()
        if not jerr and content and AddUITriggeredEvent then
            -- Lua cannot render UI; RAISE an MD event per decision and let the per-category MD cue
            -- (ai_influence_galaxynews.xml: log_diplomacy/log_news/log_general/log_alerts) write the
            -- logbook + notification in MD context (the only one X4 renders). AddUITriggeredEvent works
            -- from this async callback (the suggestion wheel uses it). SPEC 1d-S: route by item.category.
            if content.news then
                for _, item in ipairs(content.news) do
                    local txt = (type(item) == "table") and item.text or tostring(item)
                    local cat = (type(item) == "table") and item.category or "diplomacy"
                    if txt and txt ~= "" then
                        pcall(function() AddUITriggeredEvent("ai_influence", "log_" .. tostring(cat), tostring(txt)) end)
                    end
                end
            end
            -- SPEC 1d-W2: REAL relation changes -> the proven On_action MD cue (ai_influence_contract.xml ->
            -- set_faction_relation -> X4 fleets fight). MUST rebuild a FRESH plain Lua table (like the chat
            -- action path) with tonumber(relation); passing the raw getJson table does NOT round-trip through
            -- event.param3 into MD.
            if content.actions then
                for _, a in ipairs(content.actions) do
                    if type(a) == "table" then
                        local tp = { type = tostring(a.type or "adjust_relation") }
                        if a.faction then tp.faction = tostring(a.faction) end
                        if a.target then tp.target = tostring(a.target) end
                        if a.relation ~= nil then tp.relation = tonumber(a.relation) or 0 end
                        -- SPEC 3.3-B economy action fields (fresh plain table, same round-trip rule as relation)
                        if a.ware then tp.ware = tostring(a.ware) end
                        if a.amount ~= nil then tp.amount = tonumber(a.amount) or 0 end
                        if a.op then tp.op = tostring(a.op) end
                        -- SPEC 3.3-B military order field (patrol|raid)
                        if a.kind then tp.kind = tostring(a.kind) end
                        pcall(function() AddUITriggeredEvent("ai_influence", "action", tp) end)
                    end
                end
            end
            -- SPEC 2b: NARRATOR history articles -> the News logbook tab with the article's OWN title. Fresh
            -- plain table {title, body} (same round-trip rule as the action/comms paths).
            if content.articles then
                for _, art in ipairs(content.articles) do
                    if type(art) == "table" and art.title and art.body then
                        local tp = { title = tostring(art.title), body = tostring(art.body) }
                        if art.consequence and tostring(art.consequence) ~= "" then tp.consequence = tostring(art.consequence) end
                        pcall(function() AddUITriggeredEvent("ai_influence", "log_article", tp) end)
                    end
                end
            end
        end
    end)
end

-- SPEC 1j: drain prominent faction->player communiques. GET /v1/player_comms -> for each, RAISE an MD event
-- 'comms_incoming' carrying a FRESH plain Lua table (title/body/faction/category) so the comms MD cue renders
-- the incoming transmission + logbook entry in MD-action context (the only context X4 renders from). Same
-- fresh-table rule as the action path (a raw getJson table does NOT round-trip through event.param3).
function AI_Influence.DrainPlayerComms(saveId)
    local req = newRequest("GET")
    if not req then return end
    req:setUrl(BRIDGE_URL .. "/v1/player_comms")
    req:send(function(resp, err)
        if err then return end
        local status = (resp and resp.getStatus) and resp:getStatus() or 0
        if status ~= 200 then return end
        local content, jerr = resp:getJson()
        if jerr or not content or not content.comms or not AddUITriggeredEvent then return end
        for _, c in ipairs(content.comms) do
            if type(c) == "table" then
                local tp = {
                    title = tostring(c.title or "Incoming Transmission"),
                    body = tostring(c.body or ""),
                    faction = tostring(c.faction or ""),
                    category = tostring(c.category or "alerts"),
                }
                pcall(function() AddUITriggeredEvent("ai_influence", "comms_incoming", tp) end)
            end
        end
    end)
end

-- ---- sector ownership: enumerate each faction's sectors (vanilla GetSectorsByOwner) ------------
-- Rides the relations heartbeat (Do_sync raises AIChat.sync_relations on load + every 15s). POSTs
-- {sector_id,name,owner} per sector to /v1/sectors_sync. Grounded on unpacked vanilla
-- (ego_detailmonitor/menu_map.lua: GetSectorsByOwner VLA + ffi.string(GetComponentName)).
pcall(function() ffi.cdef[[
    typedef uint64_t UniverseID;
    uint32_t GetNumSectorsByOwner(const char* factionid);
    uint32_t GetSectorsByOwner(UniverseID* result, uint32_t resultlen, const char* factionid);
]] end)
local SECTOR_FACTIONS = {"argon","antigone","alliance","teladi","ministry","paranid","holyorder","split","freesplit","scaleplate","xenon","khaak","player"}
function AI_Influence.SyncSectors(saveId)
    local req = newRequest("POST")
    if not req then return end
    local sectors = {}
    for _, fid in ipairs(SECTOR_FACTIONS) do
        pcall(function()
            local n = C.GetNumSectorsByOwner(fid)
            if n and tonumber(n) and tonumber(n) > 0 then
                local buf = ffi.new("UniverseID[?]", n)
                local m = C.GetSectorsByOwner(buf, n, fid)
                for i = 0, (tonumber(m) or 0) - 1 do
                    -- buf is an ffi UniverseID[] (uint64_t), so buf[i] is raw CDATA. GetComponentData wants
                    -- a Lua component ID, not cdata ("Invalid argument #1 got cdata") — convert it the way the
                    -- proven skills reader does (ConvertStringToLuaID(tostring(...))). Keep the raw cdata for the
                    -- C.* engine calls (they take the UniverseID directly) and for the stable string key.
                    local rawid = buf[i]
                    local sid = ConvertStringToLuaID(tostring(rawid))
                    local macro = nil
                    pcall(function() macro = GetComponentData(sid, "macro") end)
                    local name = "Unknown Sector"
                    if macro and macro ~= "" then
                        local mok, mn = pcall(function() return GetMacroData(macro, "name") end)
                        if mok and mn and mn ~= "" then name = mn end
                    end
                    if name == "Unknown Sector" then
                        local nok, nn = pcall(function() return ffi.string(C.GetComponentName(rawid)) end)
                        if nok and nn and nn ~= "" then name = nn end
                    end
                    local sector_id = (macro and macro ~= "") and tostring(macro) or (tostring(rawid):gsub("U?LL$", ""))
                    sectors[#sectors + 1] = { sector_id = sector_id, name = name, owner = fid }
                end
            end
        end)
    end
    local body = { save_id = (saveId and saveId ~= "") and saveId or "unindexed", sectors = sectors }
    req:setUrl(BRIDGE_URL .. "/v1/sectors_sync")
    req:setBody((json and json.encode) and json.encode(body) or body)
    log("sectors_sync POST count=" .. tostring(#sectors) .. " save=" .. tostring(saveId))
    req:send(function(resp, err) if err then log("sectors_sync err: " .. tostring(err)) end end)
end

-- ---- fleet strength: per-faction ship census (vanilla GetContainedObjectsByOwner) -------------
-- Heavy, throttled ~120s. Per faction: enumerate objects, keep ships (class "ship_*"), bucket by
-- primarypurpose (fight/trade/mine/build/other), count capitals (ship_l/ship_xl). POST /v1/fleets_sync.
local FLEET_FACTIONS = {"player","argon","antigone","alliance","teladi","ministry","paranid","holyorder","split","freesplit","scaleplate","xenon","khaak"}
pcall(function() ffi.cdef[[ const char* GetMacroClass(const char* macroname); ]] end)
function AI_Influence.SyncFleets(saveId)
    local fleets = {}
    local presence = {}      -- presence[sectorKey][faction] = fight-ship count (-> contested_by on bridge)
    local sectKeyCache = {}  -- ship-sector component -> sector key (cache; many ships share a sector)
    for _, fid in ipairs(FLEET_FACTIONS) do
        pcall(function()
            -- Faction ship census. CRITICAL: GetContainedObjectsByOwner(fid) with a SINGLE arg
            -- enumerates galaxy-wide; passing (fid, nil, true) returns EMPTY (verified in-game).
            -- Ship detection: GetMacroClass(macro) starts "ship_" (GetComponentData "class" is dead here).
            -- Role split via primarypurpose; capitals = ship_l + ship_xl.
            local objs = GetContainedObjectsByOwner(fid)
            local total, fight, trade, mine, build, caps = 0, 0, 0, 0, 0, 0
            if type(objs) == "table" then
                for _, obj in ipairs(objs) do
                    pcall(function()
                        local macro = GetComponentData(obj, "macro")
                        if macro and macro ~= "" then
                            local mc = tostring(ffi.string(C.GetMacroClass(macro)) or "")
                            if mc:sub(1, 5) == "ship_" then
                                total = total + 1
                                local sz = mc:sub(6)
                                if sz == "l" or sz == "xl" then caps = caps + 1 end
                                local pp = tostring(GetComponentData(obj, "primarypurpose") or "")
                                if pp == "fight" then
                                    fight = fight + 1
                                    -- Combat-ship sector presence -> contested_by. Key MUST match
                                    -- SyncSectors (sector macro string, else numeric id) so the bridge joins.
                                    local sc = GetComponentData(obj, "sector")
                                    if sc then
                                        local ck = tostring(sc)          -- raw string = stable cache key
                                        local sk = sectKeyCache[ck]
                                        if not sk then
                                            local sm = nil
                                            -- sc is a component returned BY GetComponentData -> it's cdata;
                                            -- passing it straight back in throws "Invalid argument got cdata".
                                            -- Normalise to a Lua id first (same fix as SyncSectors).
                                            pcall(function() sm = GetComponentData(ConvertStringToLuaID(ck), "macro") end)
                                            sk = (sm and sm ~= "") and tostring(sm) or (ck:gsub("U?LL$", ""))
                                            sectKeyCache[ck] = sk
                                        end
                                        local pe = presence[sk]; if not pe then pe = {}; presence[sk] = pe end
                                        pe[fid] = (pe[fid] or 0) + 1
                                    end
                                elseif pp == "trade" then trade = trade + 1
                                elseif pp == "mine" then mine = mine + 1
                                elseif pp == "build" then build = build + 1 end
                            end
                        end
                    end)
                end
            end
            fleets[#fleets + 1] = { faction_id = fid, total_ships = total, fight = fight,
                trade = trade, mine = mine, build = build, other = 0, capitals = caps }
        end)
    end
    if #fleets > 0 then
        local req = newRequest("POST")
        if req then
            local body = { save_id = (saveId and saveId ~= "") and saveId or "unindexed", fleets = fleets, presence = presence }
            req:setUrl(BRIDGE_URL .. "/v1/fleets_sync")
            req:setBody((json and json.encode) and json.encode(body) or body)
            req:send(function(resp, err) if err then log("fleets_sync err: " .. tostring(err)) end end)
        end
    end
    log("fleets sync " .. tostring(#fleets) .. " factions")
end

-- ---- economy: per-STATION capture, round-robin (vanilla GetContainedStationsByOwner) ------------
-- #54: emit ONE record per station to /v1/economy/stations; the bridge ROLLUP derives shortages/key_needs/
-- production_health/market_status from the accumulated table. We round-robin ONE faction + a bounded slice
-- per call so a full sweep amortizes over heartbeats — the C-API runs on the UI thread, and a paranid-sized
-- 165-station sweep in a single tick would stutter the game (canon "throttled incremental indexer"). Reads are
-- the Lua-FFI equivalent of DeadAir's MD economy reads (see the x4-reference-mods skill): GetComponentData st
-- products/allresources/sector/macro/name/idcode (all proven in-mod). PK (save_id, station_id) = upsert.
local ECON_FACTIONS = {"argon","antigone","alliance","teladi","ministry","paranid","holyorder","split","freesplit","scaleplate","xenon","khaak"}
local ECON_STATION_CAP = 60
local function aic_wareList(station, field)
    local out, seen = {}, {}
    pcall(function()
        local list = GetComponentData(station, field)
        if type(list) == "table" then
            for _, w in ipairs(list) do
                local ware = (type(w) == "table") and (w.ware or w.id or w[1]) or w
                ware = ware and tostring(ware) or nil
                if ware and ware ~= "" and not seen[ware] then seen[ware] = true; out[#out + 1] = ware end
            end
        end
    end)
    return out
end
function AI_Influence.SyncEconomy(saveId)
    local sid = (saveId and saveId ~= "") and saveId or "unindexed"
    AI_Influence._econFac = AI_Influence._econFac or 1
    local fid = ECON_FACTIONS[AI_Influence._econFac]
    local function advanceFaction()
        AI_Influence._econFac = (AI_Influence._econFac % #ECON_FACTIONS) + 1
        AI_Influence._econOff = 0
    end
    pcall(function()
        local stations = GetContainedStationsByOwner(fid, nil, true)
        local total = (type(stations) == "table") and #stations or 0
        if total == 0 then advanceFaction(); return end
        local off = AI_Influence._econOff or 0
        if off >= total then off = 0 end
        local last = math.min(off + ECON_STATION_CAP, total)
        local recs = {}
        for i = off + 1, last do
            local st = stations[i]
            local rec = { faction_id = fid }
            local code; pcall(function() code = GetComponentData(st, "idcode") end)
            rec.station_id = (code and tostring(code) ~= "") and tostring(code) or tostring(st)
            pcall(function() rec.sector_id = tostring(GetComponentData(st, "sector") or "") end)
            pcall(function() rec.station_name = tostring(GetComponentData(st, "name") or "") end)
            pcall(function() rec.station_type = tostring(GetComponentData(st, "macro") or "") end)
            rec.products = aic_wareList(st, "products")
            rec.needs = aic_wareList(st, "allresources")
            recs[#recs + 1] = rec
        end
        if #recs > 0 then
            local req = newRequest("POST")
            if req then
                local body = { save_id = sid, stations = recs, rollup = true }
                req:setUrl(BRIDGE_URL .. "/v1/economy/stations")
                req:setBody((json and json.encode) and json.encode(body) or body)
                req:send(function(resp, err) if err then log("economy err: " .. tostring(err)) end end)
            end
            log("economy " .. fid .. " stations " .. tostring(off) .. ".." .. tostring(last) .. "/" .. tostring(total) .. " sent=" .. tostring(#recs))
        end
        if last >= total then advanceFaction() else AI_Influence._econOff = last end
    end)
end

-- ---- per-NPC skills: read the live crew skills the way the vanilla crew menu does ---------------
-- MD raises "AIChat.npc_skills" at conversation start with the NPC component. We read its per-skill
-- values via GetComponentData(npc,"skills") — grounded on the unpacked game UI
-- (ui/addons/ego_detailmonitor/menu_map.lua): the call returns a LIST of {name=, value=} entries.
-- We stash them keyed by name and fold them into full_context at window-open time so they ride to
-- the bridge as prompt_vars.skills. pcall-wrapped so a bad/stale component can never break the chat.
AI_Influence._pendingSkills = nil
function AI_Influence.ReadNpcSkills(component)
    -- A3b PHASE-0 PROBE (2026-06-27): ONE in-game chat -> FULL save+exit+reload -> chat-again answers BOTH
    -- questions from the identity-binding spec: Q1 does X4 expose a STABLE person idcode? Q2 does the runtime
    -- component id survive save/reload? Log the raw component id (Q2) PLUS candidate persistent fields
    -- (idcode/name/owner) (Q1), each pcall-guarded so a missing/invalid field can never break the chat. Compare
    -- the "A3b probe =>" line before vs after a full save+reload to choose Path A/B/C.
    AI_Influence._pendingNpcId = tostring(component)
    pcall(function()
        local pid = ConvertStringToLuaID(tostring(component))
        local function f(field)
            local v = nil
            pcall(function() v = GetComponentData(pid, field) end)
            return tostring(v)
        end
        -- I1 GROUND (2026-06-28): idcode came back EMPTY in #99, so before building the evidence
        -- pipeline, discover which OTHER fields are runtime-readable for a PERSON component. Appended to
        -- the same "A3b probe =>" line so the Forge parse-log endpoint returns them in `.line`.
        log("A3b probe => raw=" .. tostring(component) .. " idcode=" .. f("idcode")
            .. " name=" .. f("name") .. " owner=" .. f("owner")
            .. " macro=" .. f("macro") .. " code=" .. f("code") .. " class=" .. f("class")
            .. " container=" .. f("container") .. " commander=" .. f("commander") .. " sector=" .. f("sector"))
    end)
    local skills = nil
    pcall(function()
        local luaid = ConvertStringToLuaID(tostring(component))
        local skilltable = GetComponentData(luaid, "skills") or {}
        local out = {}
        for _, entry in ipairs(skilltable) do
            if entry and entry.name then out[entry.name] = entry.value end
        end
        if next(out) then skills = out end
    end)
    AI_Influence._pendingSkills = skills
    log("npc_skills read => " .. (skills and "ok" or "empty"))
    -- I1 (2026-06-28): capture the runtime-readable identity EVIDENCE. Grounded: macro + sector ARE
    -- readable for a person; code/class/commander are nil. macro is the corroborator that lifts a
    -- re-encountered NPC tentative->bound. Stashed like skills, folded into context at window open.
    AI_Influence._pendingNpcMacro = nil
    AI_Influence._pendingNpcSector = nil
    pcall(function()
        local pid2 = ConvertStringToLuaID(tostring(component))
        local mc; pcall(function() mc = GetComponentData(pid2, "macro") end)
        if mc ~= nil and tostring(mc) ~= "nil" and tostring(mc) ~= "" then AI_Influence._pendingNpcMacro = tostring(mc) end
        local sc; pcall(function() sc = GetComponentData(pid2, "sector") end)
        if sc ~= nil and tostring(sc) ~= "nil" and tostring(sc) ~= "" then AI_Influence._pendingNpcSector = tostring(sc) end
    end)
end

local function onNpcSkills(_, component) AI_Influence.ReadNpcSkills(component) end

-- ---- single poll handler (drains replies, routes to logbook + actions) -----
local function handleUpdates(success, updates)
    if not (success and updates) then return end
    for _, update in ipairs(updates) do
        local text = update.text or update.reply or ""
        local author = update.author_name or update.author or update.name or "AI"

        -- NPC-state colour feedback on the open window, if any
        local menu = rawget(_G, "X4_Terminal_Menu")
        if update.state and menu and update.state ~= menu.npcState then
            menu.npcState = update.state
            if menu.active and menu.display then menu.display() end
        end

        if text ~= "" then
            log("logbook <= " .. tostring(author) .. ": " .. tostring(text))
            writeToLogbook(author, text)
            -- Append the NPC reply to the in-window transcript and refresh if the window is open.
            if menu then
                menu.history = menu.history or {}
                table.insert(menu.history, { role = "assistant", text = text })
                if menu.active and menu.display then menu.display() end
            end
        end

        -- actions (exactly once): gate confirm-required ones (influence/set_relation) behind a typed
        -- "yes" in the chat; dispatch the rest immediately. No silent war-declarations on the save.
        if update.actions and type(update.actions) == "table" and #update.actions > 0 then
            local reqId = update.request_id
            if reqId and not AI_Influence.processedRequestIds[reqId] then
                AI_Influence.processedRequestIds[reqId] = true
                for _, action in ipairs(update.actions) do
                    local actionType = action.type or action.action or "none"
                    local actionArgs = action.args or action.params or {}
                    local triggerParams = { type = actionType }
                    for k, v in pairs(actionArgs) do
                        if k == "relation" then triggerParams[k] = tonumber(v) or 0 else triggerParams[k] = v end
                    end
                    if action.needs_confirm and menu then
                        menu._pendingAction = triggerParams   -- aic_menu.onInput dispatches on "yes"
                        menu.history = menu.history or {}
                        table.insert(menu.history, { role = "assistant",
                            text = "[Proposal] " .. tostring(action.description or "An action is proposed.")
                                .. " Reply 'yes' to confirm, or anything else to decline." })
                        if menu.active and menu.display then menu.display() end
                        log("pending action held for confirm: " .. tostring(actionType))
                    else
                        log("UI action (immediate): " .. tostring(actionType))
                        AddUITriggeredEvent("ai_influence", "action", triggerParams)
                    end
                end
            end
        end
    end
end

-- Forward declaration so onPollTick (above onOpenCommLink) can fire the one-shot open.
local onOpenCommLink

local function onPollTick(_, _)
    -- Register the menu with the engine as soon as the global Helper exists (it is nil at file
    -- load — see aic_menu.lua). The MD 1s poll starts right after load, so the menu is registered
    -- a few seconds BEFORE Auto_open fires. This mirrors SirNukes' standalone_menu.lua, which
    -- defers its Init (table.insert(Menus)/Helper.registerMenu) until the menu env is ready via
    -- Register_Require_With_Init, rather than registering at file scope. (ref: bvbohnen/x4-projects
    -- sn_mod_support_apis ui/simple_menu/standalone_menu.lua)
    local m = rawget(_G, "X4_Terminal_Menu")
    if m and m.ensureRegistered and not m._registered then m.ensureRegistered() end
    -- (Removed the one-shot auto-open test scaffold: the window must only open from a real player
    -- action — the walk-up "Speak to AI" conversation choice — never on UI reload.)
    -- Auto-send a chosen ME-wheel opener once the window is actually open (set in onOpenCommLink).
    if m and m.active and m._pendingInitial and m.onInput then
        local t = m._pendingInitial; m._pendingInitial = nil
        log("auto-send opener: " .. tostring(t))
        pcall(m.onInput, t)
    end
    AI_Influence.PollUpdates(handleUpdates)
end

-- ---- open the comm window --------------------------------------------------
onOpenCommLink = function(_, params)
    log("onOpenCommLink")
    refreshHelper()
    local context = {}
    if type(params) == "string" then
        local sepStart, sepEnd = string.find(params, "||", 1, true)
        local contextStr = params
        if sepStart then contextStr = string.sub(params, sepEnd + 1) end
        for pair in string.gmatch(contextStr, "([^|]+)") do
            local eqPos = string.find(pair, "=")
            if eqPos then context[string.sub(pair, 1, eqPos - 1)] = string.sub(pair, eqPos + 1) end
        end
    end
    local termMenu = rawget(_G, "X4_Terminal_Menu")
    if not termMenu then
        local all = rawget(_G, "Menus")
        if all then for _, m in ipairs(all) do if m.name == "X4_Terminal" then termMenu = m break end end end
    end
    -- Definitive diagnostics: the window not appearing is almost always (a) the menu object
    -- never registered, or (b) display() erroring. Log both so the next reload's debuglog says
    -- EXACTLY where it dies instead of us guessing.
    log("onOpenCommLink: X4_Terminal_Menu " .. (termMenu and "FOUND" or "MISSING -> aic_menu.lua did not load/register"))
    if termMenu then
        -- Fold the per-skill values stashed by AIChat.npc_skills into the context so they ride to
        -- the bridge as prompt_vars.skills (consumed in router.py build_request -> target.skills).
        if AI_Influence._pendingSkills and next(AI_Influence._pendingSkills) then
            context["skills"] = AI_Influence._pendingSkills
        end
        -- I1: ride the identity evidence to the bridge alongside skills (consumed in
        -- player2_client.npc_complete -> rebind_session). Only set what was actually readable.
        if AI_Influence._pendingNpcMacro then context["macro"] = AI_Influence._pendingNpcMacro end
        if AI_Influence._pendingNpcSector and not context["sector"] then context["sector"] = AI_Influence._pendingNpcSector end
        if AI_Influence._pendingNpcId then context["runtime_component_id"] = AI_Influence._pendingNpcId end
        termMenu.currentContext = {
            faction = context["faction_id"] or context["$faction_id"] or "argon",
            target  = context["target_name"] or context["$target_name"] or "Faction Officer",
            -- Per-save id from MD (Save_identity.$save_uuid). Keys bridge memory/chat to THIS
            -- playthrough so a new game starts fresh. nil if MD didn't send it (bridge falls back).
            save_id = context["save_id"] or context["$save_id"],
            full_context = context,
        }
        -- ME-wheel opener: if the player picked a suggested line, queue it to auto-send once the
        -- window is active (the poll tick does the send, so it waits for the engine to open it).
        local initial = context["initial"] or context["$initial"]
        termMenu._pendingInitial = (initial ~= nil and initial ~= "") and initial or nil
        termMenu._openRequested = true
        if Helper and Helper.closeInteractMenu then pcall(Helper.closeInteractMenu) end
        -- Complete the engine registration NOW (open time), when the global Helper is populated —
        -- at file load it was nil, so registerMenu was skipped and OpenMenu had nothing to open.
        if termMenu.ensureRegistered then
            local reg = termMenu.ensureRegistered()
            log("ensureRegistered before open => engineRegistered=" .. tostring(reg))
        end
        -- GROUNDED FIX (ref: SirNukes simple_menu/Standalone_Menu.lua): a registered menu is opened
        -- by the ENGINE function OpenMenu(name,...), which then calls menu.onShowMenu() -> the frame
        -- build. We were calling onShowMenu/RaiseEvent directly, which builds a frame the engine
        -- never actually opens -> nothing renders. OpenMenu is the missing piece. currentContext is
        -- set above so onShowMenu reads it when the engine fires it (after a short delay).
        if OpenMenu then
            log("OpenMenu('" .. termMenu.name .. "') registeredInMenus=" .. tostring((function()
                local all = rawget(_G, "Menus"); if not all then return false end
                for _, m in ipairs(all) do if m.name == termMenu.name then return true end end; return false
            end)()))
            local ok, err = pcall(OpenMenu, termMenu.name, nil, nil, true)
            log("OpenMenu returned " .. (ok and "OK" or ("ERROR: " .. tostring(err))))
        elseif termMenu.onShowMenu then
            local ok, err = pcall(termMenu.onShowMenu)
            log("OpenMenu missing; onShowMenu fallback " .. (ok and "OK" or ("ERROR: " .. tostring(err))))
        end
    end
end

local function init()
    RegisterEvent("AIChat.open", onOpenCommLink)
    RegisterEvent("AIChat.poll", onPollTick)
    RegisterEvent("AIChat.index_npcs", onIndexNpcs)
    RegisterEvent("AIChat.suggest", onRequestSuggest)
    RegisterEvent("AIChat.relation_report", onReportRelation)
    RegisterEvent("AIChat.hostile_event", onReportHostile)
    RegisterEvent("AIChat.sync_relations", onSyncRelations)
    RegisterEvent("AIChat.npc_skills", onNpcSkills)
    log("events registered: AIChat.open, AIChat.poll, AIChat.index_npcs, AIChat.suggest, AIChat.relation_report, AIChat.sync_relations, AIChat.npc_skills")
end
init()
