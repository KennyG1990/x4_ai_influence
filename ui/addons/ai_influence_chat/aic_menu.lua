-- ============================================================================
-- AI INFLUENCE CHAT — menu shell GENERATED to the X4 Mod Studio UIBuilder "standard" template
-- (the proven render pattern, verified in-game + against 24 vanilla menus): read Helper LAZILY
-- (nil at file load), register DEFERRED the moment Helper exists, then OpenMenu(name) → engine
-- calls onShowMenu → Helper.createFrameHandle → frame:display(). Caching Helper at load or
-- registering at file scope silently breaks rendering (X4_STANDALONE_MENU_SCHEMA).
-- Widgets (designer order): header, chat/transcript, input, SEND button, CLOSE button.
-- The djfhe/LLM transport is companion logic in aic_uix.lua (this file is the window).
-- ============================================================================

-- Helper is nil when this file first loads — read it lazily and re-fetch at use time.
local Helper = rawget(_G, "Helper")
local function refreshHelper() if not Helper then Helper = rawget(_G, "Helper") end return Helper end

local ffi = require("ffi")
local C = ffi.C
ffi.cdef [[
    void AddPlayerLogEntry(const char* category, const char* title, const char* text);
    int64_t GetCurrentUTCDataTime(void);
    const char* GetPlayerName(void);
]]

local function playerName()
    local ok, name = pcall(function() return ffi.string(C.GetPlayerName()) end)
    if ok and name and name ~= "" then return name end
    return "Player"
end

-- Menu table. Exposed as a global so the companion transport (aic_uix.lua) can find it.
X4_Terminal_Menu = {
    name = "X4_Terminal",
    layer = 4,
    active = false,
    currentContext = { faction = "argon", target = "Faction Officer" },
    editboxText = "",
    npcState = "normal",
    history = {},
    suggestions = {},   -- P1 (#113): {label,line} choices rendered as BUTTONS (the conversation flows by picking)
    typing = false,     -- the edit-box is shown ONLY when true; reached solely via "Type my own message"
}
local menu = X4_Terminal_Menu

local function log(m) if DebugError then DebugError("[AICHAT][MENU] " .. tostring(m)) end end

-- U-D1b: X4's UI font renders exotic punctuation as boxes - fold LLM text to ASCII for display.
-- Escape-proof construction (string.char): literal multi-byte escapes get mangled in transit.
local function asciiClean(s)
    s = tostring(s or "")
    local E = string.char(226, 128)
    s = s:gsub(E .. string.char(148), " - ")            -- em dash
    s = s:gsub(E .. string.char(147), "-")              -- en dash
    s = s:gsub(E .. string.char(166), "...")            -- ellipsis
    s = s:gsub(E .. string.char(152), "'"):gsub(E .. string.char(153), "'")
    s = s:gsub(E .. string.char(156), string.char(34)):gsub(E .. string.char(157), string.char(34))
    s = s:gsub(E .. string.char(175), " "):gsub(E .. string.char(137), " "):gsub(E .. string.char(130), " ")
    s = s:gsub(string.char(194, 160), " ")              -- no-break space
    return s
end

-- Idempotent + DEFERRED registration. Completes the engine registration (which OpenMenu needs) the
-- moment Helper is available. Called from the poll tick / open path, by which time Helper exists.
function menu.ensureRegistered()
    refreshHelper()
    _G.Menus = _G.Menus or {}
    local found = false
    for i, m in ipairs(_G.Menus) do if m.name == menu.name then _G.Menus[i] = menu; found = true; break end end
    if not found then table.insert(_G.Menus, menu) end
    if Helper and Helper.registerMenu and not menu._registered then
        local ok = pcall(Helper.registerMenu, menu); menu._registered = ok
    end
    log("ensureRegistered Helper=" .. tostring(Helper ~= nil) .. " registered=" .. tostring(menu._registered == true) .. " #Menus=" .. tostring(#_G.Menus))
    return menu._registered == true
end

-- PUBLIC: open the window. Pass a context table; onShowMenu reads it when the engine fires.
function menu.open(context)
    if type(context) == "table" then menu.currentContext = context end
    menu._openRequested = true
    menu.ensureRegistered()
    if OpenMenu then log("OpenMenu"); OpenMenu(menu.name, nil, nil, true)
    elseif menu.onShowMenu then menu.onShowMenu() end
end

-- Engine entry: called by OpenMenu after a short delay.
function menu.onShowMenu()
    refreshHelper()
    -- Guard: X4 auto-restores whatever menu was active when the player saved; only build the frame
    -- for a REAL player-initiated open (open paths set _openRequested). A bare load-restore closes.
    if not menu._openRequested then
        if Helper and Helper.closeMenuAndReturn then pcall(Helper.closeMenuAndReturn, menu) end
        menu.cleanup()
        return
    end
    menu._openRequested = false
    menu.active = true
    menu.display()
end

function menu.showMenuCallback(_, context)
    if type(context) == "table" then menu.currentContext = context end
    menu.onShowMenu()
end

-- P1 (#113): the conversation flows through CHOICE BUTTONS, not a forced text box. Presets show
-- instantly; the LLM batch (AI_Influence.FetchSuggestions, conversation-aware via #112) replaces them
-- and refreshes after each reply. The edit-box is opt-in via "Type my own message".
menu.PRESET_CHOICES = {
    { label = "Ask their situation", line = "What is the situation here?" },
    { label = "Who are you?", line = "Who are you, and what is your posting here?" },
    { label = "Any news?", line = "Have you heard any news lately?" },
}

function menu.currentChoices()
    -- C2: with a pending influence action, the wheel ITSELF becomes the confirm gate — dedicated
    -- Confirm/Decline wedges (onInput's yes/no gate is unchanged; these just feed it).
    if menu._pendingAction then
        -- #270: payments are a REAL choice - pay what they asked, type your own number, or refuse
        if menu._pendingAction.control == "aic_transfer" then
            return { { label = "Pay in full - " .. tostring(menu._pendingAction.credits) .. " Cr", line = "__pay_full" },
                     { label = "Enter a different amount", line = "__pay_custom" },
                     { label = "Refuse to pay", line = "__pay_refuse" } }
        end
        return { { label = "Confirm — do it", line = "yes" },
                 { label = "Decline the proposal", line = "no" } }
    end
    if menu.suggestions and #menu.suggestions > 0 then return menu.suggestions end
    return menu.PRESET_CHOICES
end

function menu.requestSuggestions()
    local bridge = rawget(_G, "AI_Influence")
    if not (bridge and bridge.FetchSuggestions) then return end
    -- #228: serverless topics ride EACH reply (SendDirectChat hands them to menu.suggestions
    -- directly) - the bridge-era GET below would just time out against a dead endpoint.
    if bridge.SendDirectChat then return end
    local ctx = menu.currentContext or {}
    pcall(function()
        bridge.FetchSuggestions(ctx.faction, ctx.target, ctx.save_id, function(list)
            if type(list) == "table" and #list > 0 then
                menu.suggestions = list
                if menu.active and menu.display then menu.display() end
            end
        end)
    end)
end

function menu.startTyping()
    menu.typing = true
    if menu.active and menu.display then menu.display() end
end

-- ============================================================================
-- C2 (#158): FULL-WHEEL PRESENTATION — the conversation lives in a RADIAL, not a box (Ken 2026-07-04,
-- screenshots on record; ME grammar). Hub = NPC's latest line; wedges = choices at polar positions.
-- C2a research verdict (grounded): X4 ships NO native radial widget — menu_interactmenu.xpl is a
-- rectangular list (width 260, zero polar math in 414KB) and helper.xpl has none either — so we draw
-- our own: ONE small frame per wedge positioned via cos/sin (multi-frame menus are a proven vanilla
-- pattern — the map menu runs several frames on one layer).
-- ============================================================================
local WHEEL = {
    rx = 340, ry = 195,       -- ellipse radii (pre-scale px @1920x1080)
    wedgeW = 250, wedgeH = 44,
    hubW = 520, hubH = 168,
    leftAngles = { 150, 180, 210 },  -- ME reply side: three conversation choices
    typeAngle = 30,                  -- right-top: free text (demoted to ONE wedge)
    byeAngle = 330,                  -- right-bottom: Goodbye ("Have it your way.")
}

local function wedgePos(cx, cy, angleDeg)
    local a = math.rad(angleDeg)
    local x = cx + Helper.scaleX(WHEEL.rx) * math.cos(a) - Helper.scaleX(WHEEL.wedgeW) / 2
    local y = cy - Helper.scaleY(WHEEL.ry) * math.sin(a) - Helper.scaleY(WHEEL.wedgeH) / 2
    return x, y
end

-- ONE FRAME PER LAYER is an ENGINE INVARIANT (helper.lua:4247 menu.frames[layer] = frameid — each
-- display() EVICTS the previous frame; live-proven: six frames → one surviving wedge). So the wheel
-- is ONE full-screen frame with POSITIONED TABLES — the vanilla pattern (interactmenu.lua:3745/:3846
-- addTable{ x=, y=, backgroundID="solid" }).
local function addWedge(frame, cx, cy, angleDeg, label, active, onClick, bg)
    local wW = Helper.scaleX(WHEEL.wedgeW)
    local x, y = wedgePos(cx, cy, angleDeg)
    menu._tab = (menu._tab or 0) + 1
    local t = frame:addTable(1, { tabOrder = menu._tab, x = x, y = y, width = wW,
                                  backgroundID = "solid",
                                  backgroundColor = bg or Color["frame_background_semitransparent"],
                                  highlightMode = "off" })
    local row = t:addRow(true, {})
    row[1]:createButton({ active = active ~= false }):setText(tostring(label), { halign = "center" })
    if onClick and active ~= false then row[1].handlers.onClick = onClick end
end

-- Render the wheel (hub + wedges + optional typing dock). Replaces the boxed layout entirely.
function menu.display()
    refreshHelper()
    log("display ENTER Helper=" .. tostring(Helper ~= nil) .. " Color=" .. tostring(rawget(_G, "Color") ~= nil))
    if not Helper then log("display ABORT: Helper nil"); return end
    -- C2 v2 (Ken's mockup 2026-07-05): INVISIBLE OVERLAY. The native conversation wheel below owns the
    -- CHOICES (ai_influence_conversation.xml keeps it open across turns); this window is ONLY floating
    -- text + a bare input. Zero borders, zero backgrounds — the send button is the single visible chrome.
    if menu.frame then Helper.clearDataForRefresh(menu, menu.layer) end
    menu._tab = 0

    local vw = Helper.viewWidth or 1920
    local vh = Helper.viewHeight or 1080
    local cx = vw / 2
    -- Wheel centre sits low so the NPC stays visible above it (same instinct as the old box anchor).
    local cy = vh - Helper.scaleY(430)

    -- THE one frame (engine invariant: one frame per layer) — full-view, NO background, NO buttons:
    -- pure floating text above the native wheel (ME framing: words, not forms).
    menu.frame = Helper.createFrameHandle(menu, { x = 0, y = 0, width = vw, height = vh,
                                                  layer = menu.layer, standardButtons = {},
                                                  blurBackground = false })   -- native no-blur look (interactmenu.lua:3629)
    local frame = menu.frame

    local tw = Helper.scaleX(680)
    -- Ken 2026-07-05 (overlap fix): anchor the text block HIGHER — long replies grow DOWNWARD from ty,
    -- so headroom lives on top and the block ends a safe margin above the wheel options (~vh-260).
    local ty = vh - Helper.scaleY(460)
    menu._tab = menu._tab + 1
    -- Ken 2026-07-22 (readability): ME-style dark subtitle plate behind the transcript — the pure
    -- floating text washed out over bright scenes (same solid-background pattern as the wedges).
    local ht = frame:addTable(3, { tabOrder = menu._tab, x = cx - tw / 2, y = ty, width = tw,
                                   backgroundID = "solid",
                                   backgroundColor = { r = 8, g = 10, b = 14, a = 72 },
                                   highlightMode = "off" })
    ht:setColWidthPercent(1, 74)
    ht:setColWidthPercent(2, 13)
    ht:setColWidthPercent(3, 13)
    -- ME palette (Ken 2026-07-05): the TARGET speaks in orange, the player in green.
    local NPC_ORANGE = { r = 255, g = 176, b = 84, a = 100 }   -- brighter on the dark plate
    local PLAYER_GREEN = { r = 120, g = 230, b = 130, a = 100 }
    local npcColor = NPC_ORANGE
    if menu.npcState == "scared" then npcColor = Color["text_warning"]
    elseif menu.npcState == "aggressive" then npcColor = Color["text_error"] end
    if lastNpcErr then npcColor = Color["text_inactive"] end   -- #228c: transport errors are STATUS, not NPC speech
    -- Name row carries the ONE persistent control: END (full exit). Everything else is pure output
    -- (Ken 2026-07-05: "the chat window is strictly for visual output").
    local row = ht:addRow(true, {})
    row[1]:setColSpan(2):createText(tostring(menu.currentContext.target or "NPC"),
                                    { color = Color["text_inactive"] })
    row[3]:createButton({ active = true }):setText("END", { halign = "center" })
    row[3].handlers.onClick = function() menu.closeMenu() end
    -- ME framing: normally show only the NPC's latest line. While they're "thinking" (your line is
    -- newer than their last reply), show YOUR pending line dimmed so the wait reads as intentional.
    local lastNpc, lastYou, lastNpcErr, lastUser
    local hist = menu.history or {}
    for i = #hist, 1, -1 do
        local it = hist[i]
        if it.role == "user" then
            if not lastUser then lastUser = it.text end
            if not lastNpc and not lastYou then lastYou = it.text end
        elseif not lastNpc then
            lastNpc = it.text
            lastNpcErr = it.err
        end
        if lastUser and lastNpc then break end
    end
    -- Ken 2026-07-22: ALWAYS show the player's last line above the reply (was: only while the NPC
    -- was "thinking") - the plate carries the full exchange, not just the NPC's half.
    if lastUser then
        row = ht:addRow(false, {})
        row[1]:setColSpan(3):createText("You:  " .. tostring(lastUser), { wordwrap = true, color = PLAYER_GREEN })
    end
    -- ME-style two-voice rendering (Ken 2026-07-05): *asterisk* spans are STAGE DIRECTION — italic,
    -- muted lavender (the Player2-app look); everything else is SPEECH in the target's orange.
    local ACTION_COLOR = { r = 175, g = 175, b = 215, a = 100 }
    local reply = tostring(lastNpc or "Say something, Commander — or pick a line below.")
    local pos = 1
    local emitted = false
    while pos <= #reply do
        local a1, a2, act = string.find(reply, "%*(.-)%*", pos)
        local speech = string.sub(reply, pos, (a1 or (#reply + 1)) - 1)
        speech = string.gsub(speech, "^%s+", ""):gsub("%s+$", "")
        if speech ~= "" then
            row = ht:addRow(false, {})
            row[1]:setColSpan(3):createText(speech, { wordwrap = true, color = npcColor })
            emitted = true
        end
        if act then
            act = string.gsub(act, "^%s+", ""):gsub("%s+$", "")
            if act ~= "" then
                row = ht:addRow(false, {})
                row[1]:setColSpan(3):createText(act, { wordwrap = true, color = ACTION_COLOR,
                                                       font = "Zekton Italic" })
                emitted = true
            end
            pos = a2 + 1
        else
            break
        end
    end
    if not emitted then
        row = ht:addRow(false, {})
        row[1]:setColSpan(3):createText(reply, { wordwrap = true, color = npcColor })
    end

    -- U-D5 (#244): next-turn confidence bands, dimmed (semi-transparent UI mode from the docs)
    if menu.lastOdds and not menu.typing then
        row = ht:addRow(false, {})
        row[1]:setColSpan(3):createText("Read:  " .. tostring(menu.lastOdds), { color = Color["text_inactive"] })
    end
    -- U-D1: the dice are VISIBLE (D&D feel) - last check readout, dimmed, not NPC speech
    if menu.lastCheck then
        local ck = menu.lastCheck
        row = ht:addRow(false, {})
        row[1]:setColSpan(3):createText(string.upper(tostring(ck.intent)) .. " CHECK: " .. tostring(ck.chance) .. "% vs roll " .. tostring(ck.roll) .. " = " .. tostring(ck.tier),
                                        { color = Color["text_inactive"] })
    end

    -- #228: LIVE choices IN the plate - the overlay owns them, refreshed from each reply's topics,
    -- so what you can pick always follows what was just said (the native wheel keeps stable slots).
    -- While the NPC "thinks" (lastYou pending) the block is a dimmed ellipsis: nothing stale to pick.
    -- #228c (review): while COMPOSING (typing dock up) the block is suppressed - the dock docks at a
    -- fixed y and the button rows would physically overlap it.
    if menu.typing then
        -- composing: no choice block
    elseif lastYou then
        row = ht:addRow(false, {})
        row[1]:setColSpan(3):createText(". . .", { color = Color["text_inactive"] })
    else
        local choices = menu.currentChoices()
        for ci = 1, math.min(3, #choices) do
            local c = choices[ci]
            if c and c.line and c.line ~= "" then
                row = ht:addRow(true, {})
                row[1]:setColSpan(3):createButton({ active = true }):setText(tostring(ci) .. ".  " .. asciiClean(c.label), { halign = "left" })
                row[1].handlers.onClick = function() menu.onInput(c.line) end   -- #228c: no wipe - a failed turn keeps the live topics
            end
        end
    end

    -- INPUT ON DEMAND, IN PLACE (Ken 2026-07-05): pressing wheel option 4 makes its label give way —
    -- the input box materializes AT the option-4 slot (right arc, wheel height) via AIChat.starttyping
    -- → startTyping(). Sending (Enter or SEND) dismisses it back to pure output.
    if menu.typing then
        -- Ken 2026-07-05: the option-4-slot position rendered UNDER the native conversation UI
        -- (unclickable). The box now docks centered BELOW the text block, above the wheel — inside
        -- our own clear region, always clickable.
        menu._tab = menu._tab + 1
        local it = frame:addTable(2, { tabOrder = menu._tab, x = cx - Helper.scaleX(240),
                                       y = vh - Helper.scaleY(310), width = Helper.scaleX(480),
                                       highlightMode = "off" })
        it:setColWidthPercent(1, 76)
        it:setColWidthPercent(2, 24)
        row = it:addRow(true, {})
        row[1]:createEditBox({ height = Helper.standardButtonHeight,
                               defaultText = "Type your message...",
                               maxChars = 255, selectTextOnActivation = true })
        row[1].handlers.onTextChanged = function(_, text, textchanged) if textchanged and text ~= nil then menu.editboxText = text end end
        row[1].handlers.onEditBoxDeactivated = function(_, text, textchanged, isconfirmed)
            if textchanged and text ~= nil then menu.editboxText = text end
            if isconfirmed then menu.typing = false; menu.onInput(text) end
        end
        row[2]:createButton({ active = true }):setText("SEND", { halign = "center" })
        row[2].handlers.onClick = function() menu.typing = false; menu.onInput(menu.editboxText) end
    end

    frame:display()
    log("display DONE (invisible overlay)")
end

-- Send a player line to the bridge (companion transport is the global AI_Influence in aic_uix.lua).
function menu.onInput(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then return end

    -- #270: typed-amount mode - the dock input IS the credit amount
    if menu._amountMode and menu._pendingAction and menu._pendingAction.control == "aic_transfer" then
        local amt = tonumber((tostring(text):gsub("[^%d]", "")))
        menu._amountMode = false
        local pending = menu._pendingAction
        menu._pendingAction = nil
        menu.history = menu.history or {}
        if amt and amt > 0 then
            if AddUITriggeredEvent then
                pcall(function() AddUITriggeredEvent("ai_influence", "aic_transfer", {
                    credits = math.floor(amt), asked = pending.credits, why = pending.why, deliverable = pending.deliverable, vfaction = pending.vfaction }) end)
            end
            table.insert(menu.history, { role = "assistant", text = "[You transfer " .. math.floor(amt) .. " Cr (they asked " .. tostring(pending.credits) .. ").]", err = true })
        else
            table.insert(menu.history, { role = "assistant", text = "[No valid amount entered - payment cancelled.]", err = true })
        end
        menu.editboxText = ""
        if menu.active and menu.display then menu.display() end
        return
    end
    if menu._pendingAction and menu._pendingAction.control == "aic_transfer" then
        if text == "__pay_full" then
            local pending = menu._pendingAction
            menu._pendingAction = nil
            if AddUITriggeredEvent then
                pcall(function() AddUITriggeredEvent("ai_influence", "aic_transfer", {
                    credits = pending.credits, asked = pending.credits, why = pending.why, deliverable = pending.deliverable, vfaction = pending.vfaction }) end)
            end
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = "[You pay the full " .. tostring(pending.credits) .. " Cr.]", err = true })
            if menu.active and menu.display then menu.display() end
            return
        elseif text == "__pay_custom" then
            menu._amountMode = true
            menu.typing = true
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = "[Enter the amount to transfer - they asked for " .. tostring(menu._pendingAction.credits) .. " Cr. Pay less at your own risk.]", err = true })
            if menu.active and menu.display then menu.display() end
            return
        elseif text == "__pay_refuse" then
            menu._pendingAction = nil
            -- #272: an open refusal kills the pending deal - the NPC hears it and reacts LIVE;
            -- no stale uix slot, no ghost-debt stamp (refusing to your face is not ghosting).
            local ai0 = rawget(_G, "AI_Influence")
            if ai0 then ai0._pendingTransfer = nil end
            text = "I am not paying that."
            -- falls through: the refusal becomes a real chat line the NPC reacts to
        end
    end
    -- #253: SIM commands - instant test triggers for the time-gated systems (Ken: "speed this up").
    -- sim event [military|political|economic|social|anomalous] | sim outbreak | sim tick | sim drop
    do
        local low = string.lower(text)
        if low:sub(1, 4) == "sim " or low:sub(1, 5) == "/sim " or low == "sim" then
            local arg = low:gsub("^/?sim%s*", "")
            local br = rawget(_G, "AI_Influence")
            local note = "[sim commands: 'sim event <type>' | 'sim outbreak' seed a plague | 'sim spread' force a plague jump | 'sim strike' force a plague tick | 'sim drop' informant/initiative pass | 'sim tick' generator cadence | 'plague on/off']"
            if br and arg ~= "" then
                if arg:sub(1, 5) == "event" then
                    local ty = arg:match("^event%s+(%a+)") or "political"
                    if br.DynEventGenerate then
                        pcall(br.DynEventGenerate, ty)
                        note = "[sim: generating a '" .. ty .. "' galaxy event - watch inbox/logbook/debuglog]"
                    end
                elseif arg:sub(1, 9) == "vassalize" then
                    local va, sa = arg:match("^vassalize%s+(%a+)%s+(%a+)$")
                    if va and sa and AddUITriggeredEvent then
                        pcall(function() AddUITriggeredEvent("ai_influence", "pol_vassalize", { v = va, s = sa, src = "sim" }) end)
                        note = "[sim: vassalizing " .. va .. " under " .. sa .. " - watch debuglog for 'AIC POLITICS']"
                    else
                        note = "[sim vassalize <vassal-id> <suzerain-id|player>]"
                    end
                elseif arg == "polevent" then
                    if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "pol_event_force", {}) end) end
                    note = "[sim: forcing a political event for the first vassalage - watch logbook/debuglog for 'POLEVENT']"
                elseif arg == "poltick" then
                    if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "pol_tick", {}) end) end
                    note = "[sim: forcing a politics happiness tick - watch debuglog for 'AIC POLITICS eval']"
                elseif arg:sub(1, 8) == "polhappy" then
                    local pv, pn = arg:match("^polhappy%s+(%a+)%s+(%d+)$")
                    if pv and pn and AddUITriggeredEvent then
                        pcall(function() AddUITriggeredEvent("ai_influence", "pol_happy", { v = pv, n = tonumber(pn) }) end)
                        note = "[sim: setting " .. pv .. " happiness to " .. pn .. "]"
                    else
                        note = "[sim polhappy <faction-id> <0-100>]"
                    end
                elseif arg == "dispatch" then
                    if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "wardesk_force", {}) end) end
                    note = "[sim: forcing a GNN newscast now - watch the News logbook / debuglog for 'NEWSCAST']"
                elseif arg == "accesstest" then
                    local b = rawget(_G, "AI_Influence")
                    if b and b.AccessSelfTest then b.AccessSelfTest() end
                    note = "[sim: espionage access-model self-test - watch debuglog for 'ACCESSTEST' lines]"
                elseif arg == "spread" then
                    if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "plague_spread_force", {}) end) end
                    note = "[sim: forcing a plague spread roll - watch debuglog for 'AIC PLAGUE spread']"
                elseif arg == "strike" then
                    -- day=0 on purpose: MD keeps its stored day, so this runs strikes WITHOUT
                    -- advancing the phase clocks - pure workforce-effect testing
                    if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "plague_tick2", { day = 0 }) end) end
                    note = "[sim: forcing a plague tick (strikes at current phases) - watch debuglog for 'AIC PLAGUE strike']"
                elseif arg == "outbreak" then
                    if br.ContagionStart then
                        pcall(br.ContagionStart)
                        note = "[sim: outbreak starting in your last grounded sector - Health Advisory + relief contract incoming]"
                    end
                elseif arg == "drop" then
                    if br.InitiativePass then
                        pcall(br.InitiativePass)
                        note = "[sim: initiative pass forced - bonded friends / informants may reach out (needs a qualifying NPC)]"
                    end
                elseif arg == "persona" then
                    br._remintNext = true
                    note = "[sim: identity cleared - their NEXT reply re-mints persona/backstory/quirks with the corrected role]"
                elseif arg == "tick" then
                    br._dynTicks = ((br._dynTicks or 0) - ((br._dynTicks or 0) % 18)) + 17
                    note = "[sim: generator cadence advanced - the next 10-min tick fires an event]"
                end
            end
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = note, err = true })
            menu.editboxText = ""
            if menu.active and menu.display then menu.display() end
            return
        end
    end
    -- #285: politics toggle ("politics off" purges + unlocks every vassal - the Safe Uninstall lesson)
    do
        local low = string.lower(text)
        if low == "politics off" or low == "/politics off" or low == "politics on" or low == "/politics on" then
            local on = (string.sub(low, -3) == " on")
            if AddUITriggeredEvent then
                pcall(function() AddUITriggeredEvent("ai_influence", on and "pol_on" or "pol_off", {}) end)
            end
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = "[Galactic politics " .. (on and "ENABLED" or "DISABLED - vassals released and unlocked") .. ".]", err = true })
            menu.editboxText = ""
            if menu.active and menu.display then menu.display() end
            return
        end
    end
    -- #274: plague toggle typed straight into the chat box ("plague off" / "plague on")
    do
        local low = string.lower(text)
        if low == "plague off" or low == "/plague off" or low == "plague on" or low == "/plague on" then
            local br = rawget(_G, "AI_Influence")
            local on = (string.sub(low, -3) == " on")
            if br then br.PLAGUE_ENABLED = on end
            if AddUITriggeredEvent then
                pcall(function() AddUITriggeredEvent("ai_influence", "toggles_persist", { plague = on and 1 or 0 }) end)
                if not on then pcall(function() AddUITriggeredEvent("ai_influence", "plague_off", {}) end) end
            end
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = "[Station plague system " .. (on and "ENABLED" or "DISABLED - active outbreaks purged") .. ".]", err = true })
            menu.editboxText = ""
            if menu.active and menu.display then menu.display() end
            return
        end
    end
    -- doc-08 (#239): obituary opt-out typed straight into the chat box ("obits off" / "obits on")
    do
        local low = string.lower(text)
        if low == "obits off" or low == "/obits off" or low == "obits on" or low == "/obits on" then
            local br = rawget(_G, "AI_Influence")
            local on = (string.sub(low, -3) == " on")
            if br then br.OBITS_ENABLED = on end
            if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "toggles_persist", { obits = on and 1 or 0 }) end) end
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = "[Ship life-stories " .. (on and "ENABLED" or "DISABLED") .. ".]", err = true })
            menu.editboxText = ""
            if menu.active and menu.display then menu.display() end
            return
        end
    end
    -- U-D1: dice-layer toggle typed straight into the chat box ("dnd off" / "dnd on")
    do
        local low = string.lower(text)
        if low == "dnd off" or low == "/dnd off" or low == "dnd on" or low == "/dnd on" then
            local br = rawget(_G, "AI_Influence")
            local on = (string.sub(low, -3) == " on")
            if br then br.DND_ENABLED = on end
            if AddUITriggeredEvent then pcall(function() AddUITriggeredEvent("ai_influence", "toggles_persist", { dnd = on and 1 or 0 }) end) end
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = "[Dice checks " .. (on and "ENABLED" or "DISABLED") .. ".]", err = true })
            menu.editboxText = ""
            if menu.active and menu.display then menu.display() end
            return
        end
    end

    -- Confirm gate: if an influence action is pending (held by aic_uix.handleUpdates), a
    -- 'yes'/'confirm' DISPATCHES it; anything else declines and is sent as a normal chat turn.
    if menu._pendingAction then
        local pending = menu._pendingAction
        menu._pendingAction = nil
        local low = string.lower(text)
        if low == "yes" or low == "y" or low == "confirm" or low == "do it" then
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "user", text = text })
            table.insert(menu.history, { role = "assistant", text = "[Confirmed] Dispatching." })
            menu.editboxText = ""
            if menu.active and menu.display then menu.display() end
            if AddUITriggeredEvent then AddUITriggeredEvent("ai_influence", pending.control or "action", pending) end
            return
        else
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = "[Declined the proposal.]" })
            -- #272: a declined transfer clears the uix pending slot as well (stale-slot bug)
            if pending.control == "aic_transfer" then
                local ai1 = rawget(_G, "AI_Influence")
                if ai1 then ai1._pendingTransfer = nil end
            end
            -- fall through: send this message as a normal chat turn
        end
    end

    -- #228c (review): ONE turn in flight at a time - a concurrent send races LoadCard/StoreCard
    -- on the same card (last writer wins; an exchange would vanish from NPC memory) and desyncs
    -- the transcript. Refuse quietly until the pending reply lands (failure replies also land).
    do
        local hist = menu.history or {}
        if #hist > 0 and hist[#hist].role == "user" then log("send refused: turn in flight") return end
    end
    log("SEND: " .. text)
    menu.history = menu.history or {}
    table.insert(menu.history, { role = "user", text = text })
    menu.editboxText = ""
    if menu.active and menu.display then menu.display() end

    local requestId = "chat_" .. tostring(tonumber(C.GetCurrentUTCDataTime()))
    local bridge = rawget(_G, "AI_Influence")
    if not bridge or not bridge.SendToBridge then
        pcall(function() C.AddPlayerLogEntry("news", "AI Error", "Bridge client not loaded in the X4 UI runtime.") end)
        return
    end
    -- P1 serverless lane: the chat turn goes DIRECT to Player2 (card-backed, no bridge). The bridge
    -- lane below is preserved as the fallback while the migration completes.
    if bridge.SendDirectChat then
        local fc = menu.currentContext.full_context or {}
        local sentTarget = menu.currentContext.target   -- #228c: a reply belongs to the conversation it was sent in
        bridge.SendDirectChat({
            target = menu.currentContext.target,
            faction = menu.currentContext.faction,
            faction_id = fc.real_facid,   -- #290 S1: resolved faction id (display name won't match ledger ids)
            skill = fc.npc_skill,          -- #290 S1: combinedskill = seniority (secondary signal)
            fleetcmd = fc.fleetcmd,        -- #290: fleet size this NPC commands = PRIMARY command authority
            issub = fc.issub,              -- #290: 1 if a subordinate in another fleet
            role = fc.npc_role or fc.role or "officer",
            standing = fc.standing,   -- P3-a grounded context from MD
            psector = fc.psector,
            nearby = fc.nearby,
            traffic = fc.traffic,     -- #216 live sector ship-traffic count
            npc_owned = fc.npc_owned, -- #217 owned-captain flag (gates conversational orders)
            npc_ship = fc.npc_ship,   -- #217 ship name for the order acknowledgement
            pmoney = fc.pmoney,       -- U-D2: REAL wallet (credits) -> Credit Leverage
            pfleet = fc.pfleet,       -- U-D2: player fight ships in this sector -> Resolve
        }, text, function(ok, reply)
            -- #228c (review): if the player moved on to another NPC while this was in flight, drop
            -- the UI write - the card write upstream is token-correct and unaffected.
            if tostring(menu.currentContext and menu.currentContext.target) ~= tostring(sentTarget) then
                log("late reply dropped (partner changed since send)")
                return
            end
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = asciiClean(reply), err = (not ok) or nil })
            if menu.active and menu.display then menu.display() end
            log(ok and ("direct chat reply len=" .. tostring(#tostring(reply))) or ("direct chat FAILED: " .. tostring(reply)))
        end)
        return
    end
    bridge.SendToBridge({
        request_id = requestId,
        faction_id = menu.currentContext.faction or "argon",
        npc_name = menu.currentContext.target,   -- the NPC's real personal name (e.g. "Selaia Erris")
        save_id = menu.currentContext.save_id,
        source = "pop-up",
        trigger_type = "player_chat",
        user_text = text,
        player_name = playerName(),
        prompt_vars = menu.currentContext.full_context or {},
    }, function(success, _, err)
        if success then log("bridge accepted " .. requestId)
        else pcall(function() C.AddPlayerLogEntry("news", "AI Error", "Failed to transmit: " .. tostring(err)) end) end
    end)
end

-- #230b: vanilla helper routes ESC/hide to menu.onCloseElement - we never defined it (nil-call
-- error in helper.xpl onHide). Standard behavior: close the overlay (closeMenu is guarded-safe).
function menu.onCloseElement()
    menu.closeMenu()
end

function menu.cleanup()
    menu._amountMode = nil
    menu.lastOdds = nil
    menu.lastCheck = nil
    menu.frame = nil
    menu.active = false
    menu.typing = false      -- lifecycle nesting (Ken): input NEVER outlives the window
    menu.editboxText = ""
end

function menu.closeMenu()
    refreshHelper()
    -- #228d (Ken's stuck wheel): closeMenuAndReturn on a menu that is NOT open pops whatever menu
    -- IS open - during a conversation start that ate the NATIVE conversation menu and stranded a
    -- choice-less wheel hub. Close the engine menu only when the overlay is actually open.
    if menu.active and menu.frame and Helper and Helper.closeMenuAndReturn then
        pcall(Helper.closeMenuAndReturn, menu)
    end
    menu.cleanup()
end

-- NOTE: registration is DEFERRED (Helper is nil at file load). The companion poll tick + open path
-- call menu.ensureRegistered(). No file-scope registration.
return menu
