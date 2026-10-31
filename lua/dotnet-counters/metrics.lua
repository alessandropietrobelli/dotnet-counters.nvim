-- Turns raw dotnet-counters events into a stable set of metrics with history.
--
-- .NET 8 publishes the runtime counters as EventCounters ("CPU Usage (%)") while .NET 9+
-- publishes them as System.Runtime meters ("dotnet.process.cpu.time (s / 1 sec)").
-- Both are mapped onto the same keys here, so the panel does not care which one it gets.
local M = {}

local MB = 1024 * 1024

--- Name without the unit suffix: "dotnet.gc.collections ({collection} / 1 sec)" -> "dotnet.gc.collections"
---@param name string
---@return string
local function base_name(name)
  return name:match("^(.-) %(") or name
end

---@param tags string
---@param key string
---@return string?
local function tag(tags, key)
  for part in (tags or ""):gmatch("[^,]+") do
    local k, v = part:match("^([^=]+)=(.*)$")
    if k == key then
      return v
    end
  end
end

-- How each counter feeds the tick: `set` overwrites, `add` sums over tag sets
-- (e.g. heap size per generation, exceptions per type).
---@type table<string, fun(tick: table, value: number, tags: string)>
local HANDLERS = {
  -- .NET 8 EventCounters
  ["CPU Usage"] = function(t, v)
    t.cpu = v
  end,
  ["Working Set"] = function(t, v)
    t.working_set = v * MB
  end,
  ["GC Heap Size"] = function(t, v)
    t.gc_heap = v * MB
  end,
  ["GC Committed Bytes"] = function(t, v)
    t.gc_committed = v * MB
  end,
  ["Allocation Rate"] = function(t, v)
    t.alloc_rate = v
  end,
  ["% Time in GC since last GC"] = function(t, v)
    t.gc_time = v
  end,
  ["Gen 0 GC Count"] = function(t, v)
    t.gen0 = v
  end,
  ["Gen 1 GC Count"] = function(t, v)
    t.gen1 = v
  end,
  ["Gen 2 GC Count"] = function(t, v)
    t.gen2 = v
  end,
  ["ThreadPool Thread Count"] = function(t, v)
    t.tp_threads = v
  end,
  ["ThreadPool Queue Length"] = function(t, v)
    t.tp_queue = v
  end,
  ["ThreadPool Completed Work Item Count"] = function(t, v)
    t.tp_items = v
  end,
  ["Exception Count"] = function(t, v)
    t.exceptions = v
  end,
  ["Monitor Lock Contention Count"] = function(t, v)
    t.contention = v
  end,

  -- .NET 9+ System.Runtime meters
  ["dotnet.process.cpu.time"] = function(t, v)
    t.cpu_time = (t.cpu_time or 0) + v
  end,
  ["dotnet.process.cpu.count"] = function(t, v)
    t.cpu_count = v
  end,
  ["dotnet.process.memory.working_set"] = function(t, v)
    t.working_set = v
  end,
  ["dotnet.gc.last_collection.heap.size"] = function(t, v)
    t.gc_heap = (t.gc_heap or 0) + v
  end,
  ["dotnet.gc.last_collection.memory.committed_size"] = function(t, v)
    t.gc_committed = v
  end,
  ["dotnet.gc.heap.total_allocated"] = function(t, v)
    t.alloc_rate = v
  end,
  ["dotnet.gc.pause.time"] = function(t, v)
    t.gc_time = v * 100
  end,
  ["dotnet.gc.collections"] = function(t, v, tags)
    local gen = tag(tags, "gc.heap.generation")
    if gen == "gen0" or gen == "gen1" or gen == "gen2" then
      t[gen] = (t[gen] or 0) + v
    end
  end,
  ["dotnet.thread_pool.work_item.count"] = function(t, v)
    t.tp_items = v
  end,
  ["dotnet.exceptions"] = function(t, v, tags)
    t.exceptions = (t.exceptions or 0) + v
    local kind = tag(tags, "error.type")
    if kind and v > 0 then
      t.exception_types = t.exception_types or {}
      t.exception_types[kind] = (t.exception_types[kind] or 0) + v
    end
  end,
  ["dotnet.monitor.lock_contentions"] = function(t, v)
    t.contention = v
  end,

  -- ASP.NET Core (meters on both .NET 8 and 9+)
  ["http.server.active_requests"] = function(t, v)
    t.http_active = (t.http_active or 0) + v
  end,
  ["http.server.request.duration"] = function(t, v, tags)
    if tag(tags, "Percentile") ~= "95" then
      return
    end
    local route = ("%s %s"):format(tag(tags, "http.request.method") or "", tag(tags, "http.route") or "?")
    local status = tag(tags, "http.response.status_code") or ""
    t.routes = t.routes or {}
    table.insert(t.routes, { route = vim.trim(route), status = status, p95 = v })
    t.http_p95 = math.max(t.http_p95 or 0, v)
  end,
}

-- Metrics that get a graph, with the history kept per key
M.GRAPHED = { "cpu", "working_set", "gc_heap", "alloc_rate", "gc_time", "http_active", "http_p95" }

-- Counters that are per-tick rates and are also summed into totals
local TOTALS = { "gen0", "gen1", "gen2", "exceptions" }

---@class DotnetCountersState
---@field current table<string, any> latest value of every metric
---@field history table<string, number[]> graphed metrics, oldest first
---@field totals table<string, number> rate counters summed since attach
---@field exception_types table<string, integer>
---@field routes table[] slowest routes of the last tick
---@field peak table<string, number>
---@field samples integer
---@field max_history integer
---@field private tick table?
---@field private seen table<string, true> counters already in the tick being filled
local State = {}
State.__index = State

---@param max_history integer
---@return DotnetCountersState
function M.new(max_history)
  local self = setmetatable({ max_history = max_history or 120 }, State)
  self:reset()
  return self
end

function State:reset()
  self.current = {}
  self.history = {}
  for _, key in ipairs(M.GRAPHED) do
    self.history[key] = {}
  end
  self.totals = {}
  self.exception_types = {}
  self.routes = {}
  self.peak = {}
  self.samples = 0
  self.tick = nil
  self.seen = {}
end

--- Close the tick being filled and fold it into current values, history and totals.
function State:commit()
  local t = self.tick
  self.tick = nil
  self.seen = {}
  if not t then
    return
  end

  -- .NET 9+ reports CPU as seconds of CPU per second: normalise to % of the whole machine,
  -- which is what the .NET 8 "CPU Usage (%)" counter already is.
  if t.cpu_time then
    local cores = t.cpu_count or self.current.cpu_count or 1
    t.cpu = t.cpu_time / math.max(cores, 1) * 100
  end

  for key, value in pairs(t) do
    if key ~= "routes" and key ~= "exception_types" then
      self.current[key] = value
    end
  end

  for _, key in ipairs(TOTALS) do
    if t[key] then
      self.totals[key] = (self.totals[key] or 0) + t[key]
    end
  end
  for kind, count in pairs(t.exception_types or {}) do
    self.exception_types[kind] = (self.exception_types[kind] or 0) + count
  end
  if t.routes then
    table.sort(t.routes, function(a, b)
      return a.p95 > b.p95
    end)
    self.routes = t.routes
  end

  for _, key in ipairs(M.GRAPHED) do
    local value = t[key]
    if value == nil and self.current[key] ~= nil then
      -- No requests in flight is reported by omission once the app is idle
      value = (key == "http_active" or key == "http_p95") and 0 or self.current[key]
    end
    if value ~= nil then
      local h = self.history[key]
      table.insert(h, value)
      if #h > self.max_history then
        table.remove(h, 1)
      end
      self.peak[key] = math.max(self.peak[key] or 0, value)
    end
  end
  self.samples = self.samples + 1
end

--- Add parsed events; returns true when at least one tick was completed.
---
--- Every counter is reported once per tick, but timestamps are not a reliable boundary:
--- .NET 8 EventCounters drift, so one counter of the next tick can arrive just before the
--- rest of the current one. A tick is therefore closed when a counter shows up again.
---@param events DotnetCountersEvent[]
---@return boolean
function State:add(events)
  local committed = false
  for _, event in ipairs(events) do
    local handler = HANDLERS[base_name(event.name)]
    if handler then
      local id = event.name .. "\0" .. (event.tags or "")
      if self.seen[id] then
        self:commit()
        committed = true
      end
      self.seen[id] = true
      self.tick = self.tick or {}
      handler(self.tick, event.value, event.tags)
    end
  end
  return committed
end

return M
