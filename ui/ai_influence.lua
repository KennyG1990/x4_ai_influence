-- AI Influence Test Mod — Lua side of the round-trip.
-- MD raises "ai_influence.request"; we POST/GET the Neural Link bridge via djfhe,
-- then raise an event_ui_triggered back to MD carrying the validated action.
-- djfhe is required LAZILY inside the handler — our UI Lua can load before djfhe's init.lua,
-- so a top-level require would fail "module not found". By event time djfhe is loaded.
local function on_request(_, payload)
  local okr, Request = pcall(require, "djfhe.http.request")
  local okj, json = pcall(require, "jsonlua.json")
  if not okr or not Request then
    AddUITriggeredEvent("ai_influence", "action", { type = "error", message = "djfhe_http not loaded" })
    return
  end
  local faction = (payload and payload.faction) or "split"
  -- djfhe fluent API: Request.new(method):setUrl():send(callback). (NOT Request:new({...}).)
  Request.new("GET")
    :setUrl("http://127.0.0.1:8713/api/test/llm_action?faction=" .. tostring(faction))
    :send(function(response, err)
      if err then
        AddUITriggeredEvent("ai_influence", "action", { type = "error", message = tostring(err) })
        return
      end
      local body = response and response:getBody() or "{}"
      local ok, decoded = pcall(json.decode, body)
      local msg = "Neural Link test: no message"
      if ok and decoded and decoded.action and decoded.action.params and decoded.action.params.message then
        msg = decoded.action.params.message
      end
      AddUITriggeredEvent("ai_influence", "action", { type = "show_notification", message = msg })
    end)
end

RegisterEvent("ai_influence.request", on_request)
