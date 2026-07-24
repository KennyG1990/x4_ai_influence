-- AIC-HTTP (#224): the mod's OWN async HTTP transport — no external HTTP-mod dependency.
-- Clean-room implementation over the bundled MIT LuaSocket (see lua3p/THIRD_PARTY_LICENSES.md).
-- Non-blocking state machine pumped by the aic_http_pump MD cue (50ms) via "aic.http.update".
-- API shape (djfhe-compatible on purpose, so the caller swap is a two-line diff):
--   local R = require("aic_http"); local req = R.new("POST")
--   req:setUrl(u):addHeader(k,v):setBody(s):send(function(resp, err) ... end)
--   resp:getStatus() -> number, resp:getBody() -> string, resp:getJson() -> table|nil, err

local M = {}

local BASEDIR = "extensions/x4_ai_influence/lua3p/"   -- resolved to the REAL one by initLibs
local initialized = false
local socket = nil
local jsonlib = nil

local function log(msg)
    if DebugError then DebugError("[AICHTTP] " .. tostring(msg)) end
end

-- #291 SELF-CONTAINED (Ken's law): the built-in transport must NEVER assume the mod folder NAME. A GitHub
-- "Download ZIP" extracts as x4_ai_influence-main/-master, which broke the old single hardcoded path
-- (core.dll not found -> the misleading "djfhe request module missing" on a clean install). Locate lua3p
-- folder-name-AGNOSTICALLY: derive from package.path (the game registered our ui path), then common names.
local function candidateBaseDirs()
    local dirs, seen = {}, {}
    local function add(d) if d and not seen[d] then seen[d] = true; dirs[#dirs + 1] = d end end
    for entry in tostring(package.path or ""):gmatch("[^;]+") do
        local base = entry:match("(.-extensions/[^/]*x4_ai_influence[^/]*/)")
        if base then add(base .. "lua3p/") end
    end
    add("extensions/x4_ai_influence/lua3p/")
    add("extensions/x4_ai_influence-main/lua3p/")
    add("extensions/x4_ai_influence-master/lua3p/")
    return dirs
end

local function initLibs()
    if initialized then return socket ~= nil end
    initialized = true
    if not package.loaded["socket.core"] then
        local f, lasterr
        for _, dir in ipairs(candidateBaseDirs()) do
            local ff, err = package.loadlib(dir .. "luasocket/core.dll", "luaopen_socket_core")
            if ff then BASEDIR = dir; f = ff; break end
            lasterr = err
            log("core.dll not loadable at " .. dir .. " (" .. tostring(err) .. ")")
        end
        if not f then
            log("FATAL: bundled LuaSocket core.dll failed at EVERY candidate path - last err: "
                .. tostring(lasterr) .. ". Cause is usually a renamed mod folder (must contain x4_ai_influence)"
                .. " or a non-Windows OS.")
            return false
        end
        local core = f()
        package.loaded["socket.core"] = core
        package.loaded["luasocket.socket.core"] = core   -- vendored socket.lua requires this name
    end
    package.path = package.path .. ";" .. BASEDIR .. "?.lua;" .. BASEDIR .. "luasocket/?.lua;" .. BASEDIR .. "luasec/?.lua"
    local ok, s = pcall(require, "socket")
    if not ok then log("socket.lua load FAILED from " .. BASEDIR .. ": " .. tostring(s)) return false end
    socket = s
    local okj, j = pcall(require, "json")
    if okj then jsonlib = j end
    log("AIC-HTTP libs loaded from " .. BASEDIR .. " (LuaSocket " .. tostring(socket._VERSION or "?") .. ")")
    return true
end
M.initLibs = initLibs
function M.json() initLibs(); return jsonlib end

-- ---- URL parse (http only; https lanes can load LuaSec later) --------------------------------
function M.parseUrl(u)
    u = tostring(u or "")
    local scheme, rest = u:match("^(https?)://(.+)$")
    if not scheme then return nil end
    local hostport, path = rest:match("^([^/]+)(/.*)$")
    if not hostport then hostport, path = rest, "/" end
    local host, port = hostport:match("^([^:]+):(%d+)$")
    if not host then host, port = hostport, (scheme == "https") and "443" or "80" end
    return { scheme = scheme, host = host, port = tonumber(port), path = path }
end

-- ---- request bytes (HTTP/1.1, explicit length, no keep-alive) --------------------------------
function M.buildRequest(method, url, headers, body)
    local u = M.parseUrl(url)
    if not u then return nil end
    body = body or ""
    local lines = { tostring(method or "GET") .. " " .. u.path .. " HTTP/1.1",
                    "Host: " .. u.host .. ":" .. tostring(u.port),
                    "Connection: close",
                    "Content-Length: " .. tostring(#body) }
    for k, v in pairs(headers or {}) do
        lines[#lines + 1] = tostring(k) .. ": " .. tostring(v)
    end
    return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

-- ---- chunked transfer decoding (RFC 7230; algorithm authored for this mod, python-validated) --
function M.decodeChunked(raw)
    local out, pos = {}, 1
    while true do
        local lineEnd = raw:find("\r\n", pos, true)
        if not lineEnd then return nil end                    -- incomplete
        local sizeLine = raw:sub(pos, lineEnd - 1)
        local size = tonumber(sizeLine:match("^(%x+)") or "", 16)
        if not size then return nil end
        if size == 0 then return table.concat(out) end        -- terminal chunk
        local dataStart = lineEnd + 2
        local dataEnd = dataStart + size - 1
        if #raw < dataEnd + 2 then return nil end             -- incomplete
        out[#out + 1] = raw:sub(dataStart, dataEnd)
        pos = dataEnd + 3                                     -- past the data CRLF to the next size line
    end
end

-- ---- response object --------------------------------------------------------------------------
local Response = {}
Response.__index = Response
function Response.new(status, headers, body)
    return setmetatable({ _status = status, _headers = headers, _body = body }, Response)
end
function Response:getStatus() return self._status end
function Response:getBody() return self._body end
function Response:getHeader(k) return self._headers[string.lower(tostring(k))] end
function Response:getJson()
    if not jsonlib then return nil, "json lib unavailable" end
    local ok, obj = pcall(jsonlib.decode, self._body)
    if ok then return obj, nil end
    return nil, tostring(obj)
end

-- ---- header/status parse ----------------------------------------------------------------------
function M.parseResponse(buf)
    local headerEnd = buf:find("\r\n\r\n", 1, true)
    if not headerEnd then return nil end
    local head = buf:sub(1, headerEnd - 1)
    local status = tonumber(head:match("^HTTP/%d%.%d (%d%d%d)"))
    if not status then return nil, "bad status line" end
    local headers = {}
    for k, v in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
        headers[string.lower(k)] = v
    end
    local body = buf:sub(headerEnd + 4)
    return { status = status, headers = headers, partialBody = body }
end

-- ---- the async request state machine ----------------------------------------------------------
local pending = {}
local TIMEOUT_S = 30

local Request = {}
Request.__index = Request
function M.new(method)
    return setmetatable({ method = method or "GET", headers = {}, body = "", url = nil, timeout = TIMEOUT_S }, Request)
end
function Request:setTimeout(s) self.timeout = tonumber(s) or TIMEOUT_S return self end
function Request:setUrl(u) self.url = u return self end
function Request:addHeader(k, v) self.headers[k] = v return self end
function Request:setBody(b)
    if type(b) == "table" and jsonlib then b = jsonlib.encode(b) end
    self.body = tostring(b or "")
    return self
end
function Request:send(cb)
    if not initLibs() then if cb then cb(nil, "aic_http libs unavailable") end return end
    local u = M.parseUrl(self.url)
    if not u then if cb then cb(nil, "bad url") end return end
    if u.scheme == "https" then if cb then cb(nil, "https not enabled in aic_http yet") end return end
    local sock = socket.tcp()
    sock:settimeout(0)
    sock:connect(u.host, u.port)   -- returns timeout immediately in non-blocking mode; select confirms
    pending[#pending + 1] = {
        sock = sock, cb = cb, state = "connecting",
        payload = M.buildRequest(self.method, self.url, self.headers, self.body),
        sent = 0, buf = "", started = os and os.clock and os.clock() or 0,
        deadline = (GetCurRealTime and GetCurRealTime() or 0) + (self.timeout or TIMEOUT_S),
    }
end

local function finish(p, resp, err)
    pcall(function() p.sock:close() end)
    p.state = "done"
    if p.cb then pcall(p.cb, resp, err) end
end

local function pumpOne(p)
    if p.state == "connecting" then
        local _, writable = socket.select(nil, { p.sock }, 0)
        if writable and #writable > 0 then p.state = "sending" end
    end
    if p.state == "sending" then
        local i, err, last = p.sock:send(p.payload, p.sent + 1)
        if i then p.sent = i elseif last then p.sent = last end
        if err and err ~= "timeout" then finish(p, nil, "send: " .. tostring(err)) return end
        if p.sent >= #p.payload then p.state = "receiving" end
    end
    if p.state == "receiving" then
        local data, err, partial = p.sock:receive(65536)
        local got = data or partial
        if got and #got > 0 then p.buf = p.buf .. got end
        local closed = (err == "closed")
        local parsed = M.parseResponse(p.buf)
        if parsed then
            local te = tostring(parsed.headers["transfer-encoding"] or ""):lower()
            local cl = tonumber(parsed.headers["content-length"])
            if te:find("chunked", 1, true) then
                local bodyDone = M.decodeChunked(parsed.partialBody)
                if bodyDone then finish(p, Response.new(parsed.status, parsed.headers, bodyDone)) return end
            elseif cl then
                if #parsed.partialBody >= cl then
                    finish(p, Response.new(parsed.status, parsed.headers, parsed.partialBody:sub(1, cl))) return
                end
            end
            if closed then
                local body = te:find("chunked", 1, true) and (M.decodeChunked(parsed.partialBody) or parsed.partialBody) or parsed.partialBody
                finish(p, Response.new(parsed.status, parsed.headers, body)) return
            end
        elseif closed then
            finish(p, nil, "connection closed before headers") return
        end
    end
    if GetCurRealTime and GetCurRealTime() > p.deadline then
        finish(p, nil, "timeout") return
    end
end

function M.update()
    for i = #pending, 1, -1 do
        local p = pending[i]
        if p.state == "done" then
            table.remove(pending, i)
        else
            local ok, err = pcall(pumpOne, p)
            if not ok then finish(p, nil, "pump error: " .. tostring(err)); table.remove(pending, i) end
        end
    end
end
function M.pendingCount() return #pending end

-- pump wiring: the MD cue raises this every 50ms; throttle by real time (sinza-proof)
local lastUpdate = 0
local function onUpdate()
    local now = GetCurRealTime and GetCurRealTime() or 0
    if (now - lastUpdate) < 0.05 then return end
    lastUpdate = now
    M.update()
end
if RegisterEvent then RegisterEvent("aic.http.update", onUpdate) end

AIC_HTTP = M   -- global export: addon files are loaded directly (no require path), callers use this handle
return M
