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
    local sid = ctx.save_id or "unindexed"
    local npcs = {}
    -- entry = name~faction~role (faction + role optional). Key sid|chat|name + game_id=chat so a censused NPC
    -- and a LATER chat unify on ONE card (= make_key(save,"chat",name)), same as the Lua SyncNpcCensus.
    for entry in string.gmatch(ctx.npcs or "", "([^;]+)") do
        local parts = {}
        for p in string.gmatch(entry, "([^~]+)") do parts[#parts + 1] = p end
        local nm = parts[1]
        if nm and nm ~= "" then
            npcs[#npcs + 1] = { npc_key = sid .. "|chat|" .. nm, name = nm,
                                faction_id = parts[2], role = parts[3] }
        end
    end
    local body = { save_id = sid, game_id = "chat", player = { name = ctx.player or "Player" }, npcs = npcs }
    req:setUrl(BRIDGE_URL .. "/v1/npcs/index")
    req:setBody((json and json.encode) and json.encode(body) or body)
    log("index_npcs POST count=" .. tostring(#npcs) .. " save=" .. tostring(ctx.save_id))
    req:send(function(resp, err) if err then log("index_npcs err: " .. tostring(err)) end end)
end

local function onIndexNpcs(_, param) AI_Influence.IndexNpcs(param) end

-- ---- EPIC I probe: Blackboard persistent NPC identity (ChemODun object-ref + string-key + npctemplate) -------
-- On each conversation open, test two durable-identity payloads on the conversation NPC and POST observations to
-- the bridge (which derives the verdict). PRIMARY: store the NPC OBJECT REFERENCE on the PLAYER scope keyed by a
-- stable name|faction token (X4 should remap the pointer on reload). SECONDARY: a plain string key on the NPC
-- itself. Also capture npctemplate (Tier-2 fallback). Fully guarded — a wrong assumption records a failed read,
-- never crashes the chat. The bridge correlates: same token read under ≥2 distinct runtime ids = survived a reload.
pcall(function() ffi.cdef [[ UniverseID GetPlayerID(void); ]] end)
function AI_Influence.BlackboardProbe(ctx)
    ctx = ctx or {}
    local okp = pcall(function()
        if not (SetNPCBlackboard and GetNPCBlackboard and ConvertStringToLuaID) then return end
        local rawid = AI_Influence._pendingNpcId
        if not rawid then return end
        local npc = ConvertStringToLuaID(tostring(rawid))
        local name = tostring(ctx.target_name or ctx["$target_name"] or ctx.name or "")
        local faction = tostring(ctx.faction_id or ctx["$faction_id"] or ctx.faction or "")
        local save_id = tostring(ctx.save_id or ctx["$save_id"] or "")
        local strkey = "$aic_persistent_npc_key"

        local tmpl = ""
        pcall(function() tmpl = tostring(GetComponentData(npc, "npctemplate") or "") end)

        -- PERSISTENT TOKEN (candidate PRIMARY identity key): read the NPC's own durable key; if absent, MINT a
        -- UNIQUE one and write it. Duplicate-safe BY DESIGN — the mint uses this NPC's current runtime id (unique
        -- per NPC at first encounter) + a random salt, so two same-name crew get DIFFERENT tokens on their own
        -- blackboards. Once written it persists across reload (proven), so we never re-mint.
        local existing = nil
        pcall(function() existing = GetNPCBlackboard(npc, strkey) end)
        local s_phase, s_value, s_write, s_read
        if existing == nil or existing == 0 or existing == "" then
            s_value = "aic_" .. tostring(rawid) .. "_" .. tostring(math.random(100000, 999999))
            pcall(function() SetNPCBlackboard(npc, strkey, s_value) end)
            local rb = nil; pcall(function() rb = GetNPCBlackboard(npc, strkey) end)
            s_write, s_read, s_phase = true, (tostring(rb) == s_value), "write"
        else
            s_value, s_write, s_read, s_phase = tostring(existing), false, true, "read"
        end
        local token = string.gsub(tostring(s_value), "[^%w]", "_")   -- bb-key-safe form of the unique token
        local objkey = "$aic_obj_" .. token

        -- PRIMARY: object reference stored on the durable PLAYER scope, keyed by the UNIQUE token (no collision).
        local o_value, o_write, o_read, o_match = "objref_" .. token, false, false, false
        local player = nil
        pcall(function() player = ConvertStringToLuaID(tostring(C.GetPlayerID())) end)
        if player then
            pcall(function() SetNPCBlackboard(player, objkey, npc); o_write = true end)
            local restored = nil
            pcall(function() restored = GetNPCBlackboard(player, objkey) end)
            if restored ~= nil and restored ~= 0 and tostring(restored) ~= "" then
                o_read = true
                pcall(function()
                    local rn = GetComponentData(restored, "name")
                    o_match = (tostring(rn) == name) and (name ~= "")
                end)
            end
        end

        local function postRow(row)
            local req = newRequest("POST"); if not req then return end
            row.save_id = save_id
            row.runtime_component_id = row.runtime_component_id or tostring(rawid)
            row.npc_name = row.npc_name or name
            row.faction = row.faction or faction
            row.role = row.role or tostring(ctx.npc_role or ctx["$npc_role"] or ctx.role or "")
            row.ship_or_station = tostring(ctx.ship or ""); row.sector = tostring(ctx.sector or "")
            row.npctemplate = tmpl; row.target_type = "conversation_person"
            req:setUrl(BRIDGE_URL .. "/v1/npc_identity_probe/blackboard")
            req:setBody((json and json.encode) and json.encode(row) or row)
            req:send(function(_, err) if err then log("bbprobe err: " .. tostring(err)) end end)
        end
        postRow({ phase = s_phase, payload_type = "string", blackboard_key = strkey,
                  blackboard_value = s_value, write_success = s_write, read_success = s_read })
        postRow({ phase = "read", payload_type = "object", blackboard_key = objkey,
                  blackboard_value = o_value, write_success = o_write, read_success = o_read, restored_match = o_match })
        -- PHASE 6 (duplicate-collision): when we meet a SECOND NPC with the same NAME this session, emit a
        -- `duplicate` row for BOTH this NPC and the prior same-name one (each with its OWN token + runtime id),
        -- so the bridge verdict's dup_ok can confirm same-name crew get DISTINCT tokens. If the mint ever collided
        -- (same token for two NPCs) the verdict flags dup_ok=False — this is the in-game proof of that guarantee.
        AI_Influence._bbSeen = AI_Influence._bbSeen or {}
        if name ~= "" then
            local prior = AI_Influence._bbSeen[name]
            if prior and prior.rid ~= tostring(rawid) then
                postRow({ phase = "duplicate", payload_type = "string", blackboard_key = strkey,
                          blackboard_value = s_value, read_success = true })
                postRow({ phase = "duplicate", payload_type = "string", blackboard_key = strkey,
                          blackboard_value = prior.tok, read_success = true,
                          npc_name = name, runtime_component_id = prior.rid })
            end
            if not prior then AI_Influence._bbSeen[name] = { tok = s_value, rid = tostring(rawid) } end
        end
        -- Carry the token into the chat context → it rides prompt_vars to the bridge (contracts merges prompt_vars
        -- into request.metadata), so npc_complete keys this conversation's MEMORY by the token (per-ID memory).
        if s_value and s_value ~= "" then ctx.blackboard_key = tostring(s_value) end
        -- WIRE: bind this NPC's identity to its durable Blackboard token (the PRIMARY key) → flips it to BOUND.
        if s_value and s_value ~= "" then
            local breq = newRequest("POST")
            if breq then
                breq:setUrl(BRIDGE_URL .. "/v1/identity/bind_blackboard")
                breq:setBody((json and json.encode) and json.encode({
                    save_id = save_id, name = name, faction = faction,
                    role = tostring(ctx.npc_role or ctx["$npc_role"] or ctx.role or ""),
                    blackboard_key = s_value, runtime_id = tostring(rawid) }) or "")
                breq:send(function(_, err) if err then log("bbbind err: " .. tostring(err)) end end)
            end
        end
        log("bbprobe name=" .. name .. " str_read=" .. tostring(s_read) .. " obj_read=" .. tostring(o_read)
            .. " obj_match=" .. tostring(o_match) .. " tmpl=" .. tostring(tmpl))
    end)
    if not okp then log("bbprobe failed (guarded)") end
end

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

-- P1 (#113): fetch suggestions as a {label,line} LIST for the chat WINDOW's choice buttons. The MD
-- native wheel uses RequestSuggestions (AddUITriggeredEvent → On_suggestions); the window needs the
-- list directly via a callback. Same GET, conversation-aware server-side (#112).
function AI_Influence.FetchSuggestions(faction_id, target_name, save_id, cb)
    local req = newRequest("GET")
    if not req then return end
    local function enc(s) return (string.gsub(tostring(s or ""), "[^%w%-_%.]", function(c)
        return string.format("%%%02X", string.byte(c)) end)) end
    req:setUrl(BRIDGE_URL .. "/api/suggest?save_id=" .. enc(save_id)
        .. "&faction_id=" .. enc(faction_id) .. "&npc_name=" .. enc(target_name))
    req:send(function(resp, err)
        if err then return end
        local status = (resp and resp.getStatus) and resp:getStatus() or 0
        if status ~= 200 then return end
        local content = resp:getJson()
        local s = content and content.suggestions
        if type(s) ~= "table" then return end
        local list = {}
        for i = 1, #s do
            list[#list + 1] = { label = s[i].label or s[i].line or "", line = s[i].line or s[i].label or "" }
        end
        if cb then pcall(cb, list) end
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

-- OPORD execution report: the protectposition aiscript raises AIChat.opord_order_event with
-- "event=arrived|lease=<id>" (or failed/interrupted) → POST observed execution to the bridge so the lease/task
-- state is grounded in what the ship actually did. save_id rides AI_Influence._saveId (set on the relations tick).
function AI_Influence.OpordOrderEvent(param)
    local req = newRequest("POST"); if not req then return end
    local ctx = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "="); if eq then ctx[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    if not ctx.lease or ctx.lease == "" then return end
    local body = { save_id = AI_Influence._saveId or "unindexed", lease_id = ctx.lease,
                   event = ctx.event or "interrupted", evidence = { reason = ctx.reason or "" } }
    req:setUrl(BRIDGE_URL .. "/v1/opord/order_event")
    req:setBody((json and json.encode) and json.encode(body) or body)
    req:send(function(_, err) if err then log("opord order_event err: " .. tostring(err)) end end)
end
local function onOpordOrderEvent(_, param) AI_Influence.OpordOrderEvent(param) end

-- OPORD issuer (Phase D): poll the bridge for tasks awaiting a real ship order, relay each to the MD issuer
-- (aic_opord_execution.xml On_Assign) which finds a faction ship + create_orders our protectposition aiscript.
function AI_Influence.PollOpordOrders(saveId)
    -- (#70 TEMP info logs stripped 2026-07-02 per D; ERROR logs kept — silent-early-return lesson stands)
    local req = newRequest("POST"); if not req then log("opord poll: djfhe request unavailable") return end
    req:setUrl(BRIDGE_URL .. "/v1/opord/orders/pending")
    req:setBody((json and json.encode) and json.encode({ save_id = saveId or "unindexed" }) or { save_id = saveId })
    req:send(function(resp, err)
        if err then log("opord poll err: " .. tostring(err)) return end
        local content, jerr
        if resp and resp.getJson then content, jerr = resp:getJson() end
        if jerr or not content or not content.pending or not AddUITriggeredEvent then
            log("opord poll: unusable response jerr=" .. tostring(jerr) .. " hasPending=" .. tostring(content and content.pending ~= nil))
            return
        end
        for _, t in ipairs(content.pending) do
            if type(t) == "table" and t.task_id then
                AddUITriggeredEvent("ai_influence", "opord_assign", { operation_id = t.operation_id,
                    task_id = t.task_id, faction = t.faction, sector = t.sector, priority = t.priority,
                    stance = t.stance or "defensive" })
            end
        end
    end)
end

-- #75 G3: contract offers — poll the bridge for player-eligible OPEN jobs, materialize/withdraw mission offers
-- via MD (aic_contracts.xml). NEW job → 'contract_offer' ui event; job gone (claimed by NPC / cancelled /
-- repriced+reposted) → 'contract_withdraw'. Every silent early-return logs (the #70b lesson).
function AI_Influence.PollContractOffers(saveId)
    local req = newRequest("POST"); if not req then log("contract poll: djfhe request unavailable") return end
    req:setUrl(BRIDGE_URL .. "/v1/jobs/offers")
    req:setBody((json and json.encode) and json.encode({ save_id = saveId or "unindexed" }) or { save_id = saveId })
    req:send(function(resp, err)
        if err then log("contract poll err: " .. tostring(err)) return end
        local content, jerr
        if resp and resp.getJson then content, jerr = resp:getJson() end
        if jerr or not content or not content.offers or not AddUITriggeredEvent then
            log("contract poll: unusable response jerr=" .. tostring(jerr))
            return
        end
        AI_Influence._contracts = AI_Influence._contracts or {}
        local seen = {}
        for _, o in ipairs(content.offers) do
            if type(o) == "table" and o.job_id then
                seen[o.job_id] = true
                -- G5 repricing: tracker stores the REWARD (was just `true`). A FRAGO escalation raise changes
                -- the bridge reward; the stale on-screen offer is withdrawn and re-offered at the new price.
                local prev = AI_Influence._contracts[o.job_id]
                if prev ~= nil and prev ~= true and tonumber(prev) ~= tonumber(o.reward or 0) then
                    AI_Influence._contracts[o.job_id] = nil
                    AddUITriggeredEvent("ai_influence", "contract_withdraw", { job_id = o.job_id })
                    log("contract reprice -> withdraw job=" .. tostring(o.job_id) ..
                        " " .. tostring(prev) .. " -> " .. tostring(o.reward))
                end
                if not AI_Influence._contracts[o.job_id] then
                    AI_Influence._contracts[o.job_id] = tonumber(o.reward or 0) or true
                    local mtypes = { patrol = "fight", escort = "fight", privateer = "destroy",
                                     bounty = "destroy", supply = "deliver", recon = "find" }
                    -- real objective verbs (objective.custom without customaction threw 'null is not a
                    -- string' in create_offer — the diag correlation Ken's board proved; enums verified in md.xsd)
                    local otypes = { patrol = "patrol", escort = "escort", privateer = "destroy",
                                     bounty = "destroy", supply = "deliver", recon = "find" }
                    AddUITriggeredEvent("ai_influence", "contract_offer", {
                        -- reward in CREDITS: MD casts via (1Cr * N) = N Cr (proven in-game across 3 builds;
                        -- only a RAW float with no money cast displays /100 — never multiply here)
                        job_id = o.job_id, faction = o.faction, reward = (o.reward or 0),
                        job_type = o.job_type or "contract",
                        urgency = (o.urgency or 3),
                        -- A2: the assessed threatened asset the escort exists to protect (bind by name in MD)
                        bind_name = o.bind_name,
                        -- A4: the mission task verb — MD gates gameplay by VERB, not job type
                        task_verb = (o.task_verb or "patrol"),
                        -- R8: the ware bill for deliver contracts
                        ware = o.ware,
                        -- A5(e): bridge-computed SAFE destination sector for evacuations
                        safe_sector = o.safe_sector,
                        mtype = mtypes[tostring(o.job_type or "")] or "fight",
                        -- vanilla-style sentence case ("Ministry Escort Contract"), not ALL CAPS (Ken 2026-07-01)
                        title = tostring(o.faction_name or o.faction or "Faction") .. " " ..
                                (tostring(o.job_type or "contract"):gsub("^%l", string.upper)) .. " Contract",
                        -- the five-paragraph order (SMESC) IS the briefing; the OBJECTIVE is the element's task
                        summary = o.briefing or o.summary,
                        task = o.task, otype = otypes[tostring(o.job_type or "")] or "custom",
                        sector = o.target_sector, target = o.target_faction })
                    log("contract offer -> MD job=" .. tostring(o.job_id) ..
                        " task?" .. tostring(o.task ~= nil) .. " briefing?" .. tostring(o.briefing ~= nil) ..
                        " LUAV=3")  -- G3 diag: which Lua version is live + does the bridge payload carry task
                end
            end
        end
        for jid, _ in pairs(AI_Influence._contracts) do
            if not seen[jid] then
                AI_Influence._contracts[jid] = nil
                AddUITriggeredEvent("ai_influence", "contract_withdraw", { job_id = jid })
                log("contract withdraw -> MD job=" .. tostring(jid))
            end
        end
    end)
end

-- MD reports the player ACCEPTED a contract offer → claim the job on the bridge (FCFS lock).
function AI_Influence.ContractClaimed(param)
    local job = string.match(tostring(param or ""), "job=([^|]*)")
    if not job or job == "" then log("contract claim: no job id in param") return end
    local req = newRequest("POST"); if not req then log("contract claim: djfhe request unavailable") return end
    req:setUrl(BRIDGE_URL .. "/v1/jobs/claim")
    local payload = { save_id = AI_Influence._saveId or "unindexed", job_id = job, claimant = "player" }
    req:setBody((json and json.encode) and json.encode(payload) or payload)
    req:send(function(resp, err)
        if err then log("contract claim err: " .. tostring(err)) return end
        -- #146 REVOCATION HANDSHAKE (the ghost-escort lesson): the bridge is the FUNDING truth. If the claim
        -- did not lock an OPEN row (cancelled/expired/taken between offer and accept), tell MD to revoke the
        -- mission gracefully — the player must never fly an unfunded contract.
        local ok_claim = false
        if resp and resp.getJson then
            local content = resp:getJson()
            ok_claim = (content ~= nil) and (content.ok == true)
        end
        if (not ok_claim) and AddUITriggeredEvent then
            AddUITriggeredEvent("ai_influence", "contract_revoked", { job_id = job })
            log("contract claim REFUSED by bridge -> revoke job=" .. tostring(job))
        end
    end)
end
local function onContractClaimed(_, param) AI_Influence.ContractClaimed(param) end

-- MD reports the player ABORTED an accepted contract → release the claim (job reopens on the market).
function AI_Influence.ContractAborted(param)
    local job = string.match(tostring(param or ""), "job=([^|]*)")
    if not job or job == "" then log("contract abort: no job id in param") return end
    -- forget it locally so the next offers poll re-offers it as a fresh contract
    if AI_Influence._contracts then AI_Influence._contracts[job] = nil end
    local req = newRequest("POST"); if not req then log("contract abort: djfhe request unavailable") return end
    req:setUrl(BRIDGE_URL .. "/v1/jobs/release")
    local payload = { save_id = AI_Influence._saveId or "unindexed", job_id = job, claimant = "player" }
    req:setBody((json and json.encode) and json.encode(payload) or payload)
    req:send(function(_, err) if err then log("contract abort err: " .. tostring(err)) end end)
end
local function onContractAborted(_, param) AI_Influence.ContractAborted(param) end

-- MD reports the mission COMPLETED (RML end-feedback success) → vetted payout on the bridge (G4).
function AI_Influence.ContractCompleted(param)
    local job = string.match(tostring(param or ""), "job=([^|]*)")
    if not job or job == "" then log("contract complete: no job id in param") return end
    if AI_Influence._contracts then AI_Influence._contracts[job] = nil end
    local req = newRequest("POST"); if not req then log("contract complete: djfhe request unavailable") return end
    req:setUrl(BRIDGE_URL .. "/v1/job/complete")
    local payload = { save_id = AI_Influence._saveId or "unindexed", job_id = job, claimant = "player",
                      evidence = { source = "md_mission_ended", game_time = getElapsedTime and getElapsedTime() or 0 } }
    req:setBody((json and json.encode) and json.encode(payload) or payload)
    req:send(function(_, err) if err then log("contract complete err: " .. tostring(err)) end end)
end
local function onContractCompleted(_, param) AI_Influence.ContractCompleted(param) end

-- W2 (#148): MD reports how many rebuild job slots were activated for a build order → bridge marks
-- placed / place_failed (reserve releases on failure).
function AI_Influence.BuildPlaced(param)
    local order = string.match(tostring(param or ""), "order=([^|]*)")
    local found = tonumber(string.match(tostring(param or ""), "found=([^|]*)") or "0") or 0
    if not order or order == "" then log("build_placed: no order id in param") return end
    local req = newRequest("POST"); if not req then log("build_placed: djfhe request unavailable") return end
    req:setUrl(BRIDGE_URL .. "/v1/build/placed")
    local payload = { save_id = AI_Influence._saveId or "unindexed", order_id = order, found = found }
    req:setBody((json and json.encode) and json.encode(payload) or payload)
    req:send(function(_, err) if err then log("build_placed err: " .. tostring(err)) end end)
    log("build_placed order=" .. tostring(order) .. " found=" .. tostring(found))
end
local function onBuildPlaced(_, param) AI_Influence.BuildPlaced(param) end

-- MD issued a real create_order → record the lease on the bridge, then mark the order issued (chained POSTs).
function AI_Influence.OpordIssued(param)
    local ctx = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "="); if eq then ctx[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    local sid = AI_Influence._saveId or "unindexed"
    local lreq = newRequest("POST"); if not lreq then return end
    lreq:setUrl(BRIDGE_URL .. "/v1/opord/lease")
    lreq:setBody((json and json.encode) and json.encode({ save_id = sid, operation_id = ctx.op, task_id = ctx.task,
        faction = ctx.faction, ship_runtime_id = ctx.ship, ship_name = ctx.name, sector = ctx.sector,
        order_kind = "protectposition", priority = 1 }) or {})
    lreq:send(function(resp, err)
        if err then return end
        local content; if resp and resp.getJson then content = resp:getJson() end
        if not content or not content.lease_id then return end
        local iss = newRequest("POST"); if not iss then return end
        iss:setUrl(BRIDGE_URL .. "/v1/opord/orders/issued")
        iss:setBody((json and json.encode) and json.encode({ save_id = sid, lease_id = content.lease_id,
            assigned_order_id = "protectposition" }) or {})
        iss:send(function(_, e2) if e2 then log("opord issued err: " .. tostring(e2)) end end)
    end)
end
local function onOpordIssued(_, param) AI_Influence.OpordIssued(param) end

-- No ship available → record a durable force-quota request on the bridge (the spec's path 2).
function AI_Influence.OpordForceRequest(param)
    local ctx = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "="); if eq then ctx[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    local req = newRequest("POST"); if not req then return end
    req:setUrl(BRIDGE_URL .. "/v1/opord/force_request")
    req:setBody((json and json.encode) and json.encode({ save_id = AI_Influence._saveId or "unindexed",
        operation_id = ctx.op, task_id = ctx.task, faction = ctx.faction, sector = ctx.sector or "",
        ship_role = ctx.role or "patrol", priority = 1 }) or {})
    req:send(function(_, err) if err then log("opord force_request err: " .. tostring(err)) end end)
end
local function onOpordForceRequest(_, param) AI_Influence.OpordForceRequest(param) end

-- ---- sync-on-load: push the game's ACTUAL faction relations so the DB mirrors reality -----------
-- MD raises "AIChat.sync_relations" with "save_id=<sid>||idA~idB~rel;idA~idB~rel;..." on game load.
function AI_Influence.SyncRelations(param)
    local req = newRequest("POST")
    if not req then return end
    local sid, body = string.match(tostring(param or ""), "save_id=([^|]*)||(.*)")
    sid = (sid ~= nil and sid ~= "") and sid or "unindexed"
    AI_Influence._saveId = sid   -- cache for callers w/o a save_id (e.g. OPORD order-event reports)
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
    if AI_Influence._econTick == 1 or (AI_Influence._econTick % 8 == 0) then AI_Influence.SyncEconomy(sid); AI_Influence.SyncFleets(sid); AI_Influence.SyncLogbook(sid); AI_Influence.SyncFactions(sid); AI_Influence.SyncNpcCensus(sid) end
    if AI_Influence._econTick % 4 == 0 then AI_Influence.SyncInfluence(sid) end
    -- SPEC 1j: drain prominent faction->player comms ~every other tick (cheap GET; comms are rare + cooldown'd).
    if AI_Influence._econTick % 2 == 0 then AI_Influence.DrainPlayerComms(sid) end
    -- Deceased sweep ~every 16th tick (~4 min); cheap + threshold-protected (won't false-mark mid-cycle).
    if AI_Influence._econTick % 16 == 0 then AI_Influence.SweepDeceased(sid) end
    -- OPORD pipeline ~every 8th tick (~2 min). #70: STAGGERED off the %8==0 burst (5 sync calls fire there) so
    -- the OPORD requests aren't the tail of a 7-request burst; offsets keep the same cadence.
    if AI_Influence._econTick % 8 == 3 then AI_Influence.AdvanceOperations(sid) end
    -- OPORD execution issuer: poll tasks awaiting a real ship order → MD finds ship + create_order.
    if AI_Influence._econTick % 8 == 5 then AI_Influence.PollOpordOrders(sid) end
    -- #75 G3: contract offers — own tick offset (de-burst rule, #70b).
    if AI_Influence._econTick % 8 == 1 then AI_Influence.PollContractOffers(sid) end
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
                        -- #27 contract_frago fields: amend the player's LIVE accepted mission (MD Frago_dispatch)
                        if a.job_id then tp.job_id = tostring(a.job_id) end
                        if a.summary then tp.summary = tostring(a.summary) end
                        -- W2 (#148) build_place fields: activate rebuild job slots (md/aic_warindustry.xml)
                        if a.order_id then tp.order_id = tostring(a.order_id) end
                        if a.size then tp.size = tostring(a.size) end
                        if a.count ~= nil then tp.count = tonumber(a.count) or 1 end
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
                -- M5: keep the param3 table SMALL (4 keys). X4's AddUITriggeredEvent->event.param3 round-trip
                -- can silently drop keys past a small count; after switching to write_incoming_message we no
                -- longer need faction/category here, so carry only what the cue uses. (sender_npc_key/tx_id for
                -- the M5b-2 Reply hook will ride a SEPARATE event to avoid the cap.)
                local tp = {
                    title = tostring(c.title or "Incoming Transmission"),
                    body = tostring(c.body or ""),
                    sender = tostring(c.sender_name or ""),
                    priority = tostring(c.priority or "low"),
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

-- ---- NPC census: per-faction station MANAGER + SHIPTRADER persons, round-robin (the live roster) -----------
-- #98 / I6 (T2): populate the roster with talk-able OPERATIONAL NPCs WITHOUT a chat, gradually. A station's
-- commanding person is GetComponentData(st,"tradenpc") (the manager) + "shiptrader" — GROUNDED on the vanilla UI
-- (ego_detailmonitor/menu_map.lua:14440, menu_docked.lua:3787). The prior MD `manager`/`controlentity` guesses
-- were empty because those are NOT the property (Lua-FFI `tradenpc` is). Round-robin ONE faction + a bounded slice
-- per call (same throttle as SyncEconomy) so the UI-thread C-API never stutters. Entries are keyed sid|chat|name
-- (= make_key(save,"chat",name)) so a censused manager and a LATER chat unify on ONE card (no duplicate). Generic
-- ship crew (T3) stay LAZY — indexed on interaction — per the spec (don't dump thousands of crew).
local NPC_STATION_CAP = 12   -- per faction PER TICK (small: ALL 12 factions advance each tick, so every NPC's
local NPC_SHIP_CAP = 12      -- last_active refreshes once per full cycle — required for the deceased sweep).
-- Sector NAME from any object: GetComponentData(obj,"sector") returns a cdata component; passing it straight
-- back throws "Invalid argument got cdata", so normalise via ConvertStringToLuaID first (same fix as SyncFleets).
local function aic_sectorName(comp)
    local sec = ""
    pcall(function()
        local sc = GetComponentData(comp, "sector")
        if sc then sec = tostring(GetComponentData(ConvertStringToLuaID(tostring(sc)), "name") or "") end
    end)
    return sec
end
-- ALL FACTIONS each tick (small per-faction caps + per-faction cursors `_npcStOff`/`_npcShOff`). Every NPC's
-- last_active thus refreshes once per full cycle, so the bridge deceased-sweep can treat "not re-seen for > a
-- cycle" as gone (its ship/station was destroyed). Ground truth galaxy-wide — GetContained* is NOT fog-of-war
-- gated (proven by SyncFleets reporting fleets for factions the player is nowhere near).
function AI_Influence.SyncNpcCensus(saveId)
    local sid = (saveId and saveId ~= "") and saveId or "unindexed"
    AI_Influence._npcStOff = AI_Influence._npcStOff or {}
    AI_Influence._npcShOff = AI_Influence._npcShOff or {}
    local npcs = {}
    local function addPerson(pid, fid, secname, defrole)
        if pid == nil then return end
        local p = pid
        pcall(function() if ConvertIDTo64Bit then p = ConvertIDTo64Bit(pid) end end)
        local nm, post
        pcall(function() nm, post = GetComponentData(p, "name", "postname") end)
        nm = nm and tostring(nm) or ""
        if nm ~= "" then
            npcs[#npcs + 1] = {
                npc_key = sid .. "|chat|" .. nm,          -- = make_key(save,"chat",name): unify w/ chat card
                name = nm, faction_id = fid,
                role = (post and tostring(post) ~= "") and tostring(post) or defrole,
                sector = secname or "",
            }
        end
    end
    for _, fid in ipairs(ECON_FACTIONS) do
        -- stations: manager (tradenpc) + shiptrader
        pcall(function()
            local stations = GetContainedStationsByOwner(fid, nil, true)
            local total = (type(stations) == "table") and #stations or 0
            if total == 0 then AI_Influence._npcStOff[fid] = 0; return end
            local off = AI_Influence._npcStOff[fid] or 0
            if off >= total then off = 0 end
            local last = math.min(off + NPC_STATION_CAP, total)
            for i = off + 1, last do
                local st = stations[i]
                local secname = aic_sectorName(st)
                local tradenpc, shiptrader
                pcall(function() tradenpc, shiptrader = GetComponentData(st, "tradenpc", "shiptrader") end)
                addPerson(tradenpc, fid, secname, "manager")
                addPerson(shiptrader, fid, secname, "shiptrader")
            end
            AI_Influence._npcStOff[fid] = (last >= total) and 0 or last
        end)
        -- ships: captains of SIGNIFICANT ships only (capitals ship_l/xl + trade/mine/build; fighters stay lazy T3)
        pcall(function()
            local objs = GetContainedObjectsByOwner(fid)        -- single-arg = galaxy-wide (per SyncFleets canon)
            if type(objs) ~= "table" then AI_Influence._npcShOff[fid] = 0; return end
            local ships = {}
            for _, obj in ipairs(objs) do
                pcall(function()
                    local macro = GetComponentData(obj, "macro")
                    if macro and macro ~= "" then
                        local mc = tostring(ffi.string(C.GetMacroClass(macro)) or "")
                        if mc:sub(1, 5) == "ship_" then
                            local sz = mc:sub(6)
                            local pp = tostring(GetComponentData(obj, "primarypurpose") or "")
                            if sz == "l" or sz == "xl" or pp == "trade" or pp == "mine" or pp == "build" then
                                ships[#ships + 1] = obj
                            end
                        end
                    end
                end)
            end
            local total = #ships
            if total == 0 then AI_Influence._npcShOff[fid] = 0; return end
            local off = AI_Influence._npcShOff[fid] or 0
            if off >= total then off = 0 end
            local last = math.min(off + NPC_SHIP_CAP, total)
            for i = off + 1, last do
                local sh = ships[i]
                local cap
                pcall(function() cap = GetComponentData(sh, "pilot") end)
                addPerson(cap, fid, aic_sectorName(sh), "captain")
            end
            AI_Influence._npcShOff[fid] = (last >= total) and 0 or last
        end)
    end
    if #npcs > 0 then
        local req = newRequest("POST")
        if req then
            local body = { save_id = sid, game_id = "chat", player = { name = "Player" }, npcs = npcs }
            req:setUrl(BRIDGE_URL .. "/v1/npcs/index")
            req:setBody((json and json.encode) and json.encode(body) or body)
            req:send(function(_, err) if err then log("npccensus err: " .. tostring(err)) end end)
        end
        log("npccensus all-factions npcs=" .. tostring(#npcs))
    end
end

-- ---- deceased sweep: mark/prune NPCs the census stopped seeing (their ship/station died) ----------
-- Cheap GET; the bridge does one bounded query (stale_seconds threshold > a full census cycle, so a faction
-- not yet re-reached this cycle is NOT falsely marked). Known NPCs -> deceased (memory kept); generic -> pruned.
function AI_Influence.SweepDeceased(saveId)
    local req = newRequest("GET")
    if not req then return end
    req:setUrl(BRIDGE_URL .. "/api/memory/sweep_deceased?save_id=" .. tostring(saveId or "unindexed"))
    req:send(function(_, err) if err then log("sweep err: " .. tostring(err)) end end)
end

-- ---- OPORD pipeline: drive operations forward one heartbeat at a time -------------------------------
-- Cheap GET to the bridge pipeline driver (advance = recognize threats → mission analysis → …future phases).
-- The bridge aggregates real hostile_events into ONE deduped operation per threat and advances its lifecycle.
-- No player surface yet (narrator is a later OPORD phase), so this can run silently while we build the chain.
function AI_Influence.AdvanceOperations(saveId)
    local req = newRequest("GET")
    if not req then return end
    req:setUrl(BRIDGE_URL .. "/api/ops/advance?save_id=" .. tostring(saveId or "unindexed"))
    req:send(function(_, err) if err then log("opord advance err: " .. tostring(err)) end end)
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
                -- P1 (#113): refresh the choice buttons from the now-extended conversation (the loop).
                if menu.requestSuggestions then menu.requestSuggestions() end
                -- C2 v2 regression fix (Ken 2026-07-05): the NATIVE wheel's labels must stay contextual
                -- too — re-request the batch on EVERY reply so MD State ($l1..$t3) carries conversation-
                -- aware lines for the next wheel render (was: refreshed only on Speak_menu open).
                if AI_Influence.RequestSuggestions and menu.currentContext then
                    pcall(AI_Influence.RequestSuggestions,
                          "faction_id=" .. tostring(menu.currentContext.faction or "")
                          .. "|target_name=" .. tostring(menu.currentContext.target or "")
                          .. "|save_id=" .. tostring(menu.currentContext.save_id or ""))
                end
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
        -- player2_client.npc_complete -> rebind_session). Read macro/sector DIRECTLY here as a fallback so
        -- it does not depend on AIChat.npc_skills having fired before AIChat.open (event-order independent).
        if (not AI_Influence._pendingNpcMacro) and AI_Influence._pendingNpcId then
            pcall(function()
                local pid3 = ConvertStringToLuaID(tostring(AI_Influence._pendingNpcId))
                local mc; pcall(function() mc = GetComponentData(pid3, "macro") end)
                if mc ~= nil and tostring(mc) ~= "nil" and tostring(mc) ~= "" then AI_Influence._pendingNpcMacro = tostring(mc) end
                local sc; pcall(function() sc = GetComponentData(pid3, "sector") end)
                if sc ~= nil and tostring(sc) ~= "nil" and tostring(sc) ~= "" then AI_Influence._pendingNpcSector = tostring(sc) end
            end)
        end
        if AI_Influence._pendingNpcMacro then context["macro"] = AI_Influence._pendingNpcMacro end
        if AI_Influence._pendingNpcSector and not context["sector"] then context["sector"] = AI_Influence._pendingNpcSector end
        if AI_Influence._pendingNpcId then context["runtime_component_id"] = tostring(AI_Influence._pendingNpcId) end
        log("AIChat.open folded identity evidence => macro=" .. tostring(AI_Influence._pendingNpcMacro)
            .. " runtime=" .. tostring(AI_Influence._pendingNpcId) .. " sector=" .. tostring(context["sector"]))
        -- EPIC I probe: test Blackboard durable identity on this conversation NPC (guarded; records to bridge).
        pcall(function() AI_Influence.BlackboardProbe(context) end)
        -- BUGFIX (2026-06-28): the window transcript (termMenu.history) is per-window and was NEVER reset,
        -- so it accumulated EVERY NPC's turns and display() relabeled them with whoever you now talk to.
        -- Reset the VISIBLE transcript when the conversation partner CHANGES. Bridge memory stays isolated
        -- per NPC (separate npc_key), and the new NPC's recall still rides via the LLM — this only clears
        -- the on-screen history. Same-NPC re-entry keeps its transcript.
        local _newTarget = context["target_name"] or context["$target_name"] or "Faction Officer"
        if (not termMenu.currentContext) or termMenu.currentContext.target ~= _newTarget then
            termMenu.history = {}
        end
        termMenu.currentContext = {
            faction = context["faction_id"] or context["$faction_id"] or "argon",
            target  = context["target_name"] or context["$target_name"] or "Faction Officer",
            -- Per-save id from MD (Save_identity.$save_uuid). Keys bridge memory/chat to THIS
            -- playthrough so a new game starts fresh. nil if MD didn't send it (bridge falls back).
            save_id = context["save_id"] or context["$save_id"],
            full_context = context,
        }
        -- P1 (#113): a fresh conversation starts in CHOICE mode (not typing); presets show instantly and
        -- the LLM batch arrives via FetchSuggestions. Reset per open so a new NPC doesn't inherit stale choices.
        termMenu.typing = false
        termMenu.suggestions = {}
        if termMenu.requestSuggestions then termMenu.requestSuggestions() end
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
    -- C2 v3 (Ken 2026-07-05): wheel option 4 SUMMONS the input box (overlay is output-only otherwise).
    RegisterEvent("AIChat.starttyping", function()
        local m = rawget(_G, "X4_Terminal_Menu")
        if m and m.startTyping then pcall(m.startTyping) end
    end)
    -- Lifecycle nesting (Ken 2026-07-05): when the CONVERSATION ends, the overlay ends with it —
    -- no orphaned chat window / input box after walking away or picking Back out.
    RegisterEvent("AIChat.close", function()
        local m = rawget(_G, "X4_Terminal_Menu")
        if m and m.active and m.closeMenu then pcall(m.closeMenu) end
    end)
    RegisterEvent("AIChat.poll", onPollTick)
    RegisterEvent("AIChat.index_npcs", onIndexNpcs)
    RegisterEvent("AIChat.suggest", onRequestSuggest)
    RegisterEvent("AIChat.relation_report", onReportRelation)
    RegisterEvent("AIChat.hostile_event", onReportHostile)
    RegisterEvent("AIChat.sync_relations", onSyncRelations)
    RegisterEvent("AIChat.npc_skills", onNpcSkills)
    RegisterEvent("AIChat.opord_order_event", onOpordOrderEvent)
    RegisterEvent("AIChat.opord_issued", onOpordIssued)
    RegisterEvent("AIChat.opord_force_request", onOpordForceRequest)
    RegisterEvent("AIChat.contract_claimed", onContractClaimed)
    RegisterEvent("AIChat.contract_aborted", onContractAborted)
    RegisterEvent("AIChat.contract_completed", onContractCompleted)
    RegisterEvent("AIChat.build_placed", onBuildPlaced)
    log("events registered: AIChat.open, AIChat.poll, AIChat.index_npcs, AIChat.suggest, AIChat.relation_report, AIChat.sync_relations, AIChat.npc_skills")
end
init()
