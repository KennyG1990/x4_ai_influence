---@diagnostic disable: undefined-global, need-check-nil, undefined-field
-- ============================================================================
-- AI INFLUENCE CHAT - HTTP Bridge Client (djfhe_http)
-- POST /v1/request  -> submit a player chat turn
-- GET  /v1/updates_pool -> drain completed replies, write to logbook
-- Poll is driven deterministically by an MD 1s loop raising "AIChat.poll".
-- ============================================================================

local LOAD_REVISION = "aichat-r1"
local BRIDGE_URL = "http://127.0.0.1:8713"
-- ADR-009 single-mod migration: EVERY bridge lane is gated by this master switch. Default true while
-- systems re-home; the cutover flips it false and the mod runs fully serverless. Toggle at runtime via
-- AI_Influence.SetBridgeEnabled(false) for clean serverless testing (kills the D-B transport contention).
AI_Influence = AI_Influence or {}
AI_Influence.BRIDGE_ENABLED = false  -- CUTOVER 2026-07-21: Ken disabled the neural_link extension; all 28 lanes dormant until re-homed
function AI_Influence.SetBridgeEnabled(b) AI_Influence.BRIDGE_ENABLED = (b == true) end
-- P1 (serverless slice): call Player2 DIRECTLY, no Python bridge in the path. Proven 2026-07-21:
-- POST :4315/v1/chat/completions returns a standard OpenAI completion SYNCHRONOUSLY (~1.1s), so the
-- direct lane needs no poll loop. The game-key identifies our registered Player2 mod ("X4 Ai_Influence").
local PLAYER2_URL = "http://127.0.0.1:4315"
local PLAYER2_GAME_KEY = "019bc2c3-f234-74bd-a4e3-ebdb6092f5ec"

-- U2 backend selection (#198): the docs require BYO backend (Player2 / OpenRouter / DeepSeek / Ollama /
-- KoboldCpp). All are OpenAI-shaped /v1/chat/completions; only base URL + auth + model differ. Player enters
-- their OWN key in the (future) options menu — the mod never hardcodes cloud keys. Default = Player2 (current
-- behavior, so nothing regresses). auth: "player2" (game-key header) | "bearer" (Authorization: Bearer <key>)
-- | "none" (local servers). base/model/key are overridable at runtime by the menu via AI_Influence.backendSet.
local BACKENDS = {
    player2   = { base = PLAYER2_URL,                 path = "/v1/chat/completions", auth = "player2", key = PLAYER2_GAME_KEY, model = "" },
    openrouter= { base = "https://openrouter.ai/api", path = "/v1/chat/completions", auth = "bearer",  key = "", model = "" },
    deepseek  = { base = "https://api.deepseek.com",  path = "/v1/chat/completions", auth = "bearer",  key = "", model = "deepseek-chat" },
    ollama    = { base = "http://127.0.0.1:11434",    path = "/v1/chat/completions", auth = "none",    key = "", model = "llama3" },
    koboldcpp = { base = "http://127.0.0.1:5001",     path = "/v1/chat/completions", auth = "none",    key = "", model = "" },
}
AI_Influence = AI_Influence or {}
AI_Influence.backendProvider = AI_Influence.backendProvider or "player2"
AI_Influence.backendOverride = AI_Influence.backendOverride or {}   -- { base=, model=, key= } from the options menu

-- Menu/config setter (the options menu calls this; player supplies endpoint/model/key for their chosen provider).
function AI_Influence.backendSet(provider, override)
    if provider and BACKENDS[provider] then AI_Influence.backendProvider = provider end
    if type(override) == "table" then
        AI_Influence.backendOverride = AI_Influence.backendOverride or {}
        for _, k in ipairs({ "base", "model", "key" }) do
            if override[k] ~= nil then AI_Influence.backendOverride[k] = override[k] end
        end
    end
end

-- Parse the MD-pushed config string "provider=..|base=..|model=..|key=.." into a table (#209).
function AI_Influence.parseBackendConfig(param)
    local g = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "=")
        if eq then g[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    return g
end
-- Set the active backend AND ask MD to persist it in the save (survives reload). The options menu calls this;
-- the Lua->MD hop is the same event_ui_triggered path Store_card uses (proven).
function AI_Influence.backendSetAndPersist(provider, override)
    AI_Influence.backendSet(provider, override)
    local o = AI_Influence.backendOverride or {}
    if AddUITriggeredEvent then
        pcall(function()
            AddUITriggeredEvent("ai_influence", "backend_persist", {
                provider = tostring(AI_Influence.backendProvider or "player2"),
                base = tostring(o.base or ""), model = tostring(o.model or ""), key = tostring(o.key or ""),
            })
        end)
    end
end

-- Resolve the ACTIVE backend = preset + player overrides. Returns { url, auth, key, model }.
function AI_Influence.ActiveBackend()
    local p = AI_Influence.backendProvider or "player2"
    local b = BACKENDS[p] or BACKENDS.player2
    local o = AI_Influence.backendOverride or {}
    local base = (o.base and o.base ~= "") and o.base or b.base
    return {
        provider = p,
        url = base .. b.path,
        auth = b.auth,
        key = (o.key and o.key ~= "") and o.key or b.key,
        model = (o.model and o.model ~= "") and o.model or b.model,
    }
end

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
    -- #224: prefer the mod's OWN baked-in transport (aic_http.lua, no external HTTP-mod dependency)
    local own = rawget(_G, "AIC_HTTP")
    if own and own.initLibs and own.initLibs() then
        Request = own
        if not json then json = own.json() end
        log("transport=aic_http (built-in)")
        return true
    end
    -- fallback: the external djfhe_http extension, if present
    local ok_r, req = pcall(require, "djfhe.http.request")
    if ok_r and req then Request = req end
    if not json then local ok_j, js = pcall(require, "jsonlua.json"); if ok_j then json = js end end
    if Request then log("transport=djfhe (external fallback)") end
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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

-- ---- P1 direct Player2 lane (serverless): messages[] -> :4315 chat/completions -> reply ----
-- callback(ok, replyText, usage, err). Synchronous upstream: the reply is in this callback, no poll.
-- messages = { {role="system",content=...}, {role="user",content=...}, ... } (OpenAI shape).
function AI_Influence.SendDirect(messages, opts, callback)
    opts = opts or {}
    local req = newRequest("POST")
    if not req then
        if callback then callback(false, nil, nil, "djfhe request module missing") end
        return
    end
    local be = AI_Influence.ActiveBackend()
    local body = { messages = messages }
    if be.model and be.model ~= "" then body.model = be.model end
    if opts.max_tokens then body.max_tokens = opts.max_tokens end
    if opts.temperature then body.temperature = opts.temperature end
    if opts.response_format then body.response_format = opts.response_format end
    req:setUrl(be.url)
    if req.addHeader then
        pcall(function() req:addHeader("Content-Type", "application/json") end)  -- all: strict JSON (Player2 415s without)
        if be.auth == "player2" then
            pcall(function() req:addHeader("player2-game-key", be.key) end)
        elseif be.auth == "bearer" and be.key and be.key ~= "" then
            pcall(function() req:addHeader("Authorization", "Bearer " .. be.key) end)
        end
    end
    req:setBody((json and json.encode) and json.encode(body) or body)
    if req.setTimeout then req:setTimeout(90) end   -- LLM completions can be slow on big models (Ken hit 30s live)
    log("SendDirect [" .. tostring(be.provider) .. "] msgs=" .. tostring(#messages))
    req:send(function(resp, err)
        if err then
            if callback then callback(false, nil, nil, "HTTP Error: " .. tostring(err)) end
            return
        end
        local status = (resp and resp.getStatus) and resp:getStatus() or 0
        if status ~= 200 then
            if callback then callback(false, nil, nil, "HTTP Status " .. tostring(status)) end
            return
        end
        local content, jerr = resp:getJson()
        if jerr or not content then
            if callback then callback(false, nil, nil, "bad JSON from Player2") end
            return
        end
        local reply, usage = nil, content.usage
        local ch = content.choices
        if type(ch) == "table" and ch[1] and ch[1].message then reply = ch[1].message.content end
        if not reply or reply == "" then
            if callback then callback(false, nil, usage, "empty completion") end
            return
        end
        log("SendDirect <= " .. tostring(usage and usage.total_tokens or "?") .. " tok reply len=" .. tostring(#reply))
        if callback then callback(true, reply, usage, nil) end
    end)
end

-- ---- P1/P2 memory card (serverless): per-NPC card persisted IN THE SAVE via MD state --------
-- The card is a Lua table serialized to JSON. Store rides a 2-key event table (safe under the param3
-- truncation cap); the load response comes back as a JSON string on the AIChat.card_loaded event.
-- Single-flight load: the pending callback + token are stashed (one NPC conversation at a time).
-- P2 (#194): schema v2 — version + checksum + migration + weighted caps + provenance facts.
-- SAVE ISOLATION is free by construction: Cards.$store lives INSIDE each save file.
AI_Influence._pendingCardCb = nil
AI_Influence._pendingCardToken = nil

local CARD_SCHEMA_V = 3
local CARD_MAX_TURNS = 8
local CARD_MAX_FACTS = 200
local CARD_MAX_IMPORTANT = 64
local CARD_MAX_BYTES = 6000
local CARD_IMPORTANT_CATEGORIES = { promise = true, secret = true, preference = true, relationship = true }
local CARD_PROVENANCE = { game_observed = true, player_claim = true, npc_claim = true, model_color = true }

-- U3 deterministic trust (#197): a per-NPC scalar moved by RULE-DRIVEN outcome flags, NEVER LLM-scored
-- (Bannerlord/Stardew lesson). Trust gates which stored facts are injected into the NPC's prompt, so a
-- low-trust NPC is guarded and a high-trust one opens up. Range clamped; persisted in the card (NOT in the
-- content checksum — it's mutable gameplay state).
local TRUST_MIN, TRUST_MAX = -100, 100
-- tier boundaries (index 0..3): guarded < 0 <= neutral < 25 <= friendly < 60 <= trusted
local TRUST_TIER_NAMES = { [0] = "guarded", [1] = "neutral", [2] = "friendly", [3] = "trusted" }
-- deterministic keyword tone -> trust delta per turn (rule-based classifier, no LLM)
local TRUST_HOSTILE = { "idiot", "fool", "scum", "worthless", "hate", "kill you", "threat", "stupid", "pathetic", "traitor", "coward" }
local TRUST_WARM = { "thank", "please", "appreciate", "friend", "respect", "grateful", "well done", "trust you", "help you" }

function AI_Influence.TrustTier(trust)
    trust = tonumber(trust) or 0
    if trust >= 60 then return 3 end
    if trust >= 25 then return 2 end
    if trust >= 0 then return 1 end
    return 0
end

function AI_Influence.AdjustTrust(card, delta)
    if type(card) ~= "table" then return 0 end
    local t = (tonumber(card.trust) or 0) + (tonumber(delta) or 0)
    if t > TRUST_MAX then t = TRUST_MAX elseif t < TRUST_MIN then t = TRUST_MIN end
    card.trust = t
    return t
end

-- deterministic tone -> delta from the player's message text (lowercased keyword match)
function AI_Influence.ToneTrustDelta(text)
    local low = string.lower(tostring(text or ""))
    for _, kw in ipairs(TRUST_HOSTILE) do if string.find(low, kw, 1, true) then return -8 end end
    for _, kw in ipairs(TRUST_WARM) do if string.find(low, kw, 1, true) then return 4 end end
    return 1  -- civil engagement earns slow rapport
end

-- ---- doc 06: Loyalty & Bond — deterministic personal bond, culture-colored, with decay ----------
-- Distinct from trust (will they SHARE): bond is personal CLOSENESS (0-100), grows with interaction at a
-- culture-modulated rate, decays when neglected, and gates warmer dialogue. No LLM for the state.
local BOND_MAX, BOND_MIN = 100, 0
local BOND_TIER_NAMES = { "a stranger", "an acquaintance", "a friendly contact", "a close confidant", "a deeply bonded companion" }
-- culture descriptor injected into the prompt (systems-doc 06 cultures)
local CULTURE = {
    argon = "pragmatic, direct, values competence", teladi = "profit-minded, cautious, warms slowly unless there is mutual gain",
    antigone = "pragmatic and independent", alliance = "principled and measured",
    paranid = "devout, formal, ritual matters", holyorder = "zealous and devout", ministry = "orthodox and hierarchical",
    split = "proud and aggressive, respects strength", freesplit = "fiercely independent and proud", scaleplate = "opportunistic and hard-edged",
    boron = "gentle, pacifist, warmed by kindness", terran = "disciplined, reserved, formal",
}
-- per-faction bond growth multiplier (culture pace)
local BOND_RATE = { teladi = 0.7, split = 0.8, freesplit = 0.8, scaleplate = 0.7, boron = 1.2, terran = 0.8, paranid = 0.9, holyorder = 0.9 }
function AI_Influence.BondTier(bond)
    bond = tonumber(bond) or 0
    if bond >= 80 then return 4 elseif bond >= 55 then return 3 elseif bond >= 30 then return 2 elseif bond >= 10 then return 1 end
    return 0
end
function AI_Influence.CultureDescriptor(faction)
    return CULTURE[tostring(faction or "")] or "even-tempered"
end
-- doc 06: bond GATES what the NPC will OFFER (parallel to how trust gates which facts are visible).
-- Deterministic tier -> behavioural directive; higher bond unlocks warmer, more committal offers.
local BOND_GATE = {
    [0] = "You barely know this player; stay transactional and volunteer nothing personal.",
    [1] = "You have dealt with this player before; be cordial but keep any help to routine matters.",
    [2] = "You regard this player as a friendly contact; you may volunteer minor tips or local gossip.",
    [3] = "You count this player as a close contact; you may offer real help and share faction rumours.",
    [4] = "This player is a deeply bonded companion; you may propose a standing arrangement or a personal favour.",
}
-- #217 doc-09: conversational fleet orders. Lua is the gate — an order is executed ONLY for a
-- player-OWNED ship captain (MD grounds npc_owned) and ONLY from the whitelist. The LLM proposes; we verify.
local PLAYER_ORDERS = { patrol = true, ["return"] = true, hold = true, attack = true, follow = true }
function AI_Influence.OrderAllowed(ctx, order)
    if type(ctx) ~= "table" then return false end
    if tostring(ctx.npc_owned or "") ~= "1" then return false end
    if not (ctx.npc_ship and tostring(ctx.npc_ship) ~= "") then return false end
    return PLAYER_ORDERS[tostring(order or "")] == true
end
function AI_Influence.BondGate(tier)
    tier = tonumber(tier) or 0
    if tier < 0 then tier = 0 elseif tier > 4 then tier = 4 end
    return BOND_GATE[tier]
end
-- doc 06: formal commitment — a standing pact recorded ON the card, gated behind the top bond tier.
-- Deterministic: Lua REFUSES to record a pact below the threshold even if the LLM proposes one.
function AI_Influence.CommitmentAllowed(tier) return (tonumber(tier) or 0) >= 4 end
function AI_Influence.HasCommitment(card)
    return type(card) == "table" and type(card.pact) == "table" and card.pact.kind ~= nil
end
function AI_Influence.RecordCommitment(card, kind, day)
    if type(card) ~= "table" then return false end
    card.pact = { kind = tostring(kind or "partnership"), day = tonumber(day) or 0 }
    return true
end
function AI_Influence.AddBond(card, delta, faction)
    if type(card) ~= "table" then return 0 end
    local rate = BOND_RATE[tostring(faction or "")] or 1.0
    local b = (tonumber(card.bond) or 0) + (tonumber(delta) or 0) * rate
    if b > BOND_MAX then b = BOND_MAX elseif b < BOND_MIN then b = BOND_MIN end
    card.bond = b
    return b
end
-- decay: bonds cool when neglected (-2/game-day since last interaction). Only when a prior day is stamped.
function AI_Influence.DecayBond(card, curDay)
    if type(card) ~= "table" then return 0 end
    local last = tonumber(card.bond_day) or 0
    curDay = tonumber(curDay) or 0
    if last > 0 and curDay > last then
        local b = (tonumber(card.bond) or 0) - (curDay - last) * 2
        card.bond = (b < BOND_MIN) and BOND_MIN or b
    end
    return card.bond or 0
end

-- a stored fact's minimum trust tier to be revealed, derived from its category (secrets stay hidden until trusted)
local function gateForCategory(c)
    if c == "secret" then return 2 end
    if c == "promise" or c == "relationship" then return 1 end
    return 0
end
local function factGateTier(f) return gateForCategory(f and f.c) end

-- U3: the top-K tier-VISIBLE facts (important first, then by weight), as a plain list of texts.
-- Extracted so the gating is unit-testable (a secret is withheld below tier 2).
function AI_Influence.VisibleFacts(card, tier, k)
    tier = tonumber(tier) or 0; k = k or 8
    local out = {}
    for _, m in ipairs(card.imp or {}) do if (tonumber(m.g) or 0) <= tier then out[#out + 1] = tostring(m.t) end end
    local vis = {}
    for _, f in ipairs(card.facts or {}) do if factGateTier(f) <= tier then vis[#vis + 1] = f end end
    table.sort(vis, function(a, b) return (tonumber(a.w) or 0) > (tonumber(b.w) or 0) end)
    for i = 1, math.min(k, #vis) do out[#out + 1] = tostring(vis[i].t) end
    return out
end

local function gameDay()
    local t = 0
    pcall(function() if GetCurrentGameTime then t = GetCurrentGameTime() end end)
    return math.floor((tonumber(t) or 0) / 3600)
end

-- djb2 over a CANONICAL projection of the card. JSON map key order is not stable across
-- decode/re-encode, so the checksum must never run over raw JSON — only over this
-- deterministic string (scalars + arrays in array order).
local function cardChecksum(card)
    local parts = { "v" .. tostring(card.v or 0), tostring(card.persona or "") }
    for _, t in ipairs(card.turns or {}) do parts[#parts + 1] = tostring(t.role) .. ":" .. tostring(t.text) end
    for _, f in ipairs(card.facts or {}) do
        parts[#parts + 1] = "f:" .. tostring(f.t) .. "|" .. tostring(f.p) .. "|" .. tostring(f.w) .. "|" .. tostring(f.c or "")
    end
    for _, m in ipairs(card.imp or {}) do parts[#parts + 1] = "m:" .. tostring(m.t) .. "|" .. tostring(m.i) .. "|" .. tostring(m.g or 0) end
    for _, a in ipairs(card.aliases or {}) do parts[#parts + 1] = "a:" .. tostring(a) end
    local s = table.concat(parts, "\030")
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end

local function newCard()
    return { v = CARD_SCHEMA_V, turns = {}, facts = {}, imp = {}, aliases = {}, trust = 0, bond = 0, bond_day = 0 }
end

-- Weighted fact add with dedup + provenance + auto-promote (Stardew pattern: a fact in an
-- important category is ALSO promoted into the bounded important-memories list).
-- auto-promote an important-category fact into the bounded important-memories list (idempotent by text).
local function promoteImportant(card, text, weight, category)
    if not (category and CARD_IMPORTANT_CATEGORIES[category]) then return end
    card.imp = card.imp or {}
    for _, m in ipairs(card.imp) do
        if m.t == text then m.i = math.max(tonumber(m.i) or 1, weight); return end
    end
    card.imp[#card.imp + 1] = { t = text, i = weight, d = gameDay(), g = gateForCategory(category) }
    if #card.imp > CARD_MAX_IMPORTANT then
        table.sort(card.imp, function(a, b) return (tonumber(a.i) or 0) > (tonumber(b.i) or 0) end)
        while #card.imp > CARD_MAX_IMPORTANT do table.remove(card.imp) end
    end
end

function AI_Influence.AddCardFact(card, text, provenance, weight, category)
    text = tostring(text or ""); if text == "" or type(card) ~= "table" then return false end
    provenance = CARD_PROVENANCE[provenance] and provenance or "model_color"
    weight = tonumber(weight) or 1
    card.facts = card.facts or {}
    for _, f in ipairs(card.facts) do
        if f.t == text then
            f.w = math.max(tonumber(f.w) or 1, weight)
            promoteImportant(card, text, f.w, category or f.c)  -- re-stated fact must bump its important entry too
            return true
        end
    end
    card.facts[#card.facts + 1] = { t = text, p = provenance, w = weight, d = gameDay(), c = category }
    promoteImportant(card, text, weight, category)
    if #card.facts > CARD_MAX_FACTS then
        table.sort(card.facts, function(a, b)
            local wa, wb = tonumber(a.w) or 0, tonumber(b.w) or 0
            if wa ~= wb then return wa > wb end
            return (tonumber(a.d) or 0) > (tonumber(b.d) or 0)
        end)
        while #card.facts > CARD_MAX_FACTS do table.remove(card.facts) end
    end
    return true
end

-- Encode = stamp v + checksum; compact (evict lowest-weight facts) if over the byte cap.
function AI_Influence.EncodeCard(card)
    if type(card) ~= "table" then return nil end
    if not (json and json.encode) then ensureDjfhe() end   -- lazy json (see DecodeCard note)
    card.v = CARD_SCHEMA_V
    card.ck = cardChecksum(card)
    local s = (json and json.encode) and json.encode(card) or nil
    if not s then return nil end
    local guard = 0
    while #s > CARD_MAX_BYTES and card.facts and #card.facts > 0 and guard < 250 do
        table.sort(card.facts, function(a, b) return (tonumber(a.w) or 0) < (tonumber(b.w) or 0) end)
        table.remove(card.facts, 1)
        card.ck = cardChecksum(card)
        s = json.encode(card); guard = guard + 1
    end
    return s
end

-- Decode = parse + migrate + verify. Returns card, reason ("ok" | "migrated_v1" | nil-reasons:
-- "empty" | "parse" | "checksum" | "future_version"). Corrupt cards are QUARANTINED by the caller
-- (start fresh; never crash the chat).
function AI_Influence.DecodeCard(raw)
    if not raw or raw == "" then return nil, "empty" end
    if not (json and json.decode) then ensureDjfhe() end   -- lazy json: a clean load's first card arrives before anything else loaded it
    if not (json and json.decode) then return nil, "nojson" end
    local ok, card = pcall(json.decode, raw)
    if not ok or type(card) ~= "table" then return nil, "parse" end
    if card.v == nil then
        local migrated = newCard()
        migrated.persona = card.persona
        migrated.turns = card.turns or {}
        for _, f in ipairs(card.facts or {}) do
            if type(f) == "string" then migrated.facts[#migrated.facts + 1] = { t = f, p = "npc_claim", w = 1, d = 0 }
            elseif type(f) == "table" then migrated.facts[#migrated.facts + 1] = f end
        end
        migrated.trust = 0
        return migrated, "migrated_v1"
    end
    if (tonumber(card.v) or 0) > CARD_SCHEMA_V then return nil, "future_version" end
    local ck = card.ck
    card.ck = nil
    if ck ~= nil and cardChecksum(card) ~= ck then return nil, "checksum" end
    card.turns = card.turns or {}; card.facts = card.facts or {}
    card.imp = card.imp or {}; card.aliases = card.aliases or {}
    card.trust = tonumber(card.trust) or 0
    card.bond = tonumber(card.bond) or 0; card.bond_day = tonumber(card.bond_day) or 0  -- doc 06 defaults on read
    return card, "ok"
end

function AI_Influence.StoreCard(token, cardTable)
    if not AddUITriggeredEvent then return false end
    local jsonStr = AI_Influence.EncodeCard(cardTable)
    if not jsonStr then return false end
    pcall(function() AddUITriggeredEvent("ai_influence", "store_card", { token = tostring(token), json = jsonStr }) end)
    log("StoreCard token=" .. tostring(token) .. " len=" .. tostring(#jsonStr))
    return true
end

-- #226 fix: FIFO queue instead of a single-flight stash — concurrent loads (boot hydration +
-- conversation + initiative) each get THEIR OWN response; MD answers load_card strictly in order.
AI_Influence._pendingCards = AI_Influence._pendingCards or {}
function AI_Influence.LoadCard(token, callback)
    if not AddUITriggeredEvent then if callback then callback(nil) end return end
    table.insert(AI_Influence._pendingCards, { token = tostring(token), cb = callback })
    pcall(function() AddUITriggeredEvent("ai_influence", "load_card", { token = tostring(token) }) end)
    log("LoadCard token=" .. tostring(token) .. " (queued " .. tostring(#AI_Influence._pendingCards) .. ")")
end

-- MD -> Lua response: param is the stored JSON string ("" if none). v2: verify + migrate via
-- DecodeCard; corrupt/future cards are quarantined (logged, fresh card handed to the caller).
local function onCardLoaded(_, param)
    local raw = tostring(param or "")
    local card, reason = AI_Influence.DecodeCard(raw)
    local head = table.remove(AI_Influence._pendingCards, 1)
    local tok = head and head.token or "?"
    if card == nil and reason ~= "empty" then
        log("card QUARANTINED token=" .. tok .. " reason=" .. tostring(reason))
    end
    log("card_loaded token=" .. tok .. " has_card=" .. tostring(card ~= nil) .. " reason=" .. tostring(reason))
    if head and head.cb then head.cb(card, raw) end
end

-- ---- doc 06: NPC INITIATIVE (#210) — bonded-but-neglected NPCs reach OUT to the player -------------
-- Deterministic candidate selection from a persisted index (a reserved card's .idx field); ONE LLM call
-- writes the outreach line; delivery rides the PROVEN CommsIncoming lane (native Messages). The index is
-- upserted on every chat turn and survives save/reload like any other card (idx is a non-checksum field).
local INIT_INDEX_TOKEN = "aic_initiative_index"
local INIT_BOND_MIN = 55        -- tier 3+ only: close contacts reach out, strangers don't
local INIT_NEGLECT_MIN = 2      -- game-time units (same unit bond_day uses) since the last chat
local INIT_COOLDOWN = 3         -- min units between outreaches from the same NPC
AI_Influence._initIndex = AI_Influence._initIndex or nil   -- lazily loaded from the index card
function AI_Influence.UpsertInitiativeEntry(idx, token, ctx, card)
    idx = (type(idx) == "table") and idx or {}
    ctx = ctx or {}; card = card or {}
    for _, e in ipairs(idx) do
        if e.tk == token then
            e.b = tonumber(card.bond) or 0; e.bd = tonumber(card.bond_day) or 0
            if ctx.target and ctx.target ~= "" then e.tg = tostring(ctx.target) end
            if ctx.faction and ctx.faction ~= "" then e.fid = tostring(ctx.faction) end
            return idx
        end
    end
    idx[#idx + 1] = { tk = tostring(token), tg = tostring(ctx.target or ""), fid = tostring(ctx.faction or ""),
                      b = tonumber(card.bond) or 0, bd = tonumber(card.bond_day) or 0, id = 0 }
    return idx
end
-- Highest-bond entry that is bonded (>= INIT_BOND_MIN), neglected (>= INIT_NEGLECT_MIN since last chat)
-- and off cooldown (>= INIT_COOLDOWN since its last outreach). nil when nobody qualifies.
function AI_Influence.PickInitiativeCandidate(idx, today)
    if type(idx) ~= "table" then return nil end
    today = tonumber(today) or 0
    local best = nil
    for _, e in ipairs(idx) do
        local b = tonumber(e.b) or 0
        local neglected = today - (tonumber(e.bd) or 0)
        local sinceOut = today - (tonumber(e.id) or 0)
        if b >= INIT_BOND_MIN and neglected >= INIT_NEGLECT_MIN and sinceOut >= INIT_COOLDOWN then
            if not best or b > (tonumber(best.b) or 0) then best = e end
        end
    end
    return best
end
local function persistInitIndex()
    local c = newCard()
    c.idx = AI_Influence._initIndex or {}
    AI_Influence.StoreCard(INIT_INDEX_TOKEN, c)
end
-- Chat-turn hook: keep the in-memory index current and persisted (called from SendDirectChat's store).
function AI_Influence.NoteInteraction(token, ctx, card)
    AI_Influence._initIndex = AI_Influence.UpsertInitiativeEntry(AI_Influence._initIndex or {}, token, ctx, card)
    persistInitIndex()
end
-- The periodic pass (MD Initiative_tick raises AIChat.initiative_tick). First tick after load hydrates the
-- index from its card (merging any in-memory entries from chats that happened before hydration).
function AI_Influence.InitiativePass(todayOverride)
    if AI_Influence._initIndex == nil then
        AI_Influence.LoadCard(INIT_INDEX_TOKEN, function(card)
            local stored = (type(card) == "table" and type(card.idx) == "table") and card.idx or {}
            local mem = AI_Influence._initIndex or {}
            for _, e in ipairs(mem) do stored = AI_Influence.UpsertInitiativeEntry(stored, e.tk, { target = e.tg, faction = e.fid }, { bond = e.b, bond_day = e.bd }) end
            AI_Influence._initIndex = stored
            log("initiative index hydrated entries=" .. tostring(#stored))
        end)
        return
    end
    local today = tonumber(todayOverride) or gameDay()
    local cand = AI_Influence.PickInitiativeCandidate(AI_Influence._initIndex, today)
    if not cand then
        -- observability (ADR-010): a silent no-op is indistinguishable from a crash in the debuglog
        log("initiative pass: no candidate (today=" .. tostring(today) .. " entries=" .. tostring(#AI_Influence._initIndex) .. ")")
        return
    end
    log("initiative candidate=" .. tostring(cand.tk) .. " bond=" .. tostring(cand.b))
    AI_Influence.LoadCard(cand.tk, function(card)
        card = (type(card) == "table") and card or newCard()
        local gap = today - (tonumber(cand.bd) or 0)
        local sys = "You are " .. tostring(cand.tg or "a station officer") .. " of the " .. tostring(cand.fid or "argon")
            .. " faction in the X4 galaxy. You have a close personal bond with the player, but you have not spoken in "
            .. tostring(gap) .. " days and you miss the contact. Your people are " .. AI_Influence.CultureDescriptor(cand.fid)
            .. ". Write ONE short in-character message (1-2 sentences) reaching out to the player. Respond with ONLY the message text."
        AI_Influence.SendDirect({ { role = "system", content = sys } }, { max_tokens = 100 }, function(ok, reply)
            if not ok or not reply or reply == "" then log("initiative send failed") return end
            cand.id = today
            card.turns = card.turns or {}
            card.turns[#card.turns + 1] = { role = "assistant", text = reply }
            while #card.turns > CARD_MAX_TURNS do table.remove(card.turns, 1) end
            AI_Influence.StoreCard(cand.tk, card)
            persistInitIndex()
            if AddUITriggeredEvent then
                pcall(function()
                    AddUITriggeredEvent("ai_influence", "comms_incoming", {
                        title = "Personal message from " .. tostring(cand.tg),
                        body = tostring(reply), sender = tostring(cand.tg), priority = "low",
                    })
                end)
            end
            log("initiative delivered from=" .. tostring(cand.tg) .. " len=" .. tostring(#tostring(reply)))
        end)
    end)
end

-- ---- doc 08: DEATH HISTORY (#211) — a life-story obituary when a watched ship is lost ---------------
-- MD's On_destroyed raises AIChat.ship_lost with identity fields; ONE LLM call writes a short in-memoriam
-- and delivers it via the proven CommsIncoming lane (high priority: it was YOUR ship). Deterministic gates:
-- named ships only, and a cooldown so a fleet wipe can't burn the LLM budget.
local OBIT_COOLDOWN_S = 300
AI_Influence._lastObitAt = AI_Influence._lastObitAt or -OBIT_COOLDOWN_S
-- Gate check extracted for unit testing: returns true when an obituary should be written.
function AI_Influence.ObituaryEligible(name, nowS, lastAt)
    if not name or name == "" then return false end
    return (tonumber(nowS) or 0) - (tonumber(lastAt) or 0) >= OBIT_COOLDOWN_S
end
function AI_Influence.OnShipLost(param)
    local g = AI_Influence.parseBackendConfig(param)  -- same k=v| wire format
    local nowS = 0
    pcall(function() if GetCurrentGameTime then nowS = GetCurrentGameTime() end end)
    if not AI_Influence.ObituaryEligible(g.name, nowS, AI_Influence._lastObitAt) then
        log("obituary skipped name='" .. tostring(g.name) .. "' (unnamed or cooldown)")
        return
    end
    AI_Influence._lastObitAt = nowS
    local sys = "You are a galactic news archivist in the X4 universe. The ship '" .. tostring(g.name)
        .. "' (" .. tostring(g.id or "") .. ") and its crew were lost in " .. tostring(g.sector or "unknown space")
        .. ", destroyed by " .. tostring(g.attacker or "unknown forces")
        .. ". Write a brief, dignified in-memoriam life-story for the ship and crew, 2-3 sentences,"
        .. " grounded ONLY in these facts. Respond with ONLY the memorial text."
    AI_Influence.SendDirect({ { role = "system", content = sys } }, { max_tokens = 120 }, function(ok, reply)
        if not ok or not reply or reply == "" then log("obituary send failed") return end
        if AddUITriggeredEvent then
            pcall(function()
                AddUITriggeredEvent("ai_influence", "comms_incoming", {
                    title = "In Memoriam: " .. tostring(g.name),
                    body = tostring(reply), sender = "Fleet Records", priority = "high",
                })
            end)
        end
        log("obituary delivered for=" .. tostring(g.name) .. " len=" .. tostring(#tostring(reply)))
    end)
end

-- ---- doc 03: WORLD-EVENTS LEDGER (#212) — pulse events become conversation-visible, in-save ---------
-- MD raises AIChat.world_event on every diplomacy transition + economy crisis; the ledger persists as a
-- reserved card (.evts, capped) and rides every SendDirectChat prompt. Serverless replacement for the
-- bridge's RoleRAG event awareness. Zero extra LLM calls (prompt tokens only).
local WORLDEV_TOKEN = "aic_world_events"
local WORLDEV_CAP = 30
AI_Influence._worldEvents = AI_Influence._worldEvents or nil   -- hydrated from the ledger card on load
function AI_Influence.AddWorldEvent(evts, kind, a, b, to, day)
    evts = (type(evts) == "table") and evts or {}
    evts[#evts + 1] = { k = tostring(kind or "shift"), a = tostring(a or ""), b = tostring(b or ""),
                        to = tostring(to or ""), d = tonumber(day) or 0 }
    while #evts > WORLDEV_CAP do table.remove(evts, 1) end
    return evts
end
-- newest-first prompt lines, top-K. #214 knowledge gating: diplomacy events (war/peace/shift) are
-- galaxy-common news; a CRISIS is LOCAL knowledge — only NPCs in that sector (viewer.psector) know of it.
-- viewer is optional; omit it (or omit psector) to see everything (galaxy-common only for crises).
function AI_Influence.WorldEventLines(evts, k, viewer)
    if type(evts) ~= "table" or #evts == 0 then return {} end
    local vsec = (type(viewer) == "table") and tostring(viewer.psector or "") or ""
    local out, want = {}, tonumber(k) or 5
    for i = #evts, 1, -1 do
        if #out >= want then break end
        local e = evts[i]
        if e.k == "crisis" then
            if vsec ~= "" and e.b == vsec then
                out[#out + 1] = e.a .. " in " .. e.b .. " is suffering a power crisis"
            end
        elseif e.k == "war" then out[#out + 1] = "war has broken out between " .. e.a .. " and " .. e.b
        elseif e.k == "peace" then out[#out + 1] = "the war between " .. e.a .. " and " .. e.b .. " has ended"
        else out[#out + 1] = "relations between " .. e.a .. " and " .. e.b .. " have shifted to " .. (e.to ~= "" and e.to or "a new footing") end
    end
    return out
end
local function persistWorldEvents()
    local c = newCard()
    c.evts = AI_Influence._worldEvents or {}
    AI_Influence.StoreCard(WORLDEV_TOKEN, c)
end
function AI_Influence.HydrateWorldEvents()
    AI_Influence.LoadCard(WORLDEV_TOKEN, function(card)
        local stored = (type(card) == "table" and type(card.evts) == "table") and card.evts or {}
        local mem = AI_Influence._worldEvents or {}
        for _, e in ipairs(mem) do stored = AI_Influence.AddWorldEvent(stored, e.k, e.a, e.b, e.to, e.d) end
        AI_Influence._worldEvents = stored
        log("world-events ledger hydrated n=" .. tostring(#stored))
    end)
end
function AI_Influence.OnWorldEvent(param)
    local g = AI_Influence.parseBackendConfig(param)  -- same k=v| wire format
    AI_Influence._worldEvents = AI_Influence.AddWorldEvent(AI_Influence._worldEvents or {}, g.kind, g.a, g.b, g.to, gameDay())
    persistWorldEvents()
    log("world event recorded kind=" .. tostring(g.kind) .. " n=" .. tostring(#AI_Influence._worldEvents))
end

-- ---- #221 LLM DIPLOMACY — Player2 DECIDES diplomatic developments; Lua validates; MD executes -----
-- The Bannerlord-mined shape: per-event statements, band-clamped relation deltas, news + ledger fallout.
local DIPLO_DELTA_BAND = 0.05
local KNOWN_FACTIONS = { argon = true, antigone = true, alliance = true, hatikvah = true, teladi = true,
    ministry = true, paranid = true, holyorder = true, split = true, freesplit = true, scaleplate = true,
    terran = true, pioneers = true, boron = true, buccaneers = true, riptide = true, court = true, yaki = true }
function AI_Influence.ValidatePlayerDiploTarget(npcFaction, target)
    target = tostring(target or "")
    if not KNOWN_FACTIONS[target] then return nil end           -- unknown or protected (xenon/khaak/player absent)
    if target == tostring(npcFaction or "") then return nil end -- not with yourself
    return target
end
function AI_Influence.ValidateDiploDecision(raw)
    if not (json and json.decode) then ensureDjfhe() end
    if not (json and json.decode) then return nil end
    local ok, obj = pcall(json.decode, tostring(raw or ""))
    if not ok or type(obj) ~= "table" then return nil end
    local action = tostring(obj.action or "")
    if action ~= "improve" and action ~= "worsen" and action ~= "hold" then return nil end
    local delta = tonumber(obj.relation_delta) or 0
    if delta > DIPLO_DELTA_BAND then delta = DIPLO_DELTA_BAND elseif delta < -DIPLO_DELTA_BAND then delta = -DIPLO_DELTA_BAND end
    if action == "hold" then delta = 0 end
    local statement = tostring(obj.statement or ""):sub(1, 300)
    return { action = action, delta = delta, statement = statement }
end
function AI_Influence.OnDiploStatement(param)
    local g = AI_Influence.parseBackendConfig(param)
    if not (g.a and g.a ~= "" and g.b and g.b ~= "") then return end
    local evLines = AI_Influence.WorldEventLines(AI_Influence._worldEvents, 3)
    -- KingdomStatementGenerator port: the SPEAKING faction issues its own statement to the other side
    local speaker = (g.speaker and g.speaker ~= "") and g.speaker or g.a
    local other = (speaker == g.a) and g.b or g.a
    local sys = "You are the leadership of the faction '" .. speaker .. "' in the X4 galaxy, speaking in an"
        .. " ongoing diplomatic situation (" .. tostring(g.kind or "tension") .. ") with faction '" .. other
        .. "'. Your current relation to them is " .. tostring(g.rel or "0")
        .. " (range -1 war to 1 allied). Statements exchanged so far: " .. tostring(g.n or 0) .. "."
    if #evLines > 0 then sys = sys .. " Recent galactic news: " .. table.concat(evLines, "; ") .. "." end
    sys = sys .. " Issue YOUR faction's next diplomatic statement to them and decide how it moves relations:"
        .. " improve or worsen (small steps) or hold. Stay consistent with your faction's temperament ("
        .. AI_Influence.CultureDescriptor(speaker) .. "). Respond ONLY with JSON"
        .. ' {"statement":"<your faction!s diplomatic statement, 1-2 sentences, first person plural>",'
        .. '"action":"improve|worsen|hold","relation_delta":<number between -0.05 and 0.05>}'
    AI_Influence.SendDirect({ { role = "system", content = sys } },
        { max_tokens = 220, response_format = { type = "json_object" } },
    function(ok, raw)
        if not ok then
            log("diplo statement call failed")
            if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "diplo_stmt_failed", { a = g.a, b = g.b }) end) end
            return
        end
        local v = AI_Influence.ValidateDiploDecision(raw)
        if not v then
            log("diplo decision REJECTED by validator")
            if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "diplo_stmt_failed", { a = g.a, b = g.b }) end) end
            return
        end
        if AddUITriggeredEvent then
            pcall(function()
                AddUITriggeredEvent("ai_influence", "diplo_apply", {
                    a = g.a, b = g.b,   -- ALWAYS the digest pair — the model cannot redirect the effect
                    speaker = speaker,
                    delta = v.delta, action = v.action, statement = v.statement,
                })
            end)
        end
        log("diplo decision validated: " .. g.a .. " vs " .. g.b .. " action=" .. v.action .. " delta=" .. tostring(v.delta))
    end)
end

-- ---- #226 SEMANTIC RECALL — RoleRAG over Player2 embeddings (first mod on the new endpoint) --------
-- Important memories get 256-dim embeddings (matryoshka-truncated, int8-quantized, base64, stored in a
-- per-NPC SIDE card so the main card's checksum/byte budget is untouched). Each chat turn embeds the
-- player's line (+ any not-yet-embedded memories, piggybacked in the same call) and injects the most
-- RELEVANT memories instead of merely the heaviest. Fallback when embeddings are unavailable: the
-- Stardew-proven keyword-overlap + recency scorer (zero extra calls).
local EMBED_MODEL = "text-embedding-3-small"
local EMBED_DIMS = 256
local VEC_PREFIX = "aic_vec_"

local B64C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function AI_Influence.B64Encode(bytes)
    local out = {}
    for i = 1, #bytes, 3 do
        local a, b, c = bytes:byte(i), bytes:byte(i + 1), bytes:byte(i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64C:sub(c1 + 1, c1 + 1) .. B64C:sub(c2 + 1, c2 + 1)
            .. (b and B64C:sub(c3 + 1, c3 + 1) or "=") .. (c and B64C:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end
local B64R = {}
for i = 1, 64 do B64R[B64C:sub(i, i)] = i - 1 end
function AI_Influence.B64Decode(s)
    local out = {}
    for i = 1, #s, 4 do
        local c1, c2 = B64R[s:sub(i, i)], B64R[s:sub(i + 1, i + 1)]
        local c3, c4 = B64R[s:sub(i + 2, i + 2)], B64R[s:sub(i + 3, i + 3)]
        if not (c1 and c2) then break end
        local n = c1 * 262144 + c2 * 4096 + (c3 or 0) * 64 + (c4 or 0)
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if c3 then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if c4 then out[#out + 1] = string.char(n % 256) end
    end
    return table.concat(out)
end

-- int8 quantization: {s = scale, q = base64(signed bytes stored offset+128)}
function AI_Influence.QuantizeVec(v)
    local maxabs = 1e-9
    for i = 1, #v do local a = math.abs(v[i]); if a > maxabs then maxabs = a end end
    local bytes = {}
    for i = 1, #v do
        local q = math.floor(v[i] / maxabs * 127 + 0.5)
        if q > 127 then q = 127 elseif q < -127 then q = -127 end
        bytes[#bytes + 1] = string.char(q + 128)
    end
    return { s = maxabs, q = AI_Influence.B64Encode(table.concat(bytes)) }
end
function AI_Influence.DequantizeVec(qv)
    if type(qv) ~= "table" or not qv.q then return nil end
    local bytes = AI_Influence.B64Decode(qv.q)
    local v = {}
    for i = 1, #bytes do v[i] = (bytes:byte(i) - 128) / 127 * (tonumber(qv.s) or 1) end
    return v
end
function AI_Influence.Cosine(a, b)
    if not a or not b or #a == 0 or #a ~= #b then return 0 end
    local dot, na, nb = 0, 0, 0
    for i = 1, #a do dot = dot + a[i] * b[i]; na = na + a[i] * a[i]; nb = nb + b[i] * b[i] end
    if na == 0 or nb == 0 then return 0 end
    return dot / (math.sqrt(na) * math.sqrt(nb))
end
local function vecKey(text)
    local h = 5381
    text = tostring(text or "")
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end
AI_Influence.VecKey = vecKey

-- one embeddings call: input = array of strings -> cb(ok, vectors[])
function AI_Influence.Embed(texts, cb)
    local req = newRequest("POST")
    if not req then if cb then cb(false, "no transport") end return end
    local be = AI_Influence.ActiveBackend()
    local base = be.url:gsub("/chat/completions$", "/embeddings")
    req:setUrl(base)
    if req.addHeader then
        pcall(function() req:addHeader("Content-Type", "application/json") end)
        if be.auth == "player2" then pcall(function() req:addHeader("player2-game-key", be.key) end)
        elseif be.auth == "bearer" and be.key ~= "" then pcall(function() req:addHeader("Authorization", "Bearer " .. be.key) end) end
    end
    -- NOTE (Ken 2026-07-22): Player2 lets the USER pick a default embedding model; an explicit model
    -- field would override their choice. We omit it (dimensions still requested; not all models truncate,
    -- so we ALSO truncate defensively below) and fingerprint the response model — stored vectors from a
    -- different model are invalid for comparison and get invalidated by the caller.
    if req.setTimeout then req:setTimeout(20) end
    req:setBody(json.encode({ input = texts, dimensions = EMBED_DIMS }))
    req:send(function(resp, err)
        if err or not resp then if cb then cb(false, tostring(err)) end return end
        if resp:getStatus() ~= 200 then if cb then cb(false, "HTTP " .. tostring(resp:getStatus())) end return end
        local obj = resp:getJson()
        if type(obj) ~= "table" or type(obj.data) ~= "table" then if cb then cb(false, "bad embed response") end return end
        local vecs = {}
        for i, d in ipairs(obj.data) do
            local v = d.embedding
            if type(v) == "table" and #v > EMBED_DIMS then
                local t = {}
                for j = 1, EMBED_DIMS do t[j] = v[j] end
                v = t
            end
            vecs[i] = v
        end
        if cb then cb(true, vecs, tostring(obj.model or "unknown")) end
    end)
end

-- Stardew-proven fallback: keyword overlap + recency (zero calls)
function AI_Influence.OverlapScore(query, text)
    local qwords, score = {}, 0
    for w in tostring(query or ""):lower():gmatch("%a%a%a%a+") do qwords[w] = true end
    for w in tostring(text or ""):lower():gmatch("%a%a%a%a+") do if qwords[w] then score = score + 1 end end
    return score
end

-- Pick the K most RELEVANT tier-visible important memories. Returns texts (best first).
-- vecCard may be nil (fallback scorer); queryVec may be nil (fallback scorer).
function AI_Influence.SemanticRecall(card, tier, vecCard, queryVec, queryText, k)
    k = k or 6
    local pool = {}
    for _, m in ipairs((card and card.imp) or {}) do
        if (tonumber(m.g) or 0) <= tier then pool[#pool + 1] = m end
    end
    if #pool == 0 then return {} end
    local scored = {}
    for _, m in ipairs(pool) do
        local s = nil
        if queryVec and vecCard and type(vecCard.vecs) == "table" then
            local qv = vecCard.vecs[vecKey(m.t)]
            if qv then s = AI_Influence.Cosine(queryVec, AI_Influence.DequantizeVec(qv)) end
        end
        if s == nil then s = AI_Influence.OverlapScore(queryText, m.t) * 0.1 + (tonumber(m.i) or 0) * 0.01 end
        scored[#scored + 1] = { t = m.t, s = s }
    end
    table.sort(scored, function(a, b) return a.s > b.s end)
    local out = {}
    for i = 1, math.min(k, #scored) do out[#out + 1] = scored[i].t end
    return out
end

-- P2 identity: blackboard-sticky per-entity token when a real NPC is in scope. Reads $aic_identity
-- off the conversation NPC; mints base#suffix and writes it back when absent. Same-name NPCs thus
-- get DISTINCT tokens; without an entity, the legacy name|faction|role token still works.
function AI_Influence.ResolveNpcToken(ctx)
    ctx = ctx or {}
    local base = tostring(ctx.target or "npc") .. "|" .. tostring(ctx.faction or "") .. "|" .. tostring(ctx.role or "")
    local rawid = AI_Influence._pendingNpcId
    if rawid and SetNPCBlackboard and GetNPCBlackboard and ConvertStringToLuaID then
        local okr, tok = pcall(function()
            return GetNPCBlackboard(ConvertStringToLuaID(tostring(rawid)), "$aic_identity")
        end)
        if okr and type(tok) == "string" and tok ~= "" then return tok, "blackboard" end
        local t = 0
        pcall(function() if GetCurrentGameTime then t = GetCurrentGameTime() end end)
        local minted = base .. "#" .. string.format("%x", math.floor((tonumber(t) or 0) * 10) % 1048576)
        local okw = pcall(function()
            SetNPCBlackboard(ConvertStringToLuaID(tostring(rawid)), "$aic_identity", minted)
        end)
        if okw then return minted, "minted" end
    end
    return base, "legacy"
end

-- P1b proof harness: on each game load, LOAD the probe card (logging what survived the last save),
-- then STORE an incremented card. Across F5/F9 the loaded n proves MD-save-state round-trip.
function AI_Influence.CardRoundTripProbe()
    AI_Influence.LoadCard("p1_probe", function(card, raw)
        local prevN = (type(card) == "table" and tonumber(card.n)) or 0
        if prevN > 0 then
            writeToLogbook("AI Influence (card survived)", "Loaded card n=" .. tostring(prevN)
                .. " note=" .. tostring(card and card.note or ""))
            log("CARD_ROUNDTRIP LOADED n=" .. tostring(prevN))
        else
            log("CARD_ROUNDTRIP LOADED empty (first run)")
        end
        AI_Influence.StoreCard("p1_probe", { n = prevN + 1, note = "stored on load", turns = {} })
    end)
end

-- ---- P1c serverless chat turn: card -> bounded prompt -> direct Player2 -> card ------------
-- The ONE code path both the chat window and the continuity probe use. ctx = {target, faction, role}.
-- onReply(ok, replyText). Turns capped at 8 (Stardew-grounded); facts ride the system prompt.
function AI_Influence.SendDirectChat(ctx, text, onReply)
    ctx = ctx or {}
    local token, tokenSource = AI_Influence.ResolveNpcToken(ctx)
    AI_Influence.LoadCard(token, function(card)
        card = (type(card) == "table") and card or newCard()
        card.turns = card.turns or {}; card.facts = card.facts or {}
        card.imp = card.imp or {}; card.aliases = card.aliases or {}
        card.bond = tonumber(card.bond) or 0; card.bond_day = tonumber(card.bond_day) or 0
        AI_Influence.DecayBond(card, gameDay())   -- doc 06: neglect cools the bond
        -- #226: the rest of the turn runs as a continuation so semantic recall can happen first
        local function continueTurn(relevantFacts)
        -- alias merge: a blackboard/minted token may front different display names over time
        if ctx.target and ctx.target ~= "" then
            local seen = false
            for _, a in ipairs(card.aliases) do if a == ctx.target then seen = true end end
            if not seen then card.aliases[#card.aliases + 1] = tostring(ctx.target) end
        end
        local sys = "You are " .. tostring(ctx.target or "a station officer") .. ", a "
            .. tostring(ctx.role or "officer") .. " of the " .. tostring(ctx.faction or "argon")
            .. " faction on a station in the X4 galaxy. Stay in character. Reply in 1-3 short sentences."
            .. " GROUNDING RULE (critical): everything marked as known facts, news, standing or traffic in"
            .. " this prompt is GROUND TRUTH — the real state of the world. You MAY deceive, bluff, deflect or"
            .. " withhold IN CHARACTER about things you actually know here, when it fits your persona, your"
            .. " trust in the player and your faction's interests. But you CANNOT cite specific records the"
            .. " game has not given you — manifests, prices, exact quantities, schedules, names: for those,"
            .. " deflect in character (offer to check, point to the trade terminal). Never present invented"
            .. " specifics as data. If you chose to deceive the player this reply, also include"
            .. ' "deceived":true in the JSON (they will not see this flag).' 
        -- #213: a self-generated persona (minted on the FIRST exchange, then stable) keeps this NPC's voice
        -- distinct and consistent across conversations. Persona IS part of the card checksum — tamper-proof.
        if type(card.persona) == "string" and card.persona ~= "" then
            sys = sys .. " Your established persona: " .. card.persona .. " — stay true to that character."
        end
        -- P3-a grounding (serverless): real standing + location, read by MD from the live galaxy.
        if ctx.standing and ctx.standing ~= "" then
            sys = sys .. " The player's current standing with your faction is " .. tostring(ctx.standing)
                .. " — let it colour how warm or guarded you are."
        end
        if (ctx.psector and ctx.psector ~= "") or (ctx.nearby and ctx.nearby ~= "") then
            sys = sys .. " You are located in " .. tostring(ctx.psector or "this sector") .. "."
            if ctx.nearby and ctx.nearby ~= "" then
                sys = sys .. " Nearby stations you know of: " .. tostring(ctx.nearby) .. "."
            end
            sys = sys .. " Only reference these real places; do not invent sectors or stations."
        end
        -- #216: live sector activity (aware-fleet-movements slice) — a REAL find_ship count from MD
        local traf = tonumber(ctx.traffic)
        if traf and traf > 0 then
            sys = sys .. " Ship traffic around you right now: " .. tostring(traf)
                .. " vessels active in this sector."
        end
        -- U3: deterministic trust posture. Move trust by the player's tone (rule-based), then gate which
        -- facts are visible to the NPC by trust tier (guarded NPCs withhold secrets/promises).
        card.trust = tonumber(card.trust) or 0
        AI_Influence.AdjustTrust(card, AI_Influence.ToneTrustDelta(text))
        local tier = AI_Influence.TrustTier(card.trust)
        sys = sys .. " Your trust in this player is '" .. tostring(TRUST_TIER_NAMES[tier] or "neutral")
            .. "'; be correspondingly guarded or open, and only share sensitive matters if you trust them."
        -- doc 06: personal bond + faction culture colour the warmth (distinct from trust).
        local btier = AI_Influence.BondTier(card.bond)
        sys = sys .. " On a personal level the player is " .. tostring(BOND_TIER_NAMES[btier + 1] or "an acquaintance")
            .. " to you. Your people are " .. AI_Influence.CultureDescriptor(ctx.faction)
            .. " — let both your bond level and that cultural temperament shape your warmth and familiarity."
        sys = sys .. " " .. AI_Influence.BondGate(btier)  -- bond-tier gate on what you may offer
        -- doc 06: formal commitment — reflect an existing pact; only the top tier may propose a new one.
        if AI_Influence.HasCommitment(card) then
            sys = sys .. " You and this player already share a standing " .. tostring(card.pact.kind)
                .. " — treat them as a committed ally and speak accordingly."
        end
        -- #212: recent world events ride every prompt (serverless event awareness, zero extra calls)
        -- #214: gated by viewer location — crises are local knowledge, diplomacy is galaxy-common
        local evLines = AI_Influence.WorldEventLines(AI_Influence._worldEvents, 5, { psector = ctx.psector })
        if #evLines > 0 then
            sys = sys .. " Recent galactic news you are aware of: " .. table.concat(evLines, "; ")
                .. ". You may reference these events but never invent others."
        end
        -- top-K facts ride the prompt: #226 RELEVANT-first when recall ran, weight order otherwise
        local promptFacts = relevantFacts or AI_Influence.VisibleFacts(card, tier, 8)
        if #promptFacts > 0 then
            sys = sys .. " Facts you remember about the player: " .. table.concat(promptFacts, "; ") .. "."
        end
        -- Structured single-call contract (Bannerlord/Stardew pattern): ONE completion returns the
        -- reply AND the memory extraction, so no separate extraction call. response_format json_object.
        sys = sys .. " Respond ONLY with a JSON object of the form"
            .. ' {"reply":"<your in-character line, 1-3 sentences>",'
            .. '"memory_updates":[{"text":"<a durable fact about THE PLAYER worth remembering, or omit>",'
            .. '"category":"preference|promise|secret|relationship|fact"}],'
            .. '"suggestion_topics":["<3 short things the player might plausibly say next, in the player!s voice, max 8 words each>"]}.'
            .. " Only record a memory_update when the player revealed something durable (a name, a promise,"
            .. " a preference, a secret); otherwise use an empty memory_updates array. Never invent facts."
        -- #221b: a diplomatically significant player statement can OPEN a diplomatic event
        sys = sys .. ' If the player makes a diplomatically SIGNIFICANT statement about another faction'
            .. ' (a threat, an alliance suggestion, revealing an attack), also include'
            .. ' "diplomatic_statement":{"target_faction":"<faction id>","stance":"hostile|friendly"} in the'
            .. ' JSON; otherwise omit it.'
        -- #213: no persona yet — mint one on this exchange (piggybacks the same completion, zero extra calls)
        if not (type(card.persona) == "string" and card.persona ~= "") then
            sys = sys .. ' Also include "persona":"<a 3-6 word character sketch of yourself, e.g. gruff veteran'
                .. ' dock chief>" in the JSON — invent a fitting personality for your role and faction.'
        end
        -- #217: an OWNED captain may take a patrol order through conversation (single-call pattern)
        if tostring(ctx.npc_owned or "") == "1" and ctx.npc_ship and tostring(ctx.npc_ship) ~= "" then
            sys = sys .. ' You captain the player!s ship ' .. tostring(ctx.npc_ship) .. '. If the player has'
                .. ' CLEARLY given you one of these orders in this exchange, also include'
                .. ' "order":"patrol|return|hold|attack|follow" (patrol this sector / return to the player!s'
                .. ' area / hold position / attack hostiles / follow the player) in the JSON and acknowledge'
                .. ' the order in your reply;'
                .. ' otherwise omit it entirely.'
        end
        -- doc 06: only the deepest bond tier may seal a pact; ask for the optional commitment field then.
        if AI_Influence.CommitmentAllowed(btier) and not AI_Influence.HasCommitment(card) then
            sys = sys .. ' If — and ONLY if — the player has clearly just agreed to a standing partnership with you'
                .. ' in this exchange, also include "commitment":"partnership" in the JSON; otherwise omit it entirely.'
        end
        local messages = { { role = "system", content = sys } }
        for _, t in ipairs(card.turns) do
            messages[#messages + 1] = { role = t.role, content = t.text }
        end
        messages[#messages + 1] = { role = "user", content = text }
        log("SendDirectChat token=" .. token .. " (" .. tokenSource .. ") turns=" .. tostring(#card.turns))
        AI_Influence.SendDirect(messages, { max_tokens = 260, response_format = { type = "json_object" } },
        function(ok, raw, usage, err)
            if not ok then
                if onReply then onReply(false, "[direct chat failed: " .. tostring(err) .. "]") end
                return
            end
            local reply, updates, topics, commitment, persona, order = AI_Influence.ParseStructuredReply(raw)
            -- #228b grounded deception (Ken): NPCs may lie about what they KNOW; the choice is recorded
            -- privately on the card so future catches have consequences (doc-01 lie-detection fuel).
            if json and json.decode then
                local okdc, objdc = pcall(json.decode, raw)
                if okdc and type(objdc) == "table" and objdc.deceived == true then
                    card.deceits = (tonumber(card.deceits) or 0) + 1
                    log("npc chose deception (total " .. tostring(card.deceits) .. ") token=" .. tostring(token))
                end
            end
            -- #217: whitelist + ownership gate, then hand execution to MD (proven create_order lane)
            if order and AI_Influence.OrderAllowed(ctx, order) and AddUITriggeredEvent then
                pcall(function() AddUITriggeredEvent("ai_influence", "player_order", { order = tostring(order) }) end)
                log("player order dispatched: " .. tostring(order) .. " ship=" .. tostring(ctx.npc_ship))
            end
            local nFacts = AI_Influence.ApplyMemoryUpdates(card, updates)
            -- #221b: player statement -> diplomatic event (validated: known non-protected faction, not self)
            local ds = nil
            if json and json.decode then
                local okd, obj = pcall(json.decode, raw)
                if okd and type(obj) == "table" and type(obj.diplomatic_statement) == "table" then ds = obj.diplomatic_statement end
            end
            if ds then
                local tgt = AI_Influence.ValidatePlayerDiploTarget(ctx.faction, ds.target_faction)
                local stance = (tostring(ds.stance) == "hostile" or tostring(ds.stance) == "friendly") and tostring(ds.stance) or nil
                if tgt and stance and AddUITriggeredEvent then
                    pcall(function() AddUITriggeredEvent("ai_influence", "diplo_open",
                        { a = tostring(ctx.faction), b = tgt, kind = "player_" .. stance }) end)
                    log("diplo event opened from player statement: " .. tostring(ctx.faction) .. " vs " .. tgt .. " (" .. stance .. ")")
                end
            end
            -- #213: first-exchange persona mint — once set it is never overwritten (stable voice)
            if persona and not (type(card.persona) == "string" and card.persona ~= "") then
                card.persona = tostring(persona):sub(1, 80)
                log("persona minted: " .. card.persona)
            end
            -- doc 06: seal a formal pact only if the top tier permits AND none exists yet (Lua is the gate).
            if commitment and AI_Influence.CommitmentAllowed(btier) and not AI_Influence.HasCommitment(card) then
                AI_Influence.RecordCommitment(card, commitment, gameDay())
                AI_Influence.AddCardFact(card, "sealed a standing " .. tostring(commitment) .. " with the player",
                    "npc_claim", 20, "relationship")
                log("SendDirectChat commitment sealed kind=" .. tostring(commitment))
            end
            local sug = AI_Influence.SuggestionsOut(topics)
            if sug and AddUITriggeredEvent then
                pcall(function() AddUITriggeredEvent("ai_influence", "suggestions", sug) end)
                log("suggestions (serverless) n=" .. tostring(sug.n))
            end
            card.turns[#card.turns + 1] = { role = "user", text = text }
            card.turns[#card.turns + 1] = { role = "assistant", text = reply }
            while #card.turns > CARD_MAX_TURNS do table.remove(card.turns, 1) end
            AI_Influence.AddBond(card, 3, ctx.faction); card.bond_day = gameDay()   -- doc 06: interaction deepens the bond
            AI_Influence.StoreCard(token, card)
            AI_Influence.NoteInteraction(token, ctx, card)   -- #210: keep the initiative index current
            log("SendDirectChat stored token=" .. token .. " bond=" .. string.format("%.0f", card.bond) .. " new_facts=" .. tostring(nFacts)
                .. " facts=" .. tostring(#card.facts))
            if onReply then onReply(true, reply) end
        end)
        end -- continueTurn
        -- #226 dispatcher: embed the player's line (+ up to 8 not-yet-embedded memories, same call),
        -- store vectors in the side card, recall the most RELEVANT memories; graceful fallback otherwise.
        if #(card.imp or {}) >= 3 and json then
            AI_Influence.LoadCard("aic_vec_" .. token, function(vecCard)
                vecCard = (type(vecCard) == "table") and vecCard or { v = 3, turns = {}, facts = {}, imp = {}, aliases = {}, trust = 0 }
                vecCard.vecs = vecCard.vecs or {}
                local newTexts, newKeys = {}, {}
                for _, m in ipairs(card.imp) do
                    local k2 = AI_Influence.VecKey(m.t)
                    if not vecCard.vecs[k2] and #newTexts < 8 then
                        newTexts[#newTexts + 1] = m.t; newKeys[#newKeys + 1] = k2
                    end
                end
                local input = { text }
                for _, t2 in ipairs(newTexts) do input[#input + 1] = t2 end
                AI_Influence.Embed(input, function(okE, vecs, emodel)
                    local tier0 = AI_Influence.TrustTier(tonumber(card.trust) or 0)
                    if okE and type(vecs) == "table" and vecs[1] then
                        -- model switch invalidates every stored vector (cross-model cosine is meaningless)
                        if vecCard.emodel and emodel and vecCard.emodel ~= emodel then
                            log("embed model changed (" .. tostring(vecCard.emodel) .. " -> " .. tostring(emodel) .. "); invalidating stored vectors")
                            vecCard.vecs = {}
                        end
                        vecCard.emodel = emodel
                        for i2, k2 in ipairs(newKeys) do
                            if vecs[i2 + 1] then vecCard.vecs[k2] = AI_Influence.QuantizeVec(vecs[i2 + 1]) end
                        end
                        AI_Influence.StoreCard("aic_vec_" .. token, vecCard)
                        local rec = AI_Influence.SemanticRecall(card, tier0, vecCard, vecs[1], text, 6)
                        log("semantic recall n=" .. tostring(#rec) .. " embedded_new=" .. tostring(#newKeys))
                        continueTurn(#rec > 0 and rec or nil)
                    else
                        log("semantic recall FALLBACK (embed: " .. tostring(vecs) .. ")")
                        local rec = AI_Influence.SemanticRecall(card, tier0, nil, nil, text, 6)
                        continueTurn(#rec > 0 and rec or nil)
                    end
                end)
            end)
        else
            continueTurn(nil)
        end
    end)
end

-- Parse the structured completion. Graceful degradation: if the content isn't the JSON contract
-- (model ignored response_format), treat the whole string as the reply with no memory updates —
-- the turn is NEVER lost. Returns replyText, updatesArray.
function AI_Influence.ParseStructuredReply(raw)
    raw = tostring(raw or "")
    if raw == "" then return "", {} end
    if json and json.decode then
        local ok, obj = pcall(json.decode, raw)
        if ok and type(obj) == "table" and type(obj.reply) == "string" and obj.reply ~= "" then
            local updates = (type(obj.memory_updates) == "table") and obj.memory_updates or {}
            local topics = (type(obj.suggestion_topics) == "table") and obj.suggestion_topics or {}
            local commitment = (type(obj.commitment) == "string" and obj.commitment ~= "") and obj.commitment or nil
            local persona = (type(obj.persona) == "string" and obj.persona ~= "") and obj.persona or nil
            local order = (type(obj.order) == "string" and obj.order ~= "") and obj.order or nil
            return obj.reply, updates, topics, commitment, persona, order
        end
    end
    return raw, {}, {}, nil, nil, nil   -- not the contract; show the raw line, extract nothing
end

-- RH-1: build the wheel-suggestions event table {n, l1.., t1..} from reply-piggybacked topics
-- (same shape the bridge lane used, so MD On_suggestions needs no change). Serverless = zero extra calls.
function AI_Influence.SuggestionsOut(topics)
    if type(topics) ~= "table" or #topics == 0 then return nil end
    local out = { n = math.min(3, #topics) }
    for i = 1, out.n do
        local t = tostring(topics[i] or "")
        local label = t
        if #label > 28 then label = string.sub(label, 1, 27) .. "…" end
        out["l" .. i] = label
        out["t" .. i] = t
    end
    return out
end

-- Category -> default fact weight (important categories carry more; Stardew auto-promote handles the rest).
local FACT_WEIGHT = { promise = 6, secret = 6, relationship = 5, preference = 4, fact = 2 }

-- Apply model-proposed memory updates to the card. Provenance = npc_claim (model assertion; ADR: only
-- game_observed may later authorize gameplay, so these stay narrative). Capped per turn to stop spam.
function AI_Influence.ApplyMemoryUpdates(card, updates)
    if type(updates) ~= "table" then return 0 end
    local added = 0
    for _, u in ipairs(updates) do
        if added >= 3 then break end
        if type(u) == "table" and type(u.text) == "string" and u.text ~= "" then
            local cat = tostring(u.category or "fact")
            if not (cat == "promise" or cat == "secret" or cat == "relationship"
                    or cat == "preference" or cat == "fact") then cat = "fact" end
            local w = FACT_WEIGHT[cat] or 2
            if AI_Influence.AddCardFact(card, u.text, "npc_claim", w, cat) then added = added + 1 end
        end
    end
    return added
end

-- P2 self-test (pure Lua, no game entities needed): encode/decode, tamper detection, v1
-- migration, caps + weighted eviction, auto-promote, mint fallback. Logs one PASS/FAIL line.
function AI_Influence.P2SelfTest()
    ensureDjfhe()  -- loads jsonlua; with the P1 probes off nothing else has loaded it yet at boot
    if not (json and json.encode and json.decode) then
        log("P2_SELFTEST SKIPPED: json module unavailable")
        return false
    end
    local pass, fail = 0, 0
    local function check(name, cond)
        if cond then pass = pass + 1 else fail = fail + 1; log("P2 FAIL: " .. name) end
    end
    local c1 = newCard(); c1.turns[1] = { role = "user", text = "hi there" }
    AI_Influence.AddCardFact(c1, "trades energy cells", "game_observed", 3)
    local s1 = AI_Influence.EncodeCard(c1)
    local d1, r1 = AI_Influence.DecodeCard(s1)
    check("roundtrip", d1 ~= nil and r1 == "ok" and d1.turns[1].text == "hi there")
    local tampered = s1:gsub("hi there", "ha THERE")
    local d2, r2 = AI_Influence.DecodeCard(tampered)
    check("tamper", d2 == nil and r2 == "checksum")
    local v1raw = json.encode({ turns = { { role = "user", text = "old" } }, facts = { "knows the player" } })
    local d3, r3 = AI_Influence.DecodeCard(v1raw)
    check("migrate", d3 ~= nil and r3 == "migrated_v1" and type(d3.facts[1]) == "table" and d3.facts[1].p == "npc_claim")
    local d3b, r3b = AI_Influence.DecodeCard(json.encode({ v = 99, turns = {} }))
    check("future", d3b == nil and r3b == "future_version")
    local c4 = newCard()
    for i = 1, 210 do AI_Influence.AddCardFact(c4, "fact " .. i, "game_observed", (i % 20) + 1) end
    check("factcap", #c4.facts <= 200)
    local found20 = false
    for _, f in ipairs(c4.facts) do if f.w == 20 then found20 = true end end
    check("weightkeep", found20)
    local c5 = newCard()
    AI_Influence.AddCardFact(c5, "promised to defend the station", "player_claim", 5, "promise")
    check("promote", c5.imp ~= nil and #c5.imp == 1 and c5.imp[1].t == "promised to defend the station")
    AI_Influence.AddCardFact(c5, "promised to defend the station", "player_claim", 9, "promise")
    check("promote_dedup", #c5.imp == 1 and c5.imp[1].i == 9 and #c5.facts == 1)
    local big = newCard()
    for i = 1, 60 do AI_Influence.AddCardFact(big, string.rep("x", 150) .. i, "model_color", i) end
    local sBig = AI_Influence.EncodeCard(big)
    check("compaction", sBig ~= nil and #sBig <= 6000)
    local tokL = AI_Influence.ResolveNpcToken({ target = "Test Officer", faction = "teladi", role = "manager" })
    check("legacy_token", tokL == "Test Officer|teladi|manager")
    -- U3 trust
    check("tier_boundaries", AI_Influence.TrustTier(-5) == 0 and AI_Influence.TrustTier(0) == 1
        and AI_Influence.TrustTier(30) == 2 and AI_Influence.TrustTier(70) == 3)
    local ct = newCard()
    AI_Influence.AdjustTrust(ct, 200); check("trust_clamp_hi", ct.trust == 100)
    AI_Influence.AdjustTrust(ct, -500); check("trust_clamp_lo", ct.trust == -100)
    check("tone_hostile", AI_Influence.ToneTrustDelta("you are a fool") == -8)
    check("tone_warm", AI_Influence.ToneTrustDelta("thank you kindly") == 4)
    check("tone_neutral", AI_Influence.ToneTrustDelta("what is the price of energy cells") == 1)
    -- migration: a v2 card (no trust) decodes with trust defaulted to 0
    local v2card = { v = 2, turns = {}, facts = {}, imp = {}, aliases = {} }
    v2card.ck = nil
    local v2raw = json.encode(v2card)
    -- recompute a valid v2 checksum by encoding through EncodeCard (stamps v=3 ck); instead test default path:
    local dmig, rmig = AI_Influence.DecodeCard(json.encode({ turns = {}, facts = { "old fact" } }))
    check("trust_migrate_default", dmig ~= nil and dmig.trust == 0)
    -- gating: a secret fact is hidden below tier 2 and shown at tier 2+
    local cg = newCard()
    AI_Influence.AddCardFact(cg, "the patrol schedule is at 0300", "npc_claim", 5, "secret")
    AI_Influence.AddCardFact(cg, "likes energy cells", "npc_claim", 3, "preference")
    local vis0 = AI_Influence.VisibleFacts(cg, 0, 8)
    local vis2 = AI_Influence.VisibleFacts(cg, 2, 8)
    local function has(list, sub) for _, x in ipairs(list) do if string.find(x, sub, 1, true) then return true end end return false end
    check("gate_hidden_low", not has(vis0, "patrol schedule"))
    check("gate_shown_high", has(vis2, "patrol schedule"))
    -- doc 06 bond
    local cb = newCard()
    AI_Influence.AddBond(cb, 10, "boron")   -- boron rate 1.2 -> 12
    check("bond_culture_fast", cb.bond == 12)
    local ct = newCard(); AI_Influence.AddBond(ct, 10, "teladi")   -- teladi rate 0.7 -> 7
    check("bond_culture_slow", ct.bond == 7 and AI_Influence.BondTier(ct.bond) == 0)
    AI_Influence.AddBond(cb, 100, "argon"); check("bond_cap", cb.bond == 100 and AI_Influence.BondTier(cb.bond) == 4)
    local cd = newCard(); cd.bond = 50; cd.bond_day = 5; AI_Influence.DecayBond(cd, 10)   -- 5 days * 2 = -10
    check("bond_decay", cd.bond == 40)
    check("bond_culture_desc", AI_Influence.CultureDescriptor("split") ~= AI_Influence.CultureDescriptor("boron"))
    -- doc 06 bond gate (what the NPC may offer, by tier)
    check("bond_gate_differ", AI_Influence.BondGate(0) ~= AI_Influence.BondGate(4))
    check("bond_gate_commit_top", string.find(AI_Influence.BondGate(4), "standing arrangement", 1, true) ~= nil)
    check("bond_gate_transactional_low", string.find(AI_Influence.BondGate(0), "transactional", 1, true) ~= nil)
    check("bond_gate_clamp", AI_Influence.BondGate(9) == AI_Influence.BondGate(4) and AI_Influence.BondGate(-3) == AI_Influence.BondGate(0))
    -- doc 06 formal commitment (threshold-gated, persists via card)
    check("commit_threshold", AI_Influence.CommitmentAllowed(3) == false and AI_Influence.CommitmentAllowed(4) == true)
    local cc = newCard()
    check("commit_none", AI_Influence.HasCommitment(cc) == false)
    AI_Influence.RecordCommitment(cc, "partnership", 7)
    check("commit_record", AI_Influence.HasCommitment(cc) and cc.pact.kind == "partnership" and cc.pact.day == 7)
    local encc = AI_Influence.EncodeCard(cc); local decc = AI_Influence.DecodeCard(encc)
    check("commit_persist", decc ~= nil and AI_Influence.HasCommitment(decc) and decc.pact.kind == "partnership")
    local _, _, _, cmk = AI_Influence.ParseStructuredReply('{"reply":"Agreed, partner.","commitment":"partnership"}')
    check("commit_parse", cmk == "partnership")
    -- #210 npc initiative (deterministic index + candidate selection)
    local ix = {}
    ix = AI_Influence.UpsertInitiativeEntry(ix, "tokA", { target = "Off A", faction = "teladi" }, { bond = 60, bond_day = 5 })
    ix = AI_Influence.UpsertInitiativeEntry(ix, "tokA", { target = "Off A", faction = "teladi" }, { bond = 70, bond_day = 6 })
    check("init_upsert", #ix == 1 and ix[1].b == 70 and ix[1].bd == 6)
    ix = AI_Influence.UpsertInitiativeEntry(ix, "tokB", { target = "Off B", faction = "boron" }, { bond = 90, bond_day = 4 })
    local pick = AI_Influence.PickInitiativeCandidate(ix, 10)   -- both neglected+bonded; B has more bond
    check("init_pick_best", pick ~= nil and pick.tk == "tokB")
    local low = { { tk = "l", b = 40, bd = 1, id = 0 } }
    check("init_pick_low", AI_Influence.PickInitiativeCandidate(low, 10) == nil)
    local recent = { { tk = "r", b = 90, bd = 10, id = 0 } }
    check("init_pick_recent", AI_Influence.PickInitiativeCandidate(recent, 10) == nil)   -- chatted today, not neglected
    local cooled = { { tk = "c", b = 90, bd = 5, id = 9 } }
    check("init_cooldown", AI_Influence.PickInitiativeCandidate(cooled, 10) == nil)   -- outreach 1 unit ago < 3
    -- #211 death history (gates + wire parse)
    local gl = AI_Influence.parseBackendConfig("name=ARG Frigate Resolute|id=ABC-123|sector=Argon Prime|attacker=Xenon")
    check("obit_parse", gl.name == "ARG Frigate Resolute" and gl.id == "ABC-123" and gl.sector == "Argon Prime" and gl.attacker == "Xenon")
    check("obit_gate_named", AI_Influence.ObituaryEligible("Resolute", 1000, 0) == true)
    check("obit_gate_unnamed", AI_Influence.ObituaryEligible("", 1000, 0) == false)
    check("obit_gate_cooldown", AI_Influence.ObituaryEligible("Resolute", 100, 0) == false)   -- 100s < 300s cooldown
    -- #212 world-events ledger
    local ev = {}
    ev = AI_Influence.AddWorldEvent(ev, "war", "Argon Federation", "Teladi Company", "war", 3)
    ev = AI_Influence.AddWorldEvent(ev, "crisis", "TEL Trading Station", "Argon Prime", "power_crisis", 4)
    local lines = AI_Influence.WorldEventLines(ev, 5, { psector = "Argon Prime" })
    check("worldev_lines", #lines == 2 and string.find(lines[1], "power crisis", 1, true) ~= nil
        and string.find(lines[2], "war has broken out", 1, true) ~= nil)   -- newest first
    -- #214 knowledge gating: crises are LOCAL (sector match), diplomacy is galaxy-common
    local far = AI_Influence.WorldEventLines(ev, 5, { psector = "Ianamus Zura" })
    check("worldev_gate_local", #far == 1 and string.find(far[1], "war has broken out", 1, true) ~= nil)
    check("worldev_gate_common", #AI_Influence.WorldEventLines(ev, 5) == 1)   -- no viewer: crises hidden, wars visible
    for i = 1, 40 do ev = AI_Influence.AddWorldEvent(ev, "shift", "A" .. i, "B" .. i, "friendly", i) end
    check("worldev_cap", #ev == 30)
    check("worldev_topk", #AI_Influence.WorldEventLines(ev, 5) == 5)
    check("worldev_empty", #AI_Influence.WorldEventLines({}, 5) == 0)
    -- #213 persona self-generation
    local _, _, _, _, pp = AI_Influence.ParseStructuredReply('{"reply":"Hail.","persona":"gruff veteran dock chief"}')
    check("persona_parse", pp == "gruff veteran dock chief")
    local _, _, _, _, pn = AI_Influence.ParseStructuredReply('{"reply":"Hail."}')
    check("persona_parse_absent", pn == nil)
    local cp = newCard(); cp.persona = "wry teladi accountant"
    local encp = AI_Influence.EncodeCard(cp); local decp = AI_Influence.DecodeCard(encp)
    check("persona_roundtrip", decp ~= nil and decp.persona == "wry teladi accountant")   -- persona is IN the checksum
    -- #215 serverless threat assessment
    local th = {}
    AI_Influence.AccumulateThreat(th, "teladi", "SectorX", 1, 100)
    local tm = AI_Influence.AccumulateThreat(th, "teladi", "SectorX", 2, 200)
    check("threat_accumulate", tm == 3)
    check("threat_window_reset", AI_Influence.AccumulateThreat(th, "teladi", "SectorX", 1, 200 + 901) == 1)
    check("threat_scoped", AI_Influence.AccumulateThreat(th, "argon", "SectorX", 1, 100) == 1)   -- other faction separate
    -- #217 conversational orders (parse + deterministic gate)
    local _, _, _, _, _, od = AI_Influence.ParseStructuredReply('{"reply":"Aye, starting patrol.","order":"patrol"}')
    check("order_parse", od == "patrol")
    local _, _, _, _, _, od2 = AI_Influence.ParseStructuredReply('{"reply":"Hello."}')
    check("order_parse_absent", od2 == nil)
    -- #221 diplo validator (the band that keeps the LLM honest)
    local dv = AI_Influence.ValidateDiploDecision('{"statement":"Talks continue.","action":"improve","relation_delta":0.5}')
    check("diplo_clamp", dv ~= nil and dv.delta == 0.05)
    local dh = AI_Influence.ValidateDiploDecision('{"statement":"S","action":"hold","relation_delta":-0.04}')
    check("diplo_hold_zero", dh ~= nil and dh.delta == 0)
    check("diplo_reject_action", AI_Influence.ValidateDiploDecision('{"statement":"x","action":"declare_total_war","relation_delta":0.01}') == nil)
    check("diplo_reject_junk", AI_Influence.ValidateDiploDecision('not json at all') == nil)
    -- #226 semantic recall pure checks
    local bt = AI_Influence.B64Encode("hello!"); check("sem_b64", AI_Influence.B64Decode(bt) == "hello!")
    local qv = AI_Influence.QuantizeVec({ 0.5, -0.25, 0.1 })
    local dq = AI_Influence.DequantizeVec(qv)
    check("sem_quant", dq ~= nil and math.abs(dq[1] - 0.5) < 0.01 and math.abs(dq[2] + 0.25) < 0.01)
    check("sem_cosine", AI_Influence.Cosine({1,0,0},{1,0,0}) > 0.999 and AI_Influence.Cosine({1,0,0},{0,1,0}) < 0.001)
    check("sem_overlap", AI_Influence.OverlapScore("deliver energy cells", "promised to deliver energy cells")
        > AI_Influence.OverlapScore("deliver energy cells", "likes teladi tea"))
    local rcard = { imp = { { t = "promised to deliver energy cells", i = 5, g = 0 },
                           { t = "secret smuggling route", i = 9, g = 2 },
                           { t = "likes teladi tea", i = 2, g = 0 } } }
    local rr = AI_Influence.SemanticRecall(rcard, 0, nil, nil, "what about the energy cells delivery", 2)
    check("sem_recall_fallback", #rr >= 1 and rr[1] == "promised to deliver energy cells")
    local rr2 = AI_Influence.SemanticRecall(rcard, 0, nil, nil, "tell me the smuggling secret", 3)
    local leaked = false
    for _, t2 in ipairs(rr2) do if t2 == "secret smuggling route" then leaked = true end end
    check("sem_recall_tiergate", leaked == false)   -- tier-0 must not surface the gated secret
    -- #224 aic_http pure checks (transport correctness without any network)
    local H = rawget(_G, "AIC_HTTP")
    check("http_present", H ~= nil)
    if H then
        local u = H.parseUrl("http://127.0.0.1:4315/v1/chat/completions")
        check("http_url", u ~= nil and u.host == "127.0.0.1" and u.port == 4315 and u.path == "/v1/chat/completions")
        local rq = H.buildRequest("POST", "http://h:1/p", { ["Content-Type"] = "application/json" }, "{}")
        check("http_reqbytes", rq ~= nil and rq:find("POST /p HTTP/1.1", 1, true) == 1
            and rq:find("Content%-Length: 2") ~= nil and rq:sub(-2) == "{}")
        local CRLF = string.char(13) .. string.char(10)
        local chunkedSample = "4" .. CRLF .. "Wiki" .. CRLF .. "5" .. CRLF .. "pedia" .. CRLF .. "0" .. CRLF .. CRLF
        check("http_chunked", H.decodeChunked(chunkedSample) == "Wikipedia")
        check("http_chunked_partial", H.decodeChunked("4" .. CRLF .. "Wik") == nil)
    end
    check("diplo_ptarget_ok", AI_Influence.ValidatePlayerDiploTarget("teladi", "argon") == "argon")
    check("diplo_ptarget_self", AI_Influence.ValidatePlayerDiploTarget("teladi", "teladi") == nil)
    check("diplo_ptarget_protected", AI_Influence.ValidatePlayerDiploTarget("teladi", "xenon") == nil
        and AI_Influence.ValidatePlayerDiploTarget("teladi", "player") == nil
        and AI_Influence.ValidatePlayerDiploTarget("teladi", "made_up_faction") == nil)
    check("order_gate_follow", AI_Influence.OrderAllowed({ npc_owned = "1", npc_ship = "S" }, "follow") == true
        and AI_Influence.OrderAllowed({ npc_owned = "0", npc_ship = "S" }, "follow") == false)
    check("order_gate_slice2", AI_Influence.OrderAllowed({ npc_owned = "1", npc_ship = "S" }, "return") == true
        and AI_Influence.OrderAllowed({ npc_owned = "1", npc_ship = "S" }, "hold") == true
        and AI_Influence.OrderAllowed({ npc_owned = "1", npc_ship = "S" }, "attack") == true
        and AI_Influence.OrderAllowed({ npc_owned = "0", npc_ship = "S" }, "attack") == false)
    check("order_gate", AI_Influence.OrderAllowed({ npc_owned = "1", npc_ship = "ARG Frigate" }, "patrol") == true
        and AI_Influence.OrderAllowed({ npc_owned = "0", npc_ship = "TEL Trader" }, "patrol") == false
        and AI_Influence.OrderAllowed({ npc_owned = "1", npc_ship = "" }, "patrol") == false
        and AI_Influence.OrderAllowed({ npc_owned = "1", npc_ship = "ARG Frigate" }, "self_destruct") == false)
    check("threat_guard", AI_Influence.ThreatOfferable("teladi", "xenon") == true
        and AI_Influence.ThreatOfferable("xenon", "argon") == false
        and AI_Influence.ThreatOfferable("player", "xenon") == false
        and AI_Influence.ThreatOfferable("teladi", "teladi") == false)
    -- RH-1 serverless suggestions
    local rr3, uu3, tt3 = AI_Influence.ParseStructuredReply('{"reply":"Hi.","memory_updates":[],"suggestion_topics":["Ask about trade","Ask about the war","Say goodbye"]}')
    check("topics_parse", rr3 == "Hi." and type(tt3) == "table" and #tt3 == 3)
    local so = AI_Influence.SuggestionsOut(tt3)
    check("topics_out", so ~= nil and so.n == 3 and so.l1 == "Ask about trade" and so.t3 == "Say goodbye")
    check("topics_empty", AI_Influence.SuggestionsOut({}) == nil)
    -- serverless default is bridge OFF (cutover 2026-07-21); prove the default AND the toggle round-trips, then restore
    local savedBridge = AI_Influence.BRIDGE_ENABLED
    AI_Influence.SetBridgeEnabled(true);  local bridgeOn  = AI_Influence.BRIDGE_ENABLED == true
    AI_Influence.SetBridgeEnabled(false); local bridgeOff = AI_Influence.BRIDGE_ENABLED == false
    AI_Influence.BRIDGE_ENABLED = savedBridge
    check("bridge_gate_flag", savedBridge == false and bridgeOn and bridgeOff and type(AI_Influence.SetBridgeEnabled) == "function")
    -- U2 backend routing (restore provider after)
    local savedP, savedO = AI_Influence.backendProvider, AI_Influence.backendOverride
    AI_Influence.backendProvider = "player2"; AI_Influence.backendOverride = {}
    local bp = AI_Influence.ActiveBackend()
    check("backend_player2", bp.provider == "player2" and bp.auth == "player2" and string.find(bp.url, "4315", 1, true) ~= nil)
    AI_Influence.backendSet("deepseek", { key = "sk-test" })
    local bd = AI_Influence.ActiveBackend()
    check("backend_deepseek", bd.provider == "deepseek" and bd.auth == "bearer" and bd.key == "sk-test" and bd.model == "deepseek-chat")
    AI_Influence.backendSet("ollama", { base = "http://127.0.0.1:9999", model = "mistral" })
    local bo = AI_Influence.ActiveBackend()
    check("backend_override", bo.provider == "ollama" and string.find(bo.url, "9999", 1, true) ~= nil and bo.model == "mistral" and bo.auth == "none")
    -- #209 remaining lanes + config parse + persist path (persist uses player2 so the save is never left on a test backend)
    -- NB: backendSet MERGES overrides, so clear stale base/model/key from the ollama check before resolving a clean preset.
    AI_Influence.backendOverride = {}
    AI_Influence.backendSet("koboldcpp", {})
    local bk = AI_Influence.ActiveBackend()
    check("backend_koboldcpp", bk.provider == "koboldcpp" and bk.auth == "none" and string.find(bk.url, "5001", 1, true) ~= nil)
    AI_Influence.backendOverride = {}
    AI_Influence.backendSet("openrouter", { key = "or-key" })
    local bor = AI_Influence.ActiveBackend()
    check("backend_openrouter", bor.provider == "openrouter" and bor.auth == "bearer" and bor.key == "or-key" and string.find(bor.url, "openrouter.ai", 1, true) ~= nil)
    local pc = AI_Influence.parseBackendConfig("provider=ollama|base=http://127.0.0.1:9|model=mistral|key=")
    check("backend_config_parse", pc.provider == "ollama" and pc.base == "http://127.0.0.1:9" and pc.model == "mistral")
    AI_Influence.backendSetAndPersist("player2", { base = "", model = "", key = "" })   -- exercises the MD persist path with a safe value
    check("backend_persist_path", AI_Influence.backendProvider == "player2")
    AI_Influence.backendProvider, AI_Influence.backendOverride = savedP, savedO
    -- P4a structured-reply parse + memory apply
    local rr, uu = AI_Influence.ParseStructuredReply('{"reply":"Hello there.","memory_updates":[{"text":"player likes profit","category":"preference"}]}')
    check("structured_parse", rr == "Hello there." and type(uu) == "table" and #uu == 1)
    local rr2 = AI_Influence.ParseStructuredReply("just a plain sentence, not json")
    check("structured_degrade", rr2 == "just a plain sentence, not json")
    local c6 = newCard()
    local n6 = AI_Influence.ApplyMemoryUpdates(c6, { { text = "promised to pay 10000", category = "promise" }, { text = "likes profit", category = "preference" } })
    check("apply_updates", n6 == 2 and #c6.facts == 2 and #c6.imp == 2)  -- promise AND preference both auto-promote
    local c7 = newCard()
    local n7 = AI_Influence.ApplyMemoryUpdates(c7, { {text="a"},{text="b"},{text="c"},{text="d"},{text="e"} })
    check("apply_cap3", n7 == 3)
    log("P2_SELFTEST pass=" .. pass .. " fail=" .. fail)
    writeToLogbook("AI Influence P2 selftest", "pass=" .. tostring(pass) .. " fail=" .. tostring(fail))
    return fail == 0
end

-- P1d continuity probe (self-evaluating, rides the load trigger): first run teaches a code phrase
-- through the REAL SendDirectChat path; after save+reload the same path must recall it from the card.
-- P4a end-to-end probe: send a fact-revealing line through the REAL SendDirectChat (structured
-- output), then re-load the card and log whether a durable fact was extracted + stored.
function AI_Influence.U1GroundingProbe(param)
    local g = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "="); if eq then g[string.sub(pair,1,eq-1)] = string.sub(pair,eq+1) end
    end
    log("U1_PROBE grounding standing=" .. tostring(g.standing) .. " psector=" .. tostring(g.psector) .. " nearby=" .. tostring(g.nearby))
    local ctx = { target = "Grounding Probe Officer", faction = "teladi", role = "manager",
                  standing = g.standing, psector = g.psector, nearby = g.nearby }
    AI_Influence.StoreCard("Grounding Probe Officer|teladi|manager", newCard())
    AI_Influence.SendDirectChat(ctx, "In one sentence, what sector are we in and how do you regard me?",
        function(ok, reply)
            local sec = tostring(g.psector or "")
            local hit = (sec ~= "" and reply and string.find(tostring(reply), sec, 1, true) ~= nil)
            log("U1_PROBE reply ok=" .. tostring(ok) .. " sector_referenced=" .. tostring(hit) .. " reply=" .. tostring(reply))
            writeToLogbook("AI Influence U1 grounding", "sector_ref=" .. tostring(hit) .. " | " .. tostring(reply))
        end)
end

function AI_Influence.MemoryExtractProbe()
    local ctx = { target = "Memory Probe Officer", faction = "teladi", role = "manager" }
    local token = tostring(ctx.target) .. "|" .. tostring(ctx.faction) .. "|" .. tostring(ctx.role)
    -- start clean so the count is unambiguous
    AI_Influence.StoreCard(token, newCard())
    AI_Influence.SendDirectChat(ctx, "My name is Captain Vega and I always prefer the most profitable deal.",
        function(ok, reply)
            log("P4_EXTRACT reply ok=" .. tostring(ok) .. " reply=" .. tostring(reply))
            AI_Influence.LoadCard(token, function(card)
                local nf = (type(card) == "table" and card.facts) and #card.facts or 0
                local first = (nf > 0) and tostring(card.facts[1].t) or "(none)"
                log("P4_EXTRACT verify facts=" .. tostring(nf) .. " first=" .. first)
                writeToLogbook("AI Influence P4 extract", "facts=" .. tostring(nf) .. " | " .. first)
            end)
        end)
end

function AI_Influence.ContinuityProbe()
    local ctx = { target = "Continuity Probe Officer", faction = "teladi", role = "manager" }
    local token = ctx.target .. "|" .. ctx.faction .. "|" .. ctx.role
    AI_Influence.LoadCard(token, function(card)
        local hasTurns = (type(card) == "table") and (type(card.turns) == "table") and (#card.turns > 0)
        if not hasTurns then
            AI_Influence.SendDirectChat(ctx, "Please remember the code phrase 'purple nebula seven'. Confirm you will remember it.",
                function(ok, reply)
                    log("CONTINUITY_P1 taught: ok=" .. tostring(ok) .. " reply=" .. tostring(reply))
                    if ok then writeToLogbook("AI Influence (P1d taught)", tostring(reply)) end
                end)
        else
            AI_Influence.SendDirectChat(ctx, "What code phrase did I ask you to remember earlier? State it exactly.",
                function(ok, reply)
                    local hit = ok and tostring(reply):lower():find("purple nebula", 1, true) ~= nil
                    log("CONTINUITY_P1 verdict: recalled=" .. tostring(hit) .. " reply=" .. tostring(reply))
                    writeToLogbook("AI Influence (P1d verdict)", (hit and "RECALLED: " or "MISSED: ") .. tostring(reply))
                end)
        end
    end)
end

-- P1a proof harness: fire one direct completion and drop the reply into the logbook, so a no-bridge
-- call can be confirmed in-game from the debuglog + logbook without any UI wiring. Triggered by the
-- MD event "AIChat.direct_probe" (param = optional user line).
-- P1 proof scaffolding: flip true to re-arm the load-time probes (2 Player2 calls per game load).
local P1_LOAD_PROBES = false
-- P2 selftest: zero Player2 calls (pure Lua) — cheap enough to run on every load; flip off after #194.
local P2_PROBES = false  -- #226 semantic recall: verified in-game pass=93 fail=0
-- #226 rig PROVEN 2026-07-22: "semantic recall n=4 embedded_new=4" -> the NPC answered with the exact
-- seeded promise ("You promised to deliver 500 energy cells") via Player2 /v1/embeddings + our transport.
local RECALL_PROBE = false
function AI_Influence.RecallProbe()
    local ctx = { target = "Recall Probe Officer", faction = "teladi", role = "manager" }
    local token = ctx.target .. "|" .. ctx.faction .. "|" .. ctx.role
    local seed = { v = 3, turns = {}, facts = {}, imp = {}, aliases = {}, trust = 0 }
    AI_Influence.AddCardFact(seed, "the player promised to deliver 500 energy cells", "player_claim", 8, "promise")
    AI_Influence.AddCardFact(seed, "the player prefers hull parts contracts", "npc_claim", 4, "preference")
    AI_Influence.AddCardFact(seed, "the player is a trusted associate of station command", "npc_claim", 6, "relationship")
    AI_Influence.AddCardFact(seed, "the player dislikes long docking queues", "player_claim", 3, "preference")
    AI_Influence.StoreCard(token, seed)
    AI_Influence.SendDirectChat(ctx, "Remind me what I promised to deliver to you?", function(ok, reply)
        log("RECALL_PROBE reply ok=" .. tostring(ok) .. " reply=" .. tostring(reply):sub(1, 120))
    end)
end
-- #221 rig PROVEN 2026-07-22: full LLM-decides loop ran live — 'AIC DIPLO LLM-DECIDED teladi vs argon
-- action=improve delta=0.04 rel -0.5 -> -0.46' (Player2 chose the action AND delta; validator clamped;
-- real set_faction_relation moved the galaxy). DIPLO_CLEANUP below closes the seeded test event once.
local DIPLO_PROBE = false
local DIPLO_CLEANUP = false  -- test event closed 2026-07-22
-- U1 PROVEN 2026-07-22: full round lifecycle live — hatikvah vs freesplit, alternating speakers,
-- "round 1 COMPLETE; analysis scheduled" -> "analysis: CONTINUE -> round 2"; legacy migration fired;
-- failure lane wired. Re-arm to re-test.
local PAIR_TEST = false
local U1_CLEAN_STALE = false
-- #217 rig: dispatch a patrol player_order through the REAL MD lane (falls back to a real player fight
-- ship when no conversation NPC is in scope). Proven 2026-07-21: create_order landed on GVS-020
-- 'Kestrel Vanguard' in Hewa's Twin I. #218 proven: all four verbs executed (patrol/hold=protect,
-- return=MoveGeneric to TEL Defence Platform, attack=guarded no-Xenon branch). Re-arm to re-test.
local PLAYER_ORDER_PROBE = false
-- #219 rig: one follow dispatch through the REAL lane. Proven 2026-07-22: on-foot fallback ->
-- GVS-020 MoveGeneric to the player's sector; Escort branch spike-proven (GVS-020 escorting BIX-033).
local FOLLOW_PROBE = false
-- #215 rig: 3 synthetic hostile events (teladi under xenon attack) must cross the threshold and mint a REAL
-- defense contract through the proven Offer_contract lifecycle. Proven 2026-07-21 (offer at exactly
-- 250,000 Cr deterministic price, zero errors after the objective.custom fix); re-arm to re-test.
local THREAT_PROBE = false
-- #213 rig: fresh card + one REAL SendDirectChat — the reply must mint a persona onto the card.
-- Proven 2026-07-21 ("cautious profit-driven Teladi manager" minted + persisted); re-arm to re-test.
local PERSONA_PROBE = false
function AI_Influence.PersonaProbe()
    local ctx = { target = "Persona Probe Officer", faction = "teladi", role = "manager" }
    local token = ctx.target .. "|" .. ctx.faction .. "|" .. ctx.role
    AI_Influence.StoreCard(token, { v = 3, turns = {}, facts = {}, imp = {}, aliases = {}, trust = 0 })
    AI_Influence.SendDirectChat(ctx, "Introduce yourself briefly.", function(ok, reply)
        log("PERSONA_PROBE reply ok=" .. tostring(ok))
        AI_Influence.LoadCard(token, function(card)
            local p = (type(card) == "table") and card.persona or nil
            log("PERSONA_PROBE verify persona=" .. tostring(p))
        end)
    end)
end
-- #212 rig: seeds two synthetic world events through the REAL OnWorldEvent lane (persist via StoreCard).
-- Proven 2026-07-21 (cross-save hydration n=4 after F5/F9); re-arm to re-test.
local WORLDEV_PROBE = false
-- #210 rig: seeds a high-bond neglected NPC + index, then runs the REAL InitiativePass (one live LLM call,
-- delivery via CommsIncoming). Proven 2026-07-21 (delivered 166 chars + MD comms confirm); re-arm to re-test.
local INITIATIVE_PROBE = false
-- #211 rig: fires the REAL OnShipLost with a synthetic loss (one live LLM call, CommsIncoming delivery).
-- Proven 2026-07-21 (delivered 289 chars + MD comms confirm); re-arm to re-test.
local OBITUARY_PROBE = false
function AI_Influence.InitiativeProbe()
    local token = "Initiative Probe Officer|teladi|manager"
    -- clock-independent rig: fixed day numbers (bd=7, pass at today=10 -> neglect 3, cooldown clear),
    -- so the probe works even when GetCurrentGameTime is 0/unavailable at load-probe time
    local seed = { v = 3, turns = {}, facts = {}, imp = {}, aliases = {}, trust = 0,
                   bond = 85, bond_day = 7 }
    AI_Influence.StoreCard(token, seed)
    AI_Influence._initIndex = AI_Influence.UpsertInitiativeEntry({},
        token, { target = "Initiative Probe Officer", faction = "teladi" }, seed)
    log("INITIATIVE_PROBE seeded bond=85 bd=7; running pass at today=10")
    AI_Influence.InitiativePass(10)
end
local P4_EXTRACT_PROBE = false  -- proven #195 (facts=1 from a real reply); re-arm to re-test
U1_GROUNDING_PROBE = false  -- one call on load: proves MD grounding reads + LLM consumes them (#196); off after
function AI_Influence.DirectProbe(userLine)
    if P2_PROBES then pcall(AI_Influence.P2SelfTest) end
    if INITIATIVE_PROBE then pcall(AI_Influence.InitiativeProbe) end
    if OBITUARY_PROBE then
        pcall(AI_Influence.OnShipLost, "name=ARG Probe Frigate Steadfast|id=SFT-211|sector=Argon Prime|attacker=Xenon")
    end
    if WORLDEV_PROBE then
        pcall(AI_Influence.OnWorldEvent, "kind=war|a=Probe Faction A|b=Probe Faction B|to=war")
        pcall(AI_Influence.OnWorldEvent, "kind=crisis|a=Probe Station|b=Probe Sector|to=power_crisis")
    end
    if PERSONA_PROBE then pcall(AI_Influence.PersonaProbe) end
    if RECALL_PROBE then pcall(AI_Influence.RecallProbe) end
    if DIPLO_PROBE and AddUITriggeredEvent then
        pcall(function() AddUITriggeredEvent("ai_influence", "diplo_open_test", { a = "teladi", b = "argon", kind = "tension" }) end)
        log("DIPLO_PROBE opened teladi/argon tension event")
    end
    if DIPLO_CLEANUP and AddUITriggeredEvent then
        pcall(function() AddUITriggeredEvent("ai_influence", "diplo_close_test", { a = "teladi", b = "argon" }) end)
        log("DIPLO_CLEANUP closed the seeded test event")
    end
    if U1_CLEAN_STALE and AddUITriggeredEvent then
        for _, pr in ipairs({ {"split","pioneers"}, {"buccaneers","boron"}, {"holyorder","paranid"}, {"holyorder","split"} }) do
            pcall(function() AddUITriggeredEvent("ai_influence", "diplo_close_test", { a = pr[1], b = pr[2] }) end)
        end
        log("U1_CLEAN_STALE closed soak-era events")
    end
    if PAIR_TEST and AddUITriggeredEvent then
        pcall(function() AddUITriggeredEvent("ai_influence", "diplo_pair_test", { go = "1" }) end)
        log("PAIR_TEST dispatched immediate pair selection")
    end
    if FOLLOW_PROBE and AddUITriggeredEvent then
        pcall(function() AddUITriggeredEvent("ai_influence", "player_order", { order = "follow" }) end)
        log("FOLLOW_PROBE dispatched")
    end
    if PLAYER_ORDER_PROBE and AddUITriggeredEvent then
        for _, v in ipairs({ "patrol", "return", "hold", "attack" }) do
            pcall(function() AddUITriggeredEvent("ai_influence", "player_order", { order = v }) end)
        end
        log("PLAYER_ORDER_PROBE dispatched patrol/return/hold/attack")
    end
    if THREAT_PROBE then
        -- unique-suffixed sector => fresh job id each run (Registry dedup would silently skip a repeat);
        -- table address is unique per Lua reload (GetCurrentGameTime is 0 this early in a load)
        local psec = "Threat Probe Sector " .. tostring({}):gsub("table: 0?x?", ""):sub(-6)
        for _ = 1, 3 do
            pcall(AI_Influence.ReportHostile, "attacker=xenon|victim=teladi|sector=" .. psec .. "|kind=ship_destroyed|magnitude=1|order=|save_id=probe")
        end
    end
    if P4_EXTRACT_PROBE then pcall(AI_Influence.MemoryExtractProbe) end
    if not P1_LOAD_PROBES then log("load probes disabled (P1 proven #193)") return end
    -- P1d: the continuity probe rides the load trigger (it subsumes the P1b card round-trip).
    pcall(AI_Influence.ContinuityProbe)
    local msg = (userLine and tostring(userLine) ~= "") and tostring(userLine)
        or "In one short sentence, greet a Teladi trade captain who just docked."
    AI_Influence.SendDirect(
        { { role = "system", content = "You are a terse Teladi station representative in the X4 galaxy. One sentence." },
          { role = "user", content = msg } },
        { max_tokens = 80 },
        function(ok, reply, usage, err)
            if ok then
                log("DIRECT_PROBE OK: " .. tostring(reply))
                writeToLogbook("AI Influence (direct :4315)", tostring(reply))
            else
                log("DIRECT_PROBE FAIL: " .. tostring(err))
                writeToLogbook("AI Influence (direct :4315)", "PROBE FAILED: " .. tostring(err))
            end
        end)
end

-- ---- NPC registry: index encounterable/named NPCs + the player into the bridge -------------
-- Param string (from MD): "save_id=...|player=...|npcs=Name~faction;Name~faction;". Posted to
-- /v1/npcs/index, which upserts identity WITHOUT clobbering any existing Player2 binding.
function AI_Influence.IndexNpcs(param)
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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

-- #215 (task-14 re-home slice 3): the bridge's core DECISION behavior, deterministic and serverless.
-- Hostile events accumulate per (victim, sector); crossing the threshold within the window mints ONE
-- defensive patrol contract via the PROVEN MintContract→Offer_contract lane (Registry dedups by job id).
local THREAT_OPORD_MIN = 3      -- total magnitude to trigger a defensive contract
local THREAT_WINDOW_S = 900     -- accumulation window; stale threats reset
AI_Influence._threats = AI_Influence._threats or {}
function AI_Influence.AccumulateThreat(threats, victim, sector, magnitude, nowS)
    threats = (type(threats) == "table") and threats or {}
    local key = tostring(victim) .. "|" .. tostring(sector)
    local t = threats[key]
    nowS = tonumber(nowS) or 0
    if not t or (nowS - (tonumber(t.last) or 0)) > THREAT_WINDOW_S then t = { m = 0, last = nowS } end
    t.m = (tonumber(t.m) or 0) + (tonumber(magnitude) or 1)
    t.last = nowS
    threats[key] = t
    return t.m
end
-- true when this victim faction merits a defense offer (mirrors the #204 trading-faction guard)
function AI_Influence.ThreatOfferable(victim, attacker)
    victim = tostring(victim or ""); attacker = tostring(attacker or "")
    if victim == "" or victim == attacker then return false end
    if victim == "xenon" or victim == "khaak" or victim == "player" then return false end
    return true
end

-- #66: a REAL combat event (a watched/ordered ship killed or was destroyed) -> serverless threat
-- assessment (above) + optional bridge POST. param = "attacker=..|victim=..|sector=..|kind=..|magnitude=..".
function AI_Influence.ReportHostile(param)
    local ctx = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "=")
        if eq then ctx[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1) end
    end
    -- serverless decision lane (always on): accumulate; mint a defense contract on threshold
    if AI_Influence.ThreatOfferable(ctx.victim, ctx.attacker) then
        local nowS = 0
        pcall(function() if GetCurrentGameTime then nowS = GetCurrentGameTime() end end)
        local total = AI_Influence.AccumulateThreat(AI_Influence._threats, ctx.victim, ctx.sector, ctx.magnitude, nowS)
        log("threat " .. tostring(ctx.victim) .. "@" .. tostring(ctx.sector) .. " m=" .. tostring(total))
        if total >= THREAT_OPORD_MIN then
            AI_Influence._threats[tostring(ctx.victim) .. "|" .. tostring(ctx.sector)] = nil   -- reset after offer
            -- #221b PostCombatEventCreator port: sustained NPC-vs-NPC hostilities open a diplomatic event
            if AI_Influence.ThreatOfferable(ctx.attacker, ctx.victim) and AddUITriggeredEvent then
                pcall(function() AddUITriggeredEvent("ai_influence", "diplo_open",
                    { a = tostring(ctx.victim), b = tostring(ctx.attacker), kind = "hostilities" }) end)
                log("diplo event opened from combat: " .. tostring(ctx.victim) .. " vs " .. tostring(ctx.attacker))
            end
            local reward = 100000 + 50000 * total
            AI_Influence.MintContract("job=def_" .. tostring(ctx.victim) .. "_" .. tostring(ctx.sector)
                .. "|faction=" .. tostring(ctx.victim)
                .. "|title=Defense Contract: " .. tostring(ctx.sector)
                .. "|summary=" .. tostring(ctx.victim) .. " forces are under sustained attack near " .. tostring(ctx.sector)
                .. " and will pay for armed patrol support."
                .. "|reward=" .. tostring(reward) .. "|verb=patrol|target=" .. tostring(ctx.attacker)
                .. "|sector=" .. tostring(ctx.sector))
        end
    end
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
    local req = newRequest("POST")
    if not req then return end
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

-- P8/contracts re-home (#204): deterministic serverless contract minter. MD raises AIChat.mint_contract with
-- "job=...|faction=...|title=...|summary=...|reward=...|verb=...|target=...|sector=..." — this forwards it to
-- the PROVEN Offer_contract lifecycle (contract_offer event), no bridge, no LLM. Reward is in bridge-credits
-- (Offer_contract multiplies by 1Cr internally). One contract per unique job id (Registry dedup in MD).
function AI_Influence.MintContract(param)
    if not AddUITriggeredEvent then return end
    local c = {}
    for pair in string.gmatch(tostring(param or ""), "([^|]+)") do
        local eq = string.find(pair, "="); if eq then c[string.sub(pair,1,eq-1)] = string.sub(pair,eq+1) end
    end
    if not c.job or c.job == "" or not c.faction or c.faction == "" then return end
    pcall(function()
        AddUITriggeredEvent("ai_influence", "contract_offer", {
            job_id = c.job, faction = c.faction,
            title = c.title or "War Effort Contract",
            summary = c.summary or "A faction at war is paying for combat support along its contested frontier.",
            reward = tonumber(c.reward) or 250000,
            task_verb = c.verb or "patrol", task = c.summary,
            target = c.target, sector = c.sector, mtype = "fight", otype = "custom",
        })
    end)
    log("MintContract -> contract_offer job=" .. tostring(c.job) .. " fid=" .. tostring(c.faction))
end
local function onMintContract(_, param) AI_Influence.MintContract(param) end

-- OPORD execution report: the protectposition aiscript raises AIChat.opord_order_event with
-- "event=arrived|lease=<id>" (or failed/interrupted) → POST observed execution to the bridge so the lease/task
-- state is grounded in what the ship actually did. save_id rides AI_Influence._saveId (set on the relations tick).
function AI_Influence.OpordOrderEvent(param)
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
    local out = {}
    AI_Influence._facNoRep = AI_Influence._facNoRep or {}
    for _, fid in ipairs(FACTION_LIST) do
        pcall(function()
            if AI_Influence._facNoRep[fid] then return end
            local rep = C.GetFactionRepresentative(fid)
            if rep == nil or not tonumber(rep) or tonumber(rep) == 0 then AI_Influence._facNoRep[fid] = true end
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
                        if IsValidComponent and not IsValidComponent(obj) then return end
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
                                            pcall(function()
                                                local scid = ConvertStringToLuaID(ck)
                                                if scid and (not IsValidComponent or IsValidComponent(scid)) then
                                                    sm = GetComponentData(scid, "macro")
                                                end
                                            end)
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
-- Sector NAME from any object: the "sector" property IS the sector name string (vanilla menu_map.lua:9302
-- pairs "sectorid"+"sector" as id+name). Never feed the name back through ConvertStringToLuaID — that
-- resolves to component 0 and the engine logs one error per call.
local function aic_sectorName(comp)
    local sec = ""
    pcall(function()
        local sc = GetComponentData(comp, "sector")
        if type(sc) == "string" then sec = sc end
    end)
    return sec
end
-- ALL FACTIONS each tick (small per-faction caps + per-faction cursors `_npcStOff`/`_npcShOff`). Every NPC's
-- last_active thus refreshes once per full cycle, so the bridge deceased-sweep can treat "not re-seen for > a
-- cycle" as gone (its ship/station was destroyed). Ground truth galaxy-wide — GetContained* is NOT fog-of-war
-- gated (proven by SyncFleets reporting fleets for factions the player is nowhere near).
function AI_Influence.SyncNpcCensus(saveId)
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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
    if not AI_Influence.BRIDGE_ENABLED then return end  -- ADR-009 bridge gate
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

-- #209: MD pushes the persisted backend choice on every load; apply it to the serverless router.
local function onBackendConfig(_, param)
    local g = AI_Influence.parseBackendConfig(param)
    if g.provider and g.provider ~= "" then
        AI_Influence.backendSet(g.provider, { base = g.base, model = g.model, key = g.key })
    end
    local be = AI_Influence.ActiveBackend()
    log("backend_config applied provider=" .. tostring(be.provider) .. " url=" .. tostring(be.url)
        .. " model=" .. tostring(be.model))
    -- #212: this fires once per load after MD is ready — hydrate the world-events ledger here
    pcall(AI_Influence.HydrateWorldEvents)
end

local function init()
    RegisterEvent("AIChat.open", onOpenCommLink)
    RegisterEvent("AIChat.direct_probe", function(_, param) AI_Influence.DirectProbe(param) end)
    RegisterEvent("AIChat.backend_config", onBackendConfig)
    RegisterEvent("AIChat.initiative_tick", function() pcall(AI_Influence.InitiativePass) end)
    RegisterEvent("AIChat.ship_lost", function(_, param) pcall(AI_Influence.OnShipLost, param) end)
    RegisterEvent("AIChat.world_event", function(_, param) pcall(AI_Influence.OnWorldEvent, param) end)
    RegisterEvent("AIChat.diplo_statement", function(_, param) pcall(AI_Influence.OnDiploStatement, param) end)
    RegisterEvent("AIChat.u1_probe", function(_, param) if U1_GROUNDING_PROBE then AI_Influence.U1GroundingProbe(param) end end)
    RegisterEvent("AIChat.card_loaded", onCardLoaded)
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
    RegisterEvent("AIChat.mint_contract", onMintContract)
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
