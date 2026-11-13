-- The simulated edge client used by the tests: cfg, app, log, json, lynx, mq, timer and the clock. All names,
-- addresses and numbers are made up.

local S = {}

-- ---- a tiny JSON for the simulation (the edge client has its own) ----------------------------------------------

S.json = { null = setmetatable({}, { __tostring = function() return "null" end }) }
function S.json:encode(v)
  local t = type(v)
  if t == "nil" or v == S.json.null then return "null" end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
  local keys, is_list = {}, (#v > 0)
  if is_list then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = S.json:encode(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = S.json:encode(tostring(k)) .. ":" .. S.json:encode(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
function S.json:decode(s) -- a small but real JSON decoder
  local i = 1
  local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
  local value
  local function str()
    local out = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == '"' then i = i + 1 break end
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        if n == "u" then out[#out + 1] = utf8 and utf8.char(tonumber(s:sub(i + 2, i + 5), 16)) or string.char(tonumber(s:sub(i + 2, i + 5), 16) % 256) i = i + 6
        else out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[n] or n i = i + 2 end
      else out[#out + 1] = c i = i + 1 end
    end
    return table.concat(out)
  end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local t = {}
      i = i + 1 ws()
      if s:sub(i, i) == "}" then i = i + 1 return t end
      while true do
        ws() local k = str() ws() i = i + 1
        t[k] = value() ws()
        local d = s:sub(i, i) i = i + 1
        if d == "}" then return t end
      end
    elseif c == "[" then
      local t = {}
      i = i + 1 ws()
      if s:sub(i, i) == "]" then i = i + 1 return t end
      while true do
        t[#t + 1] = value() ws()
        local d = s:sub(i, i) i = i + 1
        if d == "]" then return t end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4 return S.json.null
    else
      local n = s:match("^-?[%d%.eE+-]+", i)
      i = i + #n
      return tonumber(n)
    end
  end
  return value()
end

-- ---- the simulated edge client -------------------------------------------------------------------------------------

S.T0 = 1794300000 -- 2026-11-10 08:40 UTC (09:40 in Stockholm), a Tuesday

function S.fn(id, topic, name, extra)
  local meta = { name = name or ("Givare " .. id), topic_read = topic, state_true = "1", state_false = "0" }
  for k, v in pairs(extra or {}) do meta[k] = v end
  return { id = id, installation_id = 1001, type = "boolean_text", meta = meta }
end

S.MODE = { id = 950, installation_id = 1001, type = "mode", meta = { name = "Läge", topic_read = "obj/mode/default", topic_write = "set/obj/mode/default", ["mode.name"] = "default", ["mode.states"] = "0:home:Hemma,1:away:Borta,2:vacation:Semester" } }

--- Loads app.lua in a simulated edge client. opts: cfg, functions, retained, clock, config_refused.
function S.load_app(opts)
  opts = opts or {}
  local sim = { api = {}, created = {}, retained = opts.retained or {}, clock = opts.clock or S.T0, timers = {}, published = {}, logs = {}, handlers = {} }
  local all = {}
  for _, f in ipairs(opts.functions or {}) do all[#all + 1] = f end
  sim.instance_config = opts.cfg or {}
  function sim.add_function(f) all[#all + 1] = f end
  function sim.fn(id) for _, f in ipairs(all) do if f.id == id then return f end end end
  local function match(item, filter)
    for k, v in pairs(filter or {}) do
      if k == "type" then if item.type ~= v then return false end
      elseif (item.meta or {})[k] ~= v then return false end
    end
    return true
  end
  local next_id = 5000
  local lynx = {
    getFunctions = function(filter)
      local out = {}
      for _, f in ipairs(all) do if match(f, filter) then out[#out + 1] = f end end
      return out
    end,
    getDevices = function() return {} end,
    createFunction = function(f)
      next_id = next_id + 1
      f.id = next_id
      all[#all + 1] = f
      sim.created[#sim.created + 1] = f
      return f
    end,
    notify = function(id, body)
      if opts.notify_fails and opts.notify_fails(sim) then error("no connection") end
      sim.notified = sim.notified or {}
      sim.notified[#sim.notified + 1] = { id = id, body = body, at = sim.clock }
    end,
    apiCall = function(method, path, body)
      sim.api[#sim.api + 1] = { method = method, path = path, body = body }
      local fid = path:match("^/api/v2/functionx/%d+/(%d+)$")
      if method == "PUT" and fid then
        for _, f in ipairs(all) do if f.id == tonumber(fid) then f.meta = body.meta f.type = body.type end end
        return body
      end
      if path:match("^/api/v2/edge/app/configured/%d+$") and method == "GET" then
        if opts.config_refused then error("403 forbidden") end
        return { { id = 5, app_id = 77, name = "App", version = "0.1.0", config = sim.instance_config } }
      end
      if path:match("^/api/v2/edge/app/configured/%d+/5$") and method == "PUT" then
        if opts.config_refused then error("403 forbidden") end
        sim.instance_config = body.config
        return body
      end
      error("unexpected call " .. method .. " " .. path)
    end,
  }
  function sim.puts(prefix)
    local out = {}
    for _, c in ipairs(sim.api) do if c.method == "PUT" and c.path:sub(1, #prefix) == prefix then out[#out + 1] = c end end
    return out
  end
  local mq = {}
  function mq:sub() end
  function mq:bind(topic, fn)
    sim.handlers[topic] = fn
    if sim.retained[topic] then fn(topic, sim.retained[topic]) end
  end
  function mq:unbind(topic) sim.handlers[topic] = nil end
  function mq:pub(topic, payload, retain)
    sim.published[#sim.published + 1] = { topic = topic, payload = payload, at = sim.clock }
    if retain then sim.retained[topic] = payload end
  end
  local timer = {}
  function timer:after(secs, fn)
    local t = { at = sim.clock + secs, fn = fn }
    sim.timers[#sim.timers + 1] = t
    return { cancel = function() t.fn = nil end }
  end
  local function logger(level) return function(f, ...) sim.logs[#sim.logs + 1] = level .. " " .. string.format(f, ...) end end
  local os_fake = setmetatable({ time = function() return sim.clock end }, { __index = os })
  local env = setmetatable({
    [opts.flag or "LIMIT_TEST"] = true,
    cfg = sim.instance_config,
    app = { id = 5, installation_id = 1001, name = "App" },
    json = S.json, lynx = lynx, mq = mq, timer = timer, os = os_fake,
    log = { i = logger("I"), e = logger("E"), d = logger("D") },
  }, { __index = _G })
  local M = assert(loadfile("app.lua", "t", env))()
  function sim.advance(secs)
    local target = sim.clock + secs
    while true do
      table.sort(sim.timers, function(a, b) return a.at < b.at end)
      local nxt = sim.timers[1]
      if not nxt or nxt.at > target then break end
      table.remove(sim.timers, 1)
      sim.clock = nxt.at
      if nxt.fn then nxt.fn() end
    end
    sim.clock = target
  end
  function sim.value(topic, value)
    local h = sim.handlers[topic]
    assert(h, "not subscribed to " .. topic)
    h(topic, S.json:encode({ value = value, timestamp = sim.clock }))
  end
  function sim.set(topic, value, msg)
    local h = sim.handlers[topic]
    assert(h, "not subscribed to " .. topic)
    h(topic, S.json:encode({ value = value, msg = msg }))
  end
  function sim.pubs(topic)
    local out = {}
    for _, p in ipairs(sim.published) do if p.topic == topic then out[#out + 1] = S.json:decode(p.payload) end end
    return out
  end
  function sim.last(topic) local p = sim.pubs(topic) return p[#p] end
  return M, env, sim
end

return S
