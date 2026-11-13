-- Tests for app.lua without an edge client: run with `lua5.3 tests/test_app.lua` from the repository root.
-- The edge client and the clock are simulated. All names, addresses and numbers are made up.

local failures, count = 0, 0
local function check(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then print("ok   " .. name) else failures = failures + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, what)
  if a ~= b then error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2) end
end

local S = dofile("tests/sim.lua")
local T0, fn, load_app = S.T0, S.fn, S.load_app
local H = 3600
local ALARM = "obj/limit/test/alarm"

local function rule(extra, functions)
  local c = { name = "Test", group = "test", watch = {} }
  for k, v in pairs(extra or {}) do c[k] = v end
  local fns = functions or { fn(101, "obj/a", "Givare A", { ["limit.group"] = "test" }) }
  local M, env, sim = load_app({ cfg = c, functions = fns })
  env.onStart()
  sim.advance(5)
  return M, env, sim
end

-- ---- time ----------------------------------------------------------------------------------------------------------

check("local time in Stockholm with summer time, without a time zone database", function()
  local M = load_app({})
  eq(M.offset(T0, "Europe/Stockholm"), 3600, "November")
  eq(M.offset(1782864000, "Europe/Stockholm"), 7200, "July")
  eq(M.offset(1774746000 - 1, "Europe/Stockholm"), 3600, "just before summer time")
  eq(M.offset(1774746000, "Europe/Stockholm"), 7200, "summer time from 01:00 UTC on the last Sunday of March")
  eq(M.offset(1792890000, "Europe/Stockholm"), 3600, "winter time from the last Sunday of October")
  eq(M.offset(T0, "Europe/Helsinki"), 7200, "Helsinki")
  eq(M.offset(T0, "UTC"), 0, "UTC")
  local _, sec, wd = M.local_time(T0, "Europe/Stockholm")
  eq(sec, 9 * H + 40 * 60, "09:40")
  eq(wd, 2, "Tuesday")
  eq(M.clock("23:00"), 23 * H, "clock")
  eq(M.clock("6"), 6 * H, "hour only")
  eq(M.clock("25:00"), nil, "invalid")
end)

check("a scheduled window over midnight belongs to the day it starts", function()
  local M = load_app({})
  local sched = { from = 23 * H, to = 6 * H, days = { [2] = true } } -- Tuesday nights
  local w = M.window_at(T0 + 48000 + 2 * H, sched, "Europe/Stockholm") -- Wednesday 01:00
  assert(w, "inside")
  eq(w.start, T0 + 48000, "opened Tuesday 23:00")
  eq(w.stop - w.start, 7 * H, "seven hours")
  eq(M.window_at(T0 + 48000 + 8 * H, sched, "Europe/Stockholm"), nil, "after 06:00")
  eq(M.window_at(T0 + 48000 + 24 * H + 60, { from = 23 * H, to = 6 * H, days = { [2] = true } }, "Europe/Stockholm"), nil, "Wednesday night not chosen")
end)

-- ---- the rules -----------------------------------------------------------------------------------------------------

check("water: more than 50 l within 60 minutes raises the alarm, and it clears when the window has passed", function()
  local _, _, sim = rule({ measure = "increase", window = "rolling", window_min = 60, limit_kind = "at_most", limit = 50 })
  sim.value("obj/a", 1000)
  for _ = 1, 3 do sim.advance(10 * 60) sim.value("obj/a", 1000 + 20 * _) end
  eq(sim.last(ALARM).value, 1, "60 l in 30 min")
  assert(sim.last(ALARM).msg:find("too much", 1, true), sim.last(ALARM).msg)
  sim.advance(70 * 60)
  eq(sim.last(ALARM).value, 0, "cleared")
end)

check("a meter that starts over counts from 0", function()
  local M = load_app({})
  local r = M.rule(M.settings({ measure = "increase" }))
  r:value(1, nil, 990, T0)
  r:value(1, nil, 5, T0 + 60)
  eq(r:measure(T0, T0 + 120), 5, "from 0")
end)

check("a tank that falls more than 200 l in an hour raises the alarm and names the tank", function()
  local fns = { fn(101, "obj/a", "Tank", { ["limit.group"] = "test", ["limit.label"] = "vattentanken" }) }
  local _, _, sim = rule({ measure = "fall", window = "rolling", window_min = 60, limit_kind = "at_most", limit = 200 }, fns)
  sim.value("obj/a", 1000)
  for i = 1, 5 do sim.advance(10 * 60) sim.value("obj/a", 1000 - 45 * i) end
  eq(sim.last(ALARM).value, 1, "225 l in 50 minutes")
  assert(sim.last(ALARM).msg:find("vattentanken", 1, true), sim.last(ALARM).msg)
  sim.advance(90 * 60)
  eq(sim.last(ALARM).value, 0, "steady again")
end)

check("noise up and down does not add up; the change is now against the start of the window", function()
  local _, _, sim = rule({ measure = "fall", window = "rolling", window_min = 60, limit_kind = "at_most", limit = 1 })
  for i = 1, 60 do sim.value("obj/a", 20 + (i % 2 == 0 and 0.4 or -0.4)) sim.advance(60) end
  eq(sim.last(ALARM), nil, "a whole hour of noise of 0.8 degrees")
  sim.value("obj/a", 18)
  eq(sim.last(ALARM).value, 1, "a real fall")
end)

check("a rise counts from the value when the window began, also one reported before it", function()
  local _, _, sim = rule({ measure = "rise", window = "schedule", schedule_from = "10:00", schedule_to = "12:00", limit_kind = "at_most", limit = 5 })
  sim.value("obj/a", 20) -- 09:40 local, before the window
  sim.advance(50 * 60)   -- 10:30
  sim.value("obj/a", 24)
  eq(sim.last(ALARM), nil, "4 degrees")
  sim.advance(10 * 60)
  sim.value("obj/a", 26)
  eq(sim.last(ALARM).value, 1, "6 degrees since 10:00")
end)

check("at least a rise: a tank that is not filled up within a day", function()
  local _, _, sim = rule({ measure = "rise", window = "rolling", window_min = 1440, limit_kind = "at_least", limit = 100 })
  sim.value("obj/a", 300)
  sim.advance(12 * H) sim.value("obj/a", 250)
  sim.advance(12 * H + 60)
  eq(sim.last(ALARM).value, 1, "not filled in 24 h")
  sim.value("obj/a", 900)
  eq(sim.last(ALARM).value, 0, "filled")
end)

check("levels survive a restart", function()
  local c = { name = "Test", group = "test", measure = "fall", window = "rolling", window_min = 60, limit_kind = "at_most", limit = 3 }
  local fns = { fn(101, "obj/a", "A", { ["limit.group"] = "test" }) }
  local _, env, sim = load_app({ cfg = c, functions = fns })
  env.onStart()
  sim.value("obj/a", -1.5)
  sim.advance(600)
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, functions = fns, retained = sim.retained, clock = sim.clock + 60 })
  env2.onStart()
  sim2.value("obj/a", -5)
  eq(sim2.last(ALARM).value, 1, "3.5 degrees down across the restart")
end)

check("traffic: three cars in 10 minutes, a car counted once", function()
  local _, _, sim = rule({ measure = "count", window = "rolling", window_min = 10, limit_kind = "at_most", limit = 2, event_gap_s = 20 })
  local function car() sim.value("obj/a", 1) sim.advance(2) sim.value("obj/a", 0) sim.advance(2) sim.value("obj/a", 1) sim.advance(2) sim.value("obj/a", 0) end
  car() sim.advance(60)
  car() sim.advance(60)
  eq(sim.last(ALARM), nil, "two cars (the bounce within 20 s counted once)")
  car()
  eq(sim.last(ALARM).value, 1, "the third")
end)

check("the back yard: two different motion sensors, not one sensor twice", function()
  local fns = { fn(101, "obj/a", "Rörelse altan", { ["limit.group"] = "test" }), fn(102, "obj/b", "Rörelse förråd", { ["limit.group"] = "test" }) }
  local _, _, sim = rule({ measure = "distinct", window = "rolling", window_min = 2, limit_kind = "at_most", limit = 1 }, fns)
  sim.value("obj/a", 1) sim.advance(10) sim.value("obj/a", 0) sim.advance(10) sim.value("obj/a", 1)
  eq(sim.last(ALARM), nil, "one sensor")
  sim.advance(30)
  sim.value("obj/b", 1)
  eq(sim.last(ALARM).value, 1, "two sensors")
  assert(sim.last(ALARM).msg:find("Rörelse altan, Rörelse förråd", 1, true), sim.last(ALARM).msg)
end)

check("the fridge compressor: at least once above 30 W in two hours", function()
  local _, _, sim = rule({ measure = "count", event = "above", threshold = 30, window = "rolling", window_min = 120, limit_kind = "at_least", limit = 1 })
  sim.value("obj/a", 45) sim.advance(30 * 60) sim.value("obj/a", 2)
  sim.advance(89 * 60)
  eq(sim.last(ALARM), nil, "ran within two hours")
  sim.advance(2 * 60)
  eq(sim.last(ALARM).value, 1, "silent for two hours")
  assert(sim.last(ALARM).msg:find("too little", 1, true))
  sim.value("obj/a", 50)
  eq(sim.last(ALARM).value, 0, "running again")
end)

check("at least, rolling: no alarm before one whole window since the first start", function()
  local _, _, sim = rule({ measure = "count", window = "rolling", window_min = 60, limit_kind = "at_least", limit = 1 })
  sim.advance(59 * 60)
  eq(sim.last(ALARM), nil, "warming up")
  sim.advance(2 * 60)
  eq(sim.last(ALARM).value, 1, "after a whole window")
end)

check("night noise: more than two noises 23:00-06:00, not in the daytime", function()
  local _, _, sim = rule({ measure = "count", window = "schedule", schedule_from = "23:00", schedule_to = "06:00", limit_kind = "at_most", limit = 2 })
  for _ = 1, 3 do sim.value("obj/a", 1) sim.advance(30) sim.value("obj/a", 0) sim.advance(30) end -- 09:40 local
  eq(sim.last(ALARM), nil, "daytime")
  sim.advance(48000 - 185 + 90 * 60) -- 00:30 local
  for _ = 1, 3 do sim.value("obj/a", 1) sim.advance(30) sim.value("obj/a", 0) sim.advance(30) end
  eq(sim.last(ALARM).value, 1, "three at night")
  sim.advance(6 * H)
  eq(sim.last(ALARM).value, 0, "the window closed")
end)

check("at least, scheduled: decided when the window closes, and cleared by a sign in the next window", function()
  local _, _, sim = rule({ measure = "count", window = "schedule", schedule_from = "08:00", schedule_to = "10:00", limit_kind = "at_least", limit = 1 })
  sim.advance(H)
  eq(sim.last(ALARM), nil, "Tuesday's window was not watched from its start: not judged")
  sim.advance(80400 - 5 - H + 60) -- Wednesday 08:01 local
  eq(sim.last(ALARM), nil, "window open")
  sim.advance(2 * H)
  eq(sim.last(ALARM).value, 1, "nothing between 08 and 10")
  sim.advance(22 * H + 30 * 60) -- Thursday 08:31
  eq(sim.last(ALARM).value, 1, "stands until the next window decides")
  sim.value("obj/a", 1)
  eq(sim.last(ALARM).value, 0, "a sign in the next window")
end)

check("an acknowledged alarm stays off until the rule is kept and broken again", function()
  local _, _, sim = rule({ measure = "count", window = "rolling", window_min = 10, limit_kind = "at_most", limit = 0 })
  sim.value("obj/a", 1)
  eq(sim.last(ALARM).value, 1, "alarm")
  sim.set("set/" .. ALARM, 0, "Dashboard")
  eq(sim.last(ALARM).value, 0, "acknowledged")
  eq(sim.last(ALARM).msg, "acknowledged: Dashboard", "who")
  sim.advance(60)
  eq(sim.last(ALARM).value, 0, "stays off")
  sim.advance(10 * 60)
  sim.value("obj/a", 0) sim.value("obj/a", 1)
  eq(sim.last(ALARM).value, 1, "broken again")
end)

check("a restart goes on with the events from before", function()
  local c = { name = "Test", group = "test", measure = "count", window = "rolling", window_min = 10, limit_kind = "at_most", limit = 2 }
  local fns = { fn(101, "obj/a", "A", { ["limit.group"] = "test" }) }
  local _, env, sim = load_app({ cfg = c, functions = fns })
  env.onStart()
  sim.value("obj/a", 1) sim.value("obj/a", 0) sim.advance(10) sim.value("obj/a", 1) sim.value("obj/a", 0)
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, functions = fns, retained = sim.retained, clock = sim.clock + 60 })
  env2.onStart()
  sim2.value("obj/a", 1)
  eq(sim2.last(ALARM).value, 1, "the third, counting two from before the restart")
end)

check("at least, scheduled: a window that closed while the app was down is judged after the restart", function()
  local c = { name = "Test", group = "test", measure = "count", window = "schedule", schedule_from = "08:00", schedule_to = "10:00", limit_kind = "at_least", limit = 1 }
  local fns = { fn(101, "obj/a", "A", { ["limit.group"] = "test" }) }
  local _, env, sim = load_app({ cfg = c, functions = fns })
  env.onStart()
  sim.advance(80400 + 60) -- Wednesday 08:01
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, functions = fns, retained = sim.retained, clock = sim.clock + 3 * H })
  env2.onStart()
  sim2.advance(20)
  eq(sim2.last(ALARM).value, 1, "judged at 11:01")
end)

check("the alarm function is created once, with a topic to acknowledge", function()
  local _, env, sim = rule({})
  eq(#sim.created, 1, "created")
  local f = sim.created[1]
  eq(f.type, "alarm", "type")
  eq(f.meta.topic_read, ALARM, "read")
  eq(f.meta.topic_write, "set/" .. ALARM, "write")
  eq(f.meta.name, "Test larm", "name")
  env.onFunctionsUpdated()
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, functions = { sim.fn(101), sim.fn(f.id) }, retained = sim.retained })
  env2.onStart()
  sim2.advance(5)
  eq(#sim2.created, 0, "not again")
end)

check("the form tags the functions and is kept in step", function()
  local fns = { fn(101, "obj/a", "Vattenmätare") }
  local M, env, sim = load_app({ cfg = { name = "Vatten", group = "water", watch = { { watch_function = 101, watch_label = "vattnet" } } }, functions = fns })
  env.onStart()
  sim.advance(5)
  eq(fns[1].meta["limit.group"], "water", "group")
  eq(fns[1].meta["limit.label"], "vattnet", "label")
  assert(sim.handlers["obj/a"], "watched")
  fns[1].meta["limit.label"] = "kallvattnet"
  env.onFunctionsUpdated()
  eq(sim.instance_config.watch[1].watch_label, "kallvattnet", "back into the form")
  eq(M.settings({}).group, "limit-5", "a group of its own")
end)

check("modes: written as people see them; the rule rests in other modes", function()
  local fns = { fn(101, "obj/a", "A", { ["limit.group"] = "test" }), S.MODE }
  local _, _, sim = rule({ measure = "count", window = "rolling", window_min = 10, limit_kind = "at_most", limit = 0, active_modes = "Borta" }, fns)
  sim.value("obj/mode/default", 0)
  sim.value("obj/a", 1)
  eq(sim.last(ALARM), nil, "Hemma")
  sim.value("obj/mode/default", 1)
  sim.advance(10)
  eq(sim.last(ALARM).value, 1, "Borta")
end)

check("the code returns nothing in the edge client", function()
  local env = setmetatable({ cfg = {}, app = { id = 1 }, log = { i = print, e = print }, json = { null = {} } }, { __index = _G })
  local chunk = assert(loadfile("app.lua", "t", env))
  eq(select("#", chunk()), 0, "returned values")
end)

print(string.format("%d of %d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
