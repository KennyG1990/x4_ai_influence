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

-- Render the frame + widget rows (UIBuilder standard-template body).
function menu.display()
    refreshHelper()
    log("display ENTER Helper=" .. tostring(Helper ~= nil) .. " Color=" .. tostring(rawget(_G, "Color") ~= nil))
    if not Helper then log("display ABORT: Helper nil"); return end
    if menu.frame then Helper.clearDataForRefresh(menu, menu.layer) end

    local w = Helper.scaleX(640)
    local h = Helper.scaleY(330)
    local x = ((Helper.viewWidth or 1920) - w) / 2
    -- Anchor near the BOTTOM of the screen (not dead-centre) so the NPC stays visible behind it.
    local y = (Helper.viewHeight or 1080) - h - Helper.scaleY(70)
    menu.frame = Helper.createFrameHandle(menu, { x = x, y = y, width = w, height = h, layer = menu.layer, standardButtons = { close = true } })

    local frameColor = Color["frame_background_semitransparent"]
    if menu.npcState == "scared" then frameColor = Color["row_background_warning"]
    elseif menu.npcState == "aggressive" then frameColor = Color["row_background_error"] end
    menu.frame:setBackground("solid", { color = frameColor })

    local ftable = menu.frame:addTable(2, { tabOrder = 1, width = w, highlightMode = "off" })
    ftable:setColWidthPercent(1, 78)
    ftable:setColWidthPercent(2, 22)
    local row

    -- header widget
    row = ftable:addRow(false, { bgColor = Color["row_title_background"] })
    row[1]:setColSpan(2):createText("Comm-Link: " .. (menu.currentContext.target or "NPC"), Helper.headerRowCenteredProperties)

    -- chat/transcript widget: fixed row count — newest at the BOTTOM, blank rows padded on top — so
    -- the input box stays anchored low instead of drifting as the conversation fills. (Single-table
    -- layout: the multi-table vanilla scroll approach needs explicit per-table y-offsets — TODO.)
    local hist = menu.history or {}
    local SLOTS = 7
    local startIdx = math.max(1, #hist - SLOTS + 1)
    local shown = {}
    for i = startIdx, #hist do shown[#shown + 1] = hist[i] end
    for p = 1, (SLOTS - #shown) do
        row = ftable:addRow(false, {})   -- transparent padding (no grey bar) to keep the input anchored
        local placeholder = (#shown == 0 and p == (SLOTS - #shown)) and "Say something to begin the conversation." or " "
        row[1]:setColSpan(2):createText(placeholder)
    end
    for _, item in ipairs(shown) do
        local who = (item.role == "user") and "You" or (menu.currentContext.target or "NPC")
        row = ftable:addRow(false, { bgColor = Color["row_background_unselectable"] })
        row[1]:setColSpan(2):createText(who .. ":  " .. tostring(item.text), { wordwrap = true })
    end

    -- input widget + SEND button
    row = ftable:addRow(true, { bgColor = Color["row_background_unselectable"] })
    row[1]:createEditBox({ height = Helper.standardButtonHeight, defaultText = "Enter message...", maxChars = 255, selectTextOnActivation = true })
    row[1].handlers.onTextChanged = function(_, text, textchanged) if textchanged and text ~= nil then menu.editboxText = text end end
    row[1].handlers.onEditBoxDeactivated = function(_, text, textchanged, isconfirmed)
        if textchanged and text ~= nil then menu.editboxText = text end
        if isconfirmed then menu.onInput(text) end
    end
    row[2]:createButton({ active = true }):setText("SEND", { halign = "center" })
    row[2].handlers.onClick = function() menu.onInput(menu.editboxText) end

    -- CLOSE button
    row = ftable:addRow(true, { bgColor = Color["row_background"] })
    row[1]:setColSpan(2):createButton({ active = true }):setText("CLOSE", { halign = "center" })
    row[1].handlers.onClick = function() menu.closeMenu() end

    menu.frame:display()
    log("display DONE frame=" .. tostring(menu.frame ~= nil))
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
end

function menu.closeMenu()
    refreshHelper()
    if Helper and Helper.closeMenuAndReturn then Helper.closeMenuAndReturn(menu) end
    menu.cleanup()
end

-- NOTE: registration is DEFERRED (Helper is nil at file load). The companion poll tick + open path
-- call menu.ensureRegistered(). No file-scope registration.
return menu
