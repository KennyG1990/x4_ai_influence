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
        return { { label = "Confirm — do it", line = "yes" },
                 { label = "Decline the proposal", line = "no" } }
    end
    if menu.suggestions and #menu.suggestions > 0 then return menu.suggestions end
    return menu.PRESET_CHOICES
end

function menu.requestSuggestions()
    local bridge = rawget(_G, "AI_Influence")
    if not (bridge and bridge.FetchSuggestions) then return end
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

function menu.pickChoice(i)
    local choices = menu.currentChoices()
    local c = choices and choices[i]
    if not (c and c.line and c.line ~= "") then return end
    menu.suggestions = {}          -- show presets while the NPC "thinks"; handleUpdates refetches after the reply
    menu.onInput(c.line)           -- send the chosen line (same path as a typed message)
    -- NO fetch here: the single refresh happens after the NPC reply (aic_uix handleUpdates) — one fetch/turn.
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
    local ht = frame:addTable(3, { tabOrder = menu._tab, x = cx - tw / 2, y = ty, width = tw,
                                   highlightMode = "off" })
    ht:setColWidthPercent(1, 74)
    ht:setColWidthPercent(2, 13)
    ht:setColWidthPercent(3, 13)
    -- ME palette (Ken 2026-07-05): the TARGET speaks in orange, the player in green.
    local NPC_ORANGE = { r = 255, g = 153, b = 51, a = 100 }
    local PLAYER_GREEN = { r = 120, g = 230, b = 130, a = 100 }
    local npcColor = NPC_ORANGE
    if menu.npcState == "scared" then npcColor = Color["text_warning"]
    elseif menu.npcState == "aggressive" then npcColor = Color["text_error"] end
    -- Name row carries the ONE persistent control: END (full exit). Everything else is pure output
    -- (Ken 2026-07-05: "the chat window is strictly for visual output").
    local row = ht:addRow(true, {})
    row[1]:setColSpan(2):createText(tostring(menu.currentContext.target or "NPC"),
                                    { color = Color["text_inactive"] })
    row[3]:createButton({ active = true }):setText("END", { halign = "center" })
    row[3].handlers.onClick = function() menu.closeMenu() end
    -- ME framing: normally show only the NPC's latest line. While they're "thinking" (your line is
    -- newer than their last reply), show YOUR pending line dimmed so the wait reads as intentional.
    local lastNpc, lastYou
    local hist = menu.history or {}
    for i = #hist, 1, -1 do
        local it = hist[i]
        if it.role == "user" then
            if not lastNpc and not lastYou then lastYou = it.text end
        elseif not lastNpc then
            lastNpc = it.text
            break
        end
    end
    if lastYou then
        row = ht:addRow(false, {})
        row[1]:setColSpan(3):createText("You:  " .. tostring(lastYou), { wordwrap = true, color = PLAYER_GREEN })
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
            if isconfirmed then menu.typing = false; menu.suggestions = {}; menu.onInput(text) end
        end
        row[2]:createButton({ active = true }):setText("SEND", { halign = "center" })
        row[2].handlers.onClick = function() menu.typing = false; menu.suggestions = {}; menu.onInput(menu.editboxText) end
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
            if AddUITriggeredEvent then AddUITriggeredEvent("ai_influence", "action", pending) end
            return
        else
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = "[Declined the proposal.]" })
            -- fall through: send this message as a normal chat turn
        end
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
        bridge.SendDirectChat({
            target = menu.currentContext.target,
            faction = menu.currentContext.faction,
            role = fc.npc_role or fc.role or "officer",
            standing = fc.standing,   -- P3-a grounded context from MD
            psector = fc.psector,
            nearby = fc.nearby,
            traffic = fc.traffic,     -- #216 live sector ship-traffic count
            npc_owned = fc.npc_owned, -- #217 owned-captain flag (gates conversational orders)
            npc_ship = fc.npc_ship,   -- #217 ship name for the order acknowledgement
        }, text, function(ok, reply)
            menu.history = menu.history or {}
            table.insert(menu.history, { role = "assistant", text = tostring(reply) })
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

function menu.cleanup()
    menu.frame = nil
    menu.active = false
    menu.typing = false      -- lifecycle nesting (Ken): input NEVER outlives the window
    menu.editboxText = ""
end

function menu.closeMenu()
    refreshHelper()
    if Helper and Helper.closeMenuAndReturn then Helper.closeMenuAndReturn(menu) end
    menu.cleanup()
end

-- NOTE: registration is DEFERRED (Helper is nil at file load). The companion poll tick + open path
-- call menu.ensureRegistered(). No file-scope registration.
return menu
