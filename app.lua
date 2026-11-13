-- Limit guard (Gränsvakt): raises an alarm when something happened too much or too little within a time window.
--
-- One app instance is one rule with four choices:
--   - what is counted, from the functions in the form (metadata limit.group):
--       count     the number of times a function becomes active, or goes above or below a value (an event)
--       distinct  the number of different functions with an event
--       increase  how much a meter reading went up (a reset of the meter counts from 0)
--   - the window: rolling (the last N minutes) or scheduled (for example 23:00-06:00 on chosen days, local time)
--   - the limit: at most N (alarm as soon as it is passed) or at least N (alarm when the window had too little:
--     a rolling window after one whole window since start, a scheduled window when it closes)
--   - the alarm: a function of the app's own (obj/limit/<group>/alarm, 1 = alarm, 0 = no alarm) that the
--     dashboard, IoT Open's notifications or För länge take from there. Writing 0 to set/obj/limit/<group>/alarm
--     acknowledges it: it stays 0 until the rule is broken again.
--
-- Examples: water (increase, rolling 60 min, at most 50 l), traffic (count, rolling 10 min, at most 2), the back
-- yard (distinct motion sensors, rolling 2 min, at most 1), the fridge compressor (count of power above 30 W,
-- rolling 120 min, at least 1), night noise (count, 23:00-06:00, at most 2).
--
-- The functions are chosen in the form and stored as metadata on the functions (limit.group, limit.label); the
-- two are kept in step both ways, and whoever changed last wins, as in För länge 0.4. Events, the alarm and the form
-- the app last applied are kept retained on the local broker, so a restart goes on where it was.

local VERSION = "0.1.0"
local PREFIX = "limit"
local TICK_S = 10
local SYNC_WAIT_S = 3
local MAX_EVENTS = 2000

local M = {}

-- ---- small helpers -----------------------------------------------------------------------------------------------

local function is_null(v) return v == nil or (json ~= nil and v == json.null) end
local function num(v, d) local n = tonumber(v) if n == nil or n ~= n then return d end return n end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function str(v) if is_null(v) then return "" end return trim(v) end
local function first_set(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if not is_null(v) and trim(v) ~= "" then return trim(v) end
  end
  return nil
end

--- The edge client's log has i, e and d (no w): warnings are written with log.i.
local function warn(f, ...) log.i("warning: " .. f, ...) end

local function ids(v)
  local out = {}
  if type(v) == "table" then
    for k, x in pairs(v) do
      local id = type(k) == "number" and tonumber(x) or tonumber(k) or tonumber(x)
      if id then out[#out + 1] = math.floor(id) end
    end
  elseif tonumber(v) then
    out[1] = math.floor(tonumber(v))
  end
  table.sort(out)
  return out
end

--- A key from a name a person writes: "Hemtjänst natt" -> "hemtjanst_natt". Keys are kept as they are.
function M.slug(v)
  local t = str(v)
  for from, to in pairs({ ["å"] = "a", ["Å"] = "a", ["ä"] = "a", ["Ä"] = "a", ["ö"] = "o", ["Ö"] = "o", ["é"] = "e", ["É"] = "e", ["ü"] = "u", ["Ü"] = "u" }) do
    t = t:gsub(from, to)
  end
  t = t:lower():gsub("[^a-z0-9_%-]+", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
  return t
end

function M.same_value(a, b)
  if is_null(a) or is_null(b) then return false end
  local na, nb = tonumber(a), tonumber(b)
  if na ~= nil and nb ~= nil then return na == nb end
  return tostring(a) == tostring(b)
end

-- ---- local time without a time zone database ----------------------------------------------------------------------

-- The edge client runs in UTC. Offsets in hours and whether the EU summer time rule applies (last Sunday of March to
-- the last Sunday of October, at 01:00 UTC).
M.ZONES = {
  ["Europe/Stockholm"] = { 1, true }, ["Europe/Oslo"] = { 1, true }, ["Europe/Copenhagen"] = { 1, true },
  ["Europe/Berlin"] = { 1, true }, ["Europe/Helsinki"] = { 2, true }, ["Europe/London"] = { 0, true },
  ["UTC"] = { 0, false },
}

local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = (z >= 0 and z or z - 146096) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp + (mp < 10 and 3 or -9)
  return m <= 2 and y + 1 or y, m, d
end

local function last_sunday(y, m)
  local last = days_from_civil(y, m + 1, 1) - 1 -- m is 3 or 10
  local wd = (last + 3) % 7 -- 0 = Monday (1970-01-01 was a Thursday)
  return last - ((wd - 6) % 7)
end

--- The offset from UTC in seconds at UTC time t.
function M.offset(t, zone)
  local z = M.ZONES[zone] or M.ZONES["Europe/Stockholm"]
  local off = z[1] * 3600
  if z[2] then
    local y = civil_from_days(t // 86400)
    local from = last_sunday(y, 3) * 86400 + 3600
    local to = last_sunday(y, 10) * 86400 + 3600
    if t >= from and t < to then off = off + 3600 end
  end
  return off
end

--- Local day number (days since 1970-01-01), seconds into the local day and weekday (1 = Monday) at UTC time t.
function M.local_time(t, zone)
  local lt = t + M.offset(t, zone)
  local day = lt // 86400
  return day, lt % 86400, (day + 3) % 7 + 1
end

--- "23:00" -> seconds into the day, or nil.
function M.clock(v)
  local h, m = str(v):match("^(%d%d?)[:.](%d%d)$")
  if not h then h = str(v):match("^(%d%d?)$") m = "0" end
  h, m = tonumber(h), tonumber(m)
  if not h or h > 24 or m > 59 then return nil end
  return (h * 3600 + m * 60) % 86400
end

local DAYS = { mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6, sun = 7 }

--- The scheduled window that holds UTC time t, as { start, stop } in UTC, or nil. A window that ends at or before
--- its start time runs over midnight and belongs to the day it starts.
function M.window_at(t, sched, zone)
  local day, sec = M.local_time(t, zone)
  local len = (sched.to - sched.from) % 86400
  if len == 0 then len = 86400 end
  for back = 0, 1 do
    local wd = (day - back + 3) % 7 + 1
    local into = sec + back * 86400 - sched.from -- seconds since the window opened, if it opened that day
    if sched.days[wd] and into >= 0 and into < len then
      return { start = t - into, stop = t - into + len }
    end
  end
  return nil
end

-- ---- settings ------------------------------------------------------------------------------------------------------

function M.settings(c)
  c = c or {}
  local days = {}
  local any = false
  for _, k in ipairs(type(c.schedule_days) == "table" and c.schedule_days or {}) do
    if DAYS[str(k):lower()] then days[DAYS[str(k):lower()]] = true any = true end
  end
  if not any then for i = 1, 7 do days[i] = true end end
  local s = {
    name = str(c.name) ~= "" and str(c.name) or "Gränsvakt",
    group = M.slug(c.group) ~= "" and M.slug(c.group) or (PREFIX .. "-" .. tostring(app and app.id or 0)),
    measure = ({ count = "count", distinct = "distinct", increase = "increase" })[str(c.measure)] or "count",
    event = ({ active = "active", above = "above", below = "below" })[str(c.event)] or "active",
    threshold = tonumber(c.threshold),
    active_value = str(c.active_value),
    window = str(c.window) == "schedule" and "schedule" or "rolling",
    window_s = math.max(1, num(c.window_min, 60)) * 60,
    schedule = { from = M.clock(c.schedule_from) or 0, to = M.clock(c.schedule_to) or 0, days = days },
    zone = M.ZONES[str(c.timezone)] and str(c.timezone) or "Europe/Stockholm",
    limit_kind = str(c.limit_kind) == "at_least" and "at_least" or "at_most",
    limit = num(c.limit, 1),
    event_gap_s = math.max(0, num(c.event_gap_s, 0)),
    mode_name = str(c.mode_name) ~= "" and M.slug(c.mode_name) or "default",
    active_modes = {},
  }
  for part in str(c.active_modes):gmatch("[^,;]+") do
    if M.slug(part) ~= "" then s.active_modes[#s.active_modes + 1] = M.slug(part) end
  end
  if (s.event == "above" or s.event == "below") and s.threshold == nil then s.event = "active" end
  return s
end

-- ---- the rule: pure logic, driven by values and a clock ---------------------------------------------------------

local Rule = {}
Rule.__index = Rule

function M.rule(settings)
  return setmetatable({ settings = settings, events = {}, last = {}, on = {}, since = nil, alarm = 0, acked = false,
    period = nil, verdict = nil }, Rule)
end

--- Whether a value is an event state for a function (active value, or above / below the threshold).
function Rule:is_on(fn, value)
  local s = self.settings
  if s.event == "above" then return tonumber(value) ~= nil and tonumber(value) > s.threshold end
  if s.event == "below" then return tonumber(value) ~= nil and tonumber(value) < s.threshold end
  local meta = fn and fn.meta or {}
  local active = first_set(meta[PREFIX .. ".active_value"], s.active_value, meta.state_open, meta.state_on, meta.state_true) or "1"
  return M.same_value(value, active)
end

--- A value from function `id`; returns true when it added an event.
function Rule:value(id, fn, value, ts)
  local s = self.settings
  if s.measure == "increase" then
    local v = tonumber(value)
    if v == nil then return false end
    local prev = self.last[id]
    self.last[id] = v
    if prev == nil then return false end
    local amount = v >= prev and v - prev or v -- a meter that starts over counts from 0
    if amount <= 0 then return false end
    self.events[#self.events + 1] = { ts = ts, id = id, amount = amount }
    return true
  end
  local on = self:is_on(fn, value)
  local was = self.on[id]
  self.on[id] = on
  if not on or was then return false end
  if s.event_gap_s > 0 then
    for i = #self.events, 1, -1 do
      local e = self.events[i]
      if e.id == id then
        if ts - e.ts < s.event_gap_s then return false end
        break
      end
    end
  end
  self.events[#self.events + 1] = { ts = ts, id = id, amount = 1 }
  return true
end

--- The measure over events in [from, to).
function Rule:measure(from, to)
  local total, seen, n = 0, {}, 0
  for _, e in ipairs(self.events) do
    if e.ts >= from and e.ts < to then
      if self.settings.measure == "distinct" then
        if not seen[e.id] then seen[e.id] = true n = n + 1 end
      else
        total = total + e.amount
      end
    end
  end
  if self.settings.measure == "distinct" then return n end
  return total
end

--- The window to evaluate at time `now`: { start, stop } (rolling: the last window_s), or nil outside a schedule.
function Rule:window(now)
  local s = self.settings
  if s.window == "rolling" then return { start = now - s.window_s, stop = now + 1 } end
  return M.window_at(now, s.schedule, s.zone)
end

--- Evaluates the rule; returns "alarm", "clear" or nil (no change), and the value and window.
function Rule:evaluate(now, paused)
  local s = self.settings
  local w = self:window(now)
  local value = w and self:measure(w.start, w.stop) or 0
  local broken = false
  if paused then
    broken = false
  elseif s.limit_kind == "at_most" then
    broken = w ~= nil and value > s.limit
  elseif s.window == "rolling" then
    broken = self.since ~= nil and now - self.since >= s.window_s and value < s.limit
  else
    -- at least, scheduled: decided when the window closes, and stands until the next window decides
    if self.period and (w == nil or w.start ~= self.period.start) then
      local closed = self.period
      -- only a window watched from its start is judged
      if self.since and closed.start >= self.since then
        self.closed_value = self:measure(closed.start, closed.stop)
        self.verdict = self.closed_value < s.limit and "short" or "ok"
      end
      self.period = nil
    end
    if w and not self.period then self.period = { start = w.start, stop = w.stop } end
    if w and value >= s.limit then self.verdict = "ok" end
    broken = self.verdict == "short"
    if broken then value = self.closed_value or value end
  end
  self.value_now, self.window_now = value, w
  if not broken then
    self.acked = false
    if self.alarm == 1 then self.alarm = 0 return "clear", value, w end
    return nil, value, w
  end
  if self.alarm == 0 and not self.acked then self.alarm = 1 return "alarm", value, w end
  return nil, value, w
end

--- Acknowledged: no alarm until the rule has been kept and is broken again.
function Rule:acknowledge()
  if self.alarm == 1 then self.alarm = 0 self.acked = true return true end
  return false
end

--- Drops events no window can need any more.
function Rule:prune(now)
  local keep_s = self.settings.window == "rolling" and self.settings.window_s or 2 * 86400
  local out = {}
  for _, e in ipairs(self.events) do if now - e.ts <= keep_s then out[#out + 1] = e end end
  while #out > MAX_EVENTS do table.remove(out, 1) end
  self.events = out
end

--- The state as text for the retained topic: since, alarm, acked, period, verdict, then events and meter readings.
function Rule:dump()
  local parts = {
    "since=" .. tostring(self.since or ""), "alarm=" .. tostring(self.alarm), "acked=" .. (self.acked and "1" or "0"),
    "period=" .. (self.period and (self.period.start .. "-" .. self.period.stop) or ""), "verdict=" .. tostring(self.verdict or ""),
    "closed=" .. tostring(self.closed_value or ""),
  }
  local ev = {}
  for _, e in ipairs(self.events) do ev[#ev + 1] = e.ts .. ":" .. e.id .. ":" .. e.amount end
  parts[#parts + 1] = "events=" .. table.concat(ev, ",")
  local last = {}
  for id, v in pairs(self.last) do last[#last + 1] = id .. ":" .. v end
  table.sort(last)
  parts[#parts + 1] = "last=" .. table.concat(last, ",")
  local on = {}
  for id, v in pairs(self.on) do if v then on[#on + 1] = tostring(id) end end
  table.sort(on)
  parts[#parts + 1] = "on=" .. table.concat(on, ",")
  return table.concat(parts, ";")
end

function Rule:load(text)
  local f = {}
  for k, v in tostring(text or ""):gmatch("(%w+)=([^;]*)") do f[k] = v end
  self.since = tonumber(f.since)
  self.alarm = tonumber(f.alarm) == 1 and 1 or 0
  self.acked = f.acked == "1"
  local a, b = tostring(f.period or ""):match("^(%d+)%-(%d+)$")
  self.period = a and { start = tonumber(a), stop = tonumber(b) } or nil
  self.verdict = f.verdict ~= "" and f.verdict or nil
  self.closed_value = tonumber(f.closed)
  self.events = {}
  for ts, id, amount in tostring(f.events or ""):gmatch("(%d+):(%d+):([%d%.e%-]+)") do
    self.events[#self.events + 1] = { ts = tonumber(ts), id = tonumber(id), amount = tonumber(amount) }
  end
  for id, v in tostring(f.last or ""):gmatch("(%d+):([%d%.e%-]+)") do self.last[tonumber(id)] = tonumber(v) end
  for id in tostring(f.on or ""):gmatch("%d+") do self.on[tonumber(id)] = true end
end

M.Rule = Rule

-- ---- the installation's mode -----------------------------------------------------------------------------------

function M.mode_states(text)
  local states, labels = {}, {}
  for part in tostring(text or ""):gmatch("[^,]+") do
    local v, key, label = part:match("^%s*(%d+):([%w_%-]+):?(.*)$")
    if v then
      states[tonumber(v)] = key
      labels[key] = key
      if M.slug(label) ~= "" then labels[M.slug(label)] = key end
    end
  end
  return states, labels
end

function M.mode_ok(settings, key)
  if #settings.active_modes == 0 or key == nil then return true end
  for _, k in ipairs(settings.active_modes) do if k == key then return true end end
  return false
end

-- ---- the form and the metadata (as in För länge 0.4) ------------------------------------------------------------

local FIELDS = { "label" }

function M.groups(v)
  local out = {}
  for part in str(v):gmatch("[^,;]+") do
    local g = M.slug(part)
    if g ~= "" then out[#out + 1] = g end
  end
  return out
end

function M.in_group(fn, group)
  for _, g in ipairs(M.groups((fn.meta or {})[PREFIX .. ".group"])) do if g == group then return true end end
  return false
end

function M.form_rows(c)
  local out, seen = {}, {}
  for _, w in ipairs(type(c) == "table" and type(c.watch) == "table" and c.watch or {}) do
    if type(w) == "table" then
      local id = ids(w.watch_function)[1]
      if id and not seen[id] then
        seen[id] = true
        out[#out + 1] = { id = id, label = str(w.watch_label) }
      end
    end
  end
  return out
end

function M.meta_rows(functions, group, order)
  local by, out = {}, {}
  for _, fn in ipairs(functions or {}) do
    if fn.id and M.in_group(fn, group) then by[fn.id] = { id = fn.id, label = str((fn.meta or {})[PREFIX .. ".label"]) } end
  end
  for _, id in ipairs(order or {}) do if by[id] then out[#out + 1] = by[id] by[id] = nil end end
  local rest = {}
  for id in pairs(by) do rest[#rest + 1] = id end
  table.sort(rest)
  for _, id in ipairs(rest) do out[#out + 1] = by[id] end
  return out
end

local function clean(v) return (tostring(v or ""):gsub("[\t\r\n]", " ")) end

function M.rows_text(rows)
  local lines = {}
  for _, r in ipairs(rows or {}) do lines[#lines + 1] = tostring(r.id) .. "\t" .. clean(r.label) end
  return table.concat(lines, "\n")
end

function M.parse_rows(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local id, label = line:match("^(%d+)\t?(.*)$")
    if id then out[#out + 1] = { id = tonumber(id), label = label or "" } end
  end
  return out
end

function M.plan(prev, form, functions, group)
  local fns, out, before, after = {}, {}, {}, {}
  for _, fn in ipairs(functions or {}) do if fn.id then fns[fn.id] = fn end end
  for _, r in ipairs(prev or {}) do before[r.id] = r end
  for _, r in ipairs(form) do after[r.id] = r end
  local function set(id, key, value) out[id] = out[id] or {} out[id][key] = value end
  for _, r in ipairs(form) do
    local fn = fns[r.id]
    if fn then
      local old = before[r.id]
      if not M.in_group(fn, group) and (old == nil or prev == nil) then
        local gs = M.groups((fn.meta or {})[PREFIX .. ".group"])
        gs[#gs + 1] = group
        set(r.id, PREFIX .. ".group", table.concat(gs, ","))
      end
      for _, f in ipairs(FIELDS) do
        local key, value = PREFIX .. "." .. f, r[f]
        local current = str((fn.meta or {})[key])
        if prev == nil or old == nil then
          if value ~= "" and value ~= current then set(r.id, key, value) end
        elseif value ~= old[f] and value ~= current then
          set(r.id, key, value ~= "" and value or false)
        end
      end
    end
  end
  for _, r in ipairs(prev or {}) do
    local fn = fns[r.id]
    if not after[r.id] and fn and M.in_group(fn, group) then
      local keep = {}
      for _, g in ipairs(M.groups(fn.meta[PREFIX .. ".group"])) do if g ~= group then keep[#keep + 1] = g end end
      set(r.id, PREFIX .. ".group", #keep > 0 and table.concat(keep, ",") or false)
    end
  end
  return out
end

function M.form_watch(rows)
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = { watch_function = r.id, watch_label = r.label } end
  return out
end

-- ---- glue: the edge client -----------------------------------------------------------------------------------------

local state = { settings = nil, rule = nil, functions = {}, watched = {}, by_topic = {}, mode_topic = nil,
  mode_states = {}, mode_key = nil, form_applied = nil, form_received = false, synced = false, alarm_fn = nil,
  restored = false }

local function now() return os.time() end
local function base() return "obj/" .. PREFIX .. "/" .. state.settings.group end
local function alarm_topic() return base() .. "/alarm" end
local function set_topic() return "set/" .. alarm_topic() end
local function state_topic() return base() .. "/state" end
local function form_topic() return base() .. "/form" end

local function pub(topic, value, msg, retain)
  mq:pub(topic, json:encode({ value = value, msg = msg or "", timestamp = now() }), retain == true, 1)
end

local function labels_of(w)
  local seen, out = {}, {}
  for _, e in ipairs(state.rule.events) do
    if w and e.ts >= w.start and e.ts < w.stop and not seen[e.id] then
      seen[e.id] = true
      local fn = state.watched[e.id]
      out[#out + 1] = fn and first_set((fn.meta or {})[PREFIX .. ".label"], (fn.meta or {}).name) or tostring(e.id)
    end
  end
  return table.concat(out, ", ")
end

local function save_state() pub(state_topic(), state.rule:dump(), "state", true) end

local function evaluate()
  local paused = not M.mode_ok(state.settings, state.mode_key)
  local before = state.rule.period and state.rule.period.start
  local change, value, w = state.rule:evaluate(now(), paused)
  -- a scheduled window that opened is saved, so a restart after it closed still judges it
  if change == nil and (state.rule.period and state.rule.period.start) ~= before then save_state() end
  if change == "alarm" then
    local s = state.settings
    local what = s.limit_kind == "at_most" and "too much" or "too little"
    local msg = string.format("%s: %s (%s %s)", what, tostring(value), s.limit_kind == "at_most" and "at most" or "at least", tostring(s.limit))
    local who = labels_of(w)
    if who ~= "" then msg = msg .. ": " .. who end
    log.i("%s: alarm, %s", s.name, msg)
    pub(alarm_topic(), 1, msg, true)
    save_state()
  elseif change == "clear" then
    log.i("%s: no alarm", state.settings.name)
    pub(alarm_topic(), 0, "ok", true)
    save_state()
  end
end

local function on_value(topic, payload)
  local ok, data = pcall(json.decode, json, payload)
  if not ok or type(data) ~= "table" then return end
  local id = state.by_topic[topic]
  if not id then return end
  local was = state.rule.on[id]
  if state.rule:value(id, state.watched[id], data.value, now()) or state.rule.on[id] ~= was then save_state() end
  evaluate()
end

local function on_set(_, payload)
  local ok, data = pcall(json.decode, json, payload)
  local v = ok and type(data) == "table" and data.value or trim(payload)
  if tonumber(v) == 0 and state.rule:acknowledge() then
    local who = ok and type(data) == "table" and str(data.msg) or ""
    log.i("%s: acknowledged%s", state.settings.name, who ~= "" and (" (" .. who .. ")") or "")
    pub(alarm_topic(), 0, who ~= "" and ("acknowledged: " .. who) or "acknowledged", true)
    save_state()
  end
end

local function on_mode(_, payload)
  local ok, data = pcall(json.decode, json, payload)
  if ok and type(data) == "table" then state.mode_key = state.mode_states[tonumber(data.value)] end
end

local function on_state(_, payload)
  if state.restored then return end
  state.restored = true
  local ok, data = pcall(json.decode, json, payload)
  if ok and type(data) == "table" and data.value then
    state.rule:load(data.value)
    log.i("%s: %d events restored from before the restart", state.settings.name, #state.rule.events)
  end
end

local function on_form(_, payload)
  if state.form_received then return end
  local ok, data = pcall(json.decode, json, payload)
  if not ok or type(data) ~= "table" then return end
  state.form_received = true
  state.form_applied = M.parse_rows(data.value)
end

local bound = {}
local function bind(topic, fn)
  if bound[topic] then mq:unbind(topic, bound[topic]) end
  bound[topic] = fn
  mq:sub(topic, 1)
  mq:bind(topic, fn)
end

--- The alarm function: created once, found again by limit.app_id.
local function ensure_alarm_function()
  local mine
  for _, fn in ipairs(state.functions) do
    if fn.meta and tostring(fn.meta[PREFIX .. ".app_id"]) == tostring(app.id) then mine = fn break end
  end
  local meta = {
    name = state.settings.name .. " larm", topic_read = alarm_topic(), topic_write = set_topic(),
    state_true = "1", state_false = "0", [PREFIX .. ".app_id"] = tostring(app.id),
  }
  if mine == nil then
    lynx.createFunction({ type = "alarm", installation_id = app.installation_id, meta = meta })
    log.i("alarm function created (%s)", alarm_topic())
    return
  end
  local changed = mine.type ~= "alarm"
  local new = {}
  for k, v in pairs(mine.meta or {}) do new[k] = v end
  for k, v in pairs(meta) do
    if k ~= "name" and new[k] ~= v then new[k] = v changed = true end -- a name changed by hand is kept
  end
  if changed then
    lynx.apiCall("PUT", "/api/v2/functionx/" .. tostring(mine.installation_id or app.installation_id) .. "/" .. tostring(mine.id), {
      id = mine.id, installation_id = mine.installation_id or app.installation_id, type = "alarm", meta = new,
      protected_meta = mine.protected_meta or {},
    })
  end
end

local function refresh()
  state.functions = lynx.getFunctions() or {}
  local topics = {}
  state.watched, state.by_topic = {}, {}
  for _, fn in ipairs(state.functions) do
    if M.in_group(fn, state.settings.group) and fn.meta and fn.meta.topic_read then
      state.watched[fn.id] = fn
      state.by_topic[fn.meta.topic_read] = fn.id
      topics[fn.meta.topic_read] = true
    end
  end
  for topic, fn in pairs(bound) do
    if fn == on_value and not topics[topic] then mq:unbind(topic, fn) bound[topic] = nil end
  end
  for topic in pairs(topics) do if bound[topic] ~= on_value then bind(topic, on_value) end end
  state.mode_topic = nil
  if #state.settings.active_modes > 0 then
    for _, fn in ipairs(lynx.getFunctions({ ["mode.name"] = state.settings.mode_name }) or {}) do
      if fn.type == "mode" and fn.meta and fn.meta.topic_read then
        local labels
        state.mode_states, labels = M.mode_states(fn.meta["mode.states"])
        for i, k in ipairs(state.settings.active_modes) do state.settings.active_modes[i] = labels[k] or k end
        state.mode_topic = fn.meta.topic_read
        if bound[state.mode_topic] ~= on_mode then bind(state.mode_topic, on_mode) end
        break
      end
    end
    if state.mode_topic == nil then warn("no mode function (type mode, mode.name = %s): the rule always applies", state.settings.mode_name) end
  end
  local n = 0
  for _ in pairs(state.watched) do n = n + 1 end
  return n
end

-- keeping the form and the metadata in step

local function write_meta(fn, changes)
  local meta = {}
  for k, v in pairs(fn.meta or {}) do meta[k] = v end
  local changed = false
  for k, v in pairs(changes) do
    if v == false then
      if meta[k] ~= nil then meta[k] = nil changed = true end
    elseif meta[k] ~= v then meta[k] = v changed = true end
  end
  if not changed then return false end
  lynx.apiCall("PUT", "/api/v2/functionx/" .. tostring(fn.installation_id or app.installation_id) .. "/" .. tostring(fn.id), {
    id = fn.id, installation_id = fn.installation_id or app.installation_id, type = fn.type, meta = meta,
    protected_meta = fn.protected_meta or {},
  })
  return true
end

local function decoded(v)
  if type(v) == "string" then
    local ok, d = pcall(json.decode, json, v)
    if ok then return d end
  end
  return v
end

local warned_mirror = false
local function mirror(rows)
  local iid = app.installation_id
  local ok, err = pcall(function()
    local list = decoded(lynx.apiCall("GET", "/api/v2/edge/app/configured/" .. tostring(iid)))
    local inst
    for _, x in ipairs(type(list) == "table" and list or {}) do
      if type(x) == "table" and tonumber(x.id) == tonumber(app.id) then inst = x break end
    end
    assert(inst, "this instance was not found")
    local config = {}
    for k, v in pairs(decoded(inst.config) or {}) do config[k] = v end
    config.watch = M.form_watch(rows)
    local body = {}
    for k, v in pairs(inst) do body[k] = v end
    body.config = config
    body.installation_id = iid
    lynx.apiCall("PUT", "/api/v2/edge/app/configured/" .. tostring(iid) .. "/" .. tostring(app.id), body)
  end)
  if not ok then
    if not warned_mirror then warn("the form could not be updated from the metadata (%s)", tostring(err)) end
    warned_mirror = true
    return false
  end
  log.i("form updated from the metadata: %d functions", #rows)
  return true
end

local function save_form(rows)
  state.form_applied = rows
  pub(form_topic(), M.rows_text(rows), "form", true)
end

local function sync()
  local form = M.form_rows(cfg)
  local prev = state.form_received and state.form_applied or nil
  local functions = lynx.getFunctions() or {}
  if prev == nil or M.rows_text(prev) ~= M.rows_text(form) then
    local plan, n = M.plan(prev, form, functions, state.settings.group), 0
    for _, fn in ipairs(functions) do
      if plan[fn.id] then
        local ok, res = pcall(write_meta, fn, plan[fn.id])
        if not ok then warn("function %s could not be updated: %s", tostring(fn.id), tostring(res))
        elseif res then n = n + 1 end
      end
    end
    if n > 0 then log.i("form applied: %d functions updated", n) functions = lynx.getFunctions() or {} end
  end
  local order = {}
  for _, r in ipairs(form) do order[#order + 1] = r.id end
  local rows = M.meta_rows(functions, state.settings.group, order)
  if M.rows_text(rows) ~= M.rows_text(form) and not mirror(rows) then save_form(form) else save_form(rows) end
  state.synced = true
end

local function check_form()
  if not state.synced then return end
  local order = {}
  for _, r in ipairs(state.form_applied or {}) do order[#order + 1] = r.id end
  local rows = M.meta_rows(state.functions, state.settings.group, order)
  if M.rows_text(rows) ~= M.rows_text(state.form_applied or {}) and mirror(rows) then save_form(rows) end
end

local function tick()
  timer:after(TICK_S, tick)
  local ok, err = pcall(function()
    state.rule:prune(now())
    evaluate()
    pub(base() .. "/value", state.rule.value_now or 0, state.rule.window_now and "in window" or "outside window", false)
  end)
  if not ok then log.e("tick: %s", tostring(err)) end
end

local function start_sync()
  local ok, err = pcall(sync)
  if not ok then log.e("could not apply the form: %s", tostring(err)) state.synced = true end
  local ok2, n = pcall(refresh)
  if ok2 then log.i("%s watches %d functions", state.settings.name, n) end
  pcall(ensure_alarm_function)
  if state.rule.since == nil then state.rule.since = now() save_state() end
end

function onStart()
  state.settings = M.settings(cfg)
  state.rule = M.rule(state.settings)
  bind(state_topic(), on_state)
  bind(form_topic(), on_form)
  bind(set_topic(), on_set)
  local ok, n = pcall(refresh)
  if not ok then log.e("could not read functions: %s", tostring(n)) n = 0 end
  local s = state.settings
  log.i("limit %s: %s, %s %s %s, group %s, %d functions", VERSION, s.name, s.measure, s.limit_kind, tostring(s.limit), s.group, n)
  timer:after(SYNC_WAIT_S, start_sync)
  timer:after(TICK_S, tick)
end

function onFunctionsUpdated()
  if not state.rule then return end
  local ok, err = pcall(refresh)
  if not ok then log.e("could not read functions: %s", tostring(err)) return end
  pcall(check_form)
end

function onDevicesUpdated() end
function onExit() end

if LIMIT_TEST then
  M._state = state
  return M
end
