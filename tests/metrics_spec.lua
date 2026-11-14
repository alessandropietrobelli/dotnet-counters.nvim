local metrics = require("dotnet-counters.metrics")
local parser = require("dotnet-counters.parser")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local MB = 1024 * 1024

local function events(name)
  local text = table.concat(vim.fn.readfile(root .. "/fixtures/" .. name), "\n")
  return parser.new():feed(text)
end

local function load(name)
  local state = metrics.new(100)
  state:add(events(name))
  state:commit()
  return state
end

--- Sum of a counter over the whole fixture, optionally filtered by a tag substring.
local function sum(evs, prefix, tag)
  local total = 0
  for _, e in ipairs(evs) do
    if vim.startswith(e.name, prefix) and (not tag or e.tags:find(tag, 1, true)) then
      total = total + e.value
    end
  end
  return total
end

local function last(evs, prefix)
  local value
  for _, e in ipairs(evs) do
    if vim.startswith(e.name, prefix) then
      value = e.value
    end
  end
  return value
end

local function count(evs, prefix)
  local n = 0
  for _, e in ipairs(evs) do
    if vim.startswith(e.name, prefix) then
      n = n + 1
    end
  end
  return n
end

local function near(expected, actual)
  assert.is_true(math.abs(expected - actual) < 1e-6, ("expected %s, got %s"):format(expected, actual))
end

describe("metrics on .NET 9+ meters", function()
  local evs = events("net10.json")
  local state = load("net10.json")

  it("makes one sample per refresh tick", function()
    assert.equals(count(evs, "dotnet.process.memory.working_set"), state.samples)
    assert.equals(state.samples, #state.history.working_set)
  end)

  it("keeps the latest working set", function()
    near(last(evs, "dotnet.process.memory.working_set"), state.current.working_set)
  end)

  it("normalises CPU time to a percentage of the machine", function()
    assert.is_true(state.current.cpu >= 0 and state.current.cpu <= 100)
    local cores = last(evs, "dotnet.process.cpu.count")
    local user, system
    for _, e in ipairs(evs) do
      if vim.startswith(e.name, "dotnet.process.cpu.time") then
        if e.tags:find("user", 1, true) then
          user = e.value
        else
          system = e.value
        end
      end
    end
    near((user + system) / cores * 100, state.current.cpu)
  end)

  it("adds up the heap of every generation", function()
    local per_gen = {}
    for _, e in ipairs(evs) do
      if vim.startswith(e.name, "dotnet.gc.last_collection.heap.size") then
        per_gen[e.tags] = e.value
      end
    end
    local total = 0
    for _, v in pairs(per_gen) do
      total = total + v
    end
    near(total, state.current.gc_heap)
  end)

  it("totals GC collections per generation", function()
    for _, gen in ipairs({ "gen0", "gen1", "gen2" }) do
      near(sum(evs, "dotnet.gc.collections", "=" .. gen), state.totals[gen])
    end
  end)

  it("totals exceptions by type", function()
    local all = sum(evs, "dotnet.exceptions")
    near(all, state.totals.exceptions)
    local by_type = 0
    for _, n in pairs(state.exception_types) do
      by_type = by_type + n
    end
    near(all, by_type)
  end)

  it("reports GC pause time as a percentage", function()
    near(last(evs, "dotnet.gc.pause.time") * 100, state.current.gc_time)
  end)
end)

describe("metrics on .NET 8 EventCounters", function()
  local evs = events("net8.json")
  local state = load("net8.json")

  it("makes one sample per refresh tick even though CPU drifts across ticks", function()
    -- CPU Usage is reported twice in the first tick, so it is not a reliable tick marker
    local ticks = count(evs, "Working Set")
    assert.is_true(state.samples == ticks or state.samples == ticks + 1)
  end)

  it("converts MB counters to bytes", function()
    near(last(evs, "Working Set") * MB, state.current.working_set)
    near(last(evs, "GC Heap Size") * MB, state.current.gc_heap)
  end)

  it("uses the CPU percentage as is", function()
    near(last(evs, "CPU Usage"), state.current.cpu)
  end)

  it("totals GC collections", function()
    near(sum(evs, "Gen 0 GC Count"), state.totals.gen0)
    near(sum(evs, "Gen 2 GC Count"), state.totals.gen2)
  end)

  it("reports thread pool gauges", function()
    near(last(evs, "ThreadPool Thread Count"), state.current.tp_threads)
    near(last(evs, "ThreadPool Queue Length"), state.current.tp_queue)
  end)
end)

describe("metrics on ASP.NET Core", function()
  local state = load("aspnet8.json")

  it("lists routes with their status, slowest first", function()
    assert.is_true(#state.routes >= 2)
    local seen = {}
    for i, r in ipairs(state.routes) do
      seen[r.route .. " " .. r.status] = true
      if i > 1 then
        assert.is_true(state.routes[i - 1].p95 >= r.p95)
      end
    end
    assert.is_true(seen["GET / 200"])
    assert.is_true(seen["GET /fail 500"])
  end)

  it("tracks the slowest p95 and requests in flight", function()
    near(state.routes[1].p95, state.current.http_p95)
    assert.is_not_nil(state.current.http_active)
    assert.equals(state.samples, #state.history.http_p95)
  end)
end)

describe("metrics state", function()
  it("caps the history", function()
    local state = metrics.new(3)
    for i = 1, 5 do
      state:add({ { name = "Working Set (MB)", tags = "", value = i, timestamp = "" } })
      state:commit()
    end
    assert.same({ 3 * MB, 4 * MB, 5 * MB }, state.history.working_set)
    assert.equals(5 * MB, state.peak.working_set)
  end)

  it("starts a new tick when a counter repeats", function()
    local state = metrics.new(10)
    local committed = state:add({
      { name = "Working Set (MB)", tags = "", value = 1, timestamp = "" },
      { name = "CPU Usage (%)", tags = "", value = 5, timestamp = "" },
      { name = "Working Set (MB)", tags = "", value = 2, timestamp = "" },
    })
    assert.is_true(committed)
    assert.equals(1, state.samples)
    assert.equals(1 * MB, state.current.working_set)
  end)

  it("forgets everything on reset", function()
    local state = load("net10.json")
    state:reset()
    assert.equals(0, state.samples)
    assert.same({}, state.current)
    assert.same({}, state.history.cpu)
  end)
end)

describe("custom meters", function()
  local evs = events("custom10.json")
  local state = load("custom10.json")

  local function entry(name, tags)
    for _, c in ipairs(state.custom) do
      if c.name == name and c.tags == (tags or "") then
        return c
      end
    end
  end

  it("reads the unit from the name", function()
    assert.same(
      { base = "orders.processed", unit = "{order}", rate = true },
      metrics.unit("orders.processed ({order} / 1 sec)")
    )
    assert.same({ base = "orders.duration", unit = "s", rate = false }, metrics.unit("orders.duration (s)"))
    assert.same({ base = "Request Rate", unit = "Count", rate = true }, metrics.unit("Request Rate (Count / 1 sec)"))
    assert.same({ base = "plain", rate = false }, metrics.unit("plain"))
  end)

  it("keeps one entry per instrument and tag set, from other providers only", function()
    for _, c in ipairs(state.custom) do
      assert.equals("MyCompany.Orders", c.provider)
    end
    local processed = entry("orders.processed", "region=eu")
    assert.equals("{order}", processed.unit)
    assert.is_true(processed.rate)
    assert.equals(state.samples, #processed.history)
    assert.equals(
      last(
        vim.tbl_filter(function(e)
          return e.tags == "region=eu"
        end, evs),
        "orders.processed"
      ),
      processed.value
    )
    assert.is_false(entry("orders.queue.length").rate)
    assert.equals(9, #state.custom)
    assert.equals(6, #vim.tbl_filter(function(c)
      return c.tags ~= ""
    end, state.custom))
  end)

  it("keeps the 95th percentile of a histogram", function()
    local duration = entry("orders.duration", "region=us")
    assert.equals("95", duration.percentile)
    assert.equals(
      last(
        vim.tbl_filter(function(e)
          return e.tags == "region=us,Percentile=95"
        end, evs),
        "orders.duration"
      ),
      duration.value
    )
  end)

  it("counts the tag sets over the limit instead of keeping them", function()
    local limited = metrics.new(100, { max_tag_sets = 2 })
    limited:add(evs)
    limited:commit()
    assert.equals(1, limited.custom_dropped["MyCompany.Orders\0orders.processed"])
    assert.equals(1, limited.custom_dropped["MyCompany.Orders\0orders.duration"])
    assert.equals(7, #limited.custom)
  end)

  it("puts a rate to zero when a tick misses it, and keeps a value", function()
    local s = metrics.new(10)
    local function tick(list)
      s:add(list)
      s:commit()
    end
    local function ev(name, value)
      return { provider = "App", name = name, tags = "", value = value }
    end
    tick({ ev("jobs (s / 1 sec)", 3), ev("queue ({job})", 7) })
    tick({})
    tick({ ev("other", 1) })
    assert.same({ 3, 0 }, s.custom[1].history)
    assert.same({ 7, 7 }, s.custom[2].history)
  end)
end)
