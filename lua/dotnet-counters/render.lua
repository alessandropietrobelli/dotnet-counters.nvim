-- Builds the panel content (lines + highlights) from a metrics state. Pure: no window access.
local M = {}

local BLOCKS = { " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

---@param n number
---@return string
function M.bytes(n)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i = 1
  while n >= 1024 and i < #units do
    n = n / 1024
    i = i + 1
  end
  if i == 1 then
    return ("%d B"):format(n)
  end
  return (n < 100 and "%.1f %s" or "%.0f %s"):format(n, units[i])
end

---@param n number
---@return string
function M.percent(n)
  return ("%.1f%%"):format(n)
end

---@param seconds number
---@return string
function M.duration(seconds)
  local ms = seconds * 1000
  if ms < 1 then
    return ("%.0f µs"):format(ms * 1000)
  elseif ms < 1000 then
    return ("%.0f ms"):format(ms)
  end
  return ("%.2f s"):format(seconds)
end

---@param n number
---@return string
function M.count(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

--- Rows of a block graph, top row first. Each column is one sample, newest on the right.
---@param values number[]
---@param width integer
---@param height integer
---@param floor number minimum top of the scale, so idle metrics do not look maxed out
---@return string[] rows, number[] levels per column (0..1), (number|false)[] sample per column (false = padding)
function M.graph(values, width, height, floor)
  local n = math.min(#values, width)
  local slice = {}
  for i = #values - n + 1, #values do
    table.insert(slice, values[i])
  end
  local top = floor or 0
  for _, v in ipairs(slice) do
    top = math.max(top, v)
  end

  local levels = {}
  local columns = {}
  local samples = {}
  -- Left-pad so the newest sample is always in the last column
  for _ = 1, width - n do
    table.insert(levels, 0)
    table.insert(columns, 0)
    table.insert(samples, false)
  end
  for _, v in ipairs(slice) do
    local level = top > 0 and math.max(v, 0) / top or 0
    table.insert(levels, level)
    table.insert(samples, v)
    -- Anything above zero gets at least the lowest block, so activity is never invisible
    local eighths = math.floor(level * height * 8 + 0.5)
    if v > 0 and eighths == 0 then
      eighths = 1
    end
    table.insert(columns, eighths)
  end

  local rows = {}
  for row = height, 1, -1 do
    local chars = {}
    for _, eighths in ipairs(columns) do
      local fill = math.min(math.max(eighths - (row - 1) * 8, 0), 8)
      table.insert(chars, BLOCKS[fill + 1])
    end
    table.insert(rows, table.concat(chars))
  end
  return rows, levels, samples
end

--- Highlight group for a value against {warn, critical} thresholds in the metric's own unit.
---@param value number|false
---@param thresholds {[1]: number, [2]: number}?
---@return string
function M.severity(value, thresholds)
  if not value or not thresholds then
    return "DotnetCountersLow"
  end
  if value >= thresholds[2] then
    return "DotnetCountersHigh"
  elseif value >= thresholds[1] then
    return "DotnetCountersMid"
  end
  return "DotnetCountersLow"
end

---@class DotnetCountersLine
---@field text string
---@field hl {[1]: integer, [2]: integer, [3]: string}[] byte ranges (0-based, end exclusive) and groups

---@class DotnetCountersBuilder
---@field lines DotnetCountersLine[]
local Builder = {}
Builder.__index = Builder

--- Append a line made of {text, hl_group?} chunks.
---@param chunks {[1]: string, [2]: string?}[]
function Builder:add(chunks)
  local text, hl = "", {}
  for _, chunk in ipairs(chunks) do
    if chunk[2] then
      table.insert(hl, { #text, #text + #chunk[1], chunk[2] })
    end
    text = text .. chunk[1]
  end
  table.insert(self.lines, { text = text, hl = hl })
end

---@param label string
---@param value string
---@param extra string?
---@param width integer
function Builder:metric(label, value, extra, width)
  local right = extra and ("  " .. extra) or ""
  local pad = math.max(width - vim.fn.strdisplaywidth(label) - vim.fn.strdisplaywidth(value) - #right, 1)
  self:add({
    { label, "DotnetCountersLabel" },
    { string.rep(" ", pad) },
    { value, "DotnetCountersValue" },
    { right, "DotnetCountersMuted" },
  })
end

--- The height of a graph is relative to its visible maximum, so the shape is always readable;
--- the colour comes from absolute thresholds, so a steady 300 MB does not turn red just for
--- being at its own top.
---@param values number[]
---@param opts {width: integer, height: integer, floor: number?, thresholds: {[1]: number, [2]: number}?}
function Builder:graph(values, opts)
  local rows, _, samples = M.graph(values, opts.width, opts.height, opts.floor)
  for _, row in ipairs(rows) do
    local hl, col, i = {}, 0, 0
    for char in row:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      i = i + 1
      local group = M.severity(samples[i], opts.thresholds)
      table.insert(hl, { col, col + #char, group })
      col = col + #char
    end
    table.insert(self.lines, { text = row, hl = hl })
  end
end

function Builder:blank()
  table.insert(self.lines, { text = "", hl = {} })
end

---@param title string
---@param width integer
function Builder:section(title, width)
  local rule = string.rep("─", math.max(width - vim.fn.strdisplaywidth(title) - 1, 0))
  self:add({ { title .. " ", "DotnetCountersSection" }, { rule, "DotnetCountersMuted" } })
end

---@class DotnetCountersView
---@field name string?
---@field pid integer?
---@field status "starting"|"running"|"paused"|"stopped"|"error"
---@field message string?

--- Build the whole panel.
---@param state DotnetCountersState
---@param view DotnetCountersView
---@param opts {width: integer, graph_height: integer, thresholds: table?, total_memory: number?}
---@return DotnetCountersLine[]
function M.build(state, view, opts)
  local b = setmetatable({ lines = {} }, Builder)
  local width = math.max(opts.width - 2, 20)
  local cur, h = state.current, state.history
  local th = opts.thresholds or {}
  -- Memory thresholds are fractions of the machine's RAM
  local ram = opts.total_memory or (vim.uv or vim.loop).get_total_memory()
  local memory = th.memory and { th.memory[1] * ram, th.memory[2] * ram }

  ---@param floor number?
  ---@param thresholds {[1]: number, [2]: number}?
  local function g(floor, thresholds)
    return { width = width, height = opts.graph_height, floor = floor, thresholds = thresholds }
  end

  local status_hl = {
    running = "DotnetCountersRunning",
    paused = "DotnetCountersPaused",
    starting = "DotnetCountersMuted",
    stopped = "DotnetCountersMuted",
    error = "DotnetCountersHigh",
  }
  local status_icon = { running = "● ", paused = "⏸ ", starting = "◌ ", stopped = "■ ", error = "✗ " }
  b:add({ { "󰪚 .NET runtime", "DotnetCountersTitle" } })
  b:add({
    { status_icon[view.status] .. view.status, status_hl[view.status] },
    { view.pid and ("  %s · pid %d"):format(view.name or "process", view.pid) or "", "DotnetCountersMuted" },
  })
  if view.message then
    b:add({ { view.message, "DotnetCountersMuted" } })
  end
  b:blank()

  if state.samples == 0 then
    b:add({ { view.status == "starting" and "Waiting for the first samples…" or "No data", "DotnetCountersMuted" } })
    return b.lines
  end

  if cur.cpu then
    b:metric("CPU", M.percent(cur.cpu), "peak " .. M.percent(state.peak.cpu or 0), width)
    b:graph(h.cpu, g(10, th.cpu))
  end
  if cur.working_set then
    b:metric("Working set", M.bytes(cur.working_set), "peak " .. M.bytes(state.peak.working_set or 0), width)
    b:graph(h.working_set, g(nil, memory))
  end
  if cur.gc_heap then
    b:metric("GC heap", M.bytes(cur.gc_heap), cur.gc_committed and ("committed " .. M.bytes(cur.gc_committed)), width)
    b:graph(h.gc_heap, g(nil, memory))
  end
  if cur.alloc_rate then
    b:metric("Allocations", M.bytes(cur.alloc_rate) .. "/s", nil, width)
    b:graph(h.alloc_rate, g(nil, th.alloc_rate))
  end
  if cur.gc_time then
    b:metric("Time in GC", M.percent(cur.gc_time), nil, width)
    b:graph(h.gc_time, g(5, th.gc_time))
  end

  b:blank()
  b:section("GC", width)
  local t = state.totals
  for _, gen in ipairs({ "gen0", "gen1", "gen2" }) do
    b:metric("Collections " .. gen, M.count(t[gen] or 0), M.count(cur[gen] or 0) .. "/s", width)
  end

  b:section("Threads", width)
  if cur.tp_threads then
    b:metric("Pool threads", M.count(cur.tp_threads), nil, width)
  end
  if cur.tp_queue then
    b:metric("Pool queue", M.count(cur.tp_queue), nil, width)
  end
  if cur.tp_items then
    b:metric("Work items", M.count(cur.tp_items) .. "/s", nil, width)
  end
  if cur.contention then
    b:metric("Lock contention", M.count(cur.contention) .. "/s", nil, width)
  end

  b:section("Exceptions", width)
  b:metric("Thrown", M.count(cur.exceptions or 0) .. "/s", M.count(t.exceptions or 0) .. " total", width)
  local kinds = vim.tbl_keys(state.exception_types)
  table.sort(kinds, function(a, b2)
    return state.exception_types[a] > state.exception_types[b2]
  end)
  for i = 1, math.min(#kinds, 5) do
    local kind = kinds[i]
    local short = kind:match("([^.]+)$") or kind
    b:metric("  " .. short, "×" .. M.count(state.exception_types[kind]), nil, width)
  end

  if cur.http_active ~= nil or #state.routes > 0 then
    b:blank()
    b:section("HTTP", width)
    b:metric("In flight", M.count(cur.http_active or 0), nil, width)
    b:graph(h.http_active, g(1, th.http_active))
    if cur.http_p95 then
      b:metric("p95 (slowest route)", M.duration(cur.http_p95), nil, width)
      b:graph(h.http_p95, g(nil, th.http_p95))
    end
    for i = 1, math.min(#state.routes, 6) do
      local r = state.routes[i]
      local status_group = r.status:match("^5") and "DotnetCountersHigh"
        or r.status:match("^4") and "DotnetCountersMid"
        or "DotnetCountersMuted"
      local label = r.route
      local value = M.duration(r.p95)
      local room = width - vim.fn.strdisplaywidth(value) - #r.status - 4
      if vim.fn.strdisplaywidth(label) > room then
        label = vim.fn.strcharpart(label, 0, room - 1) .. "…"
      end
      local pad = math.max(width - vim.fn.strdisplaywidth(label) - #r.status - vim.fn.strdisplaywidth(value) - 2, 1)
      b:add({
        { label, "DotnetCountersLabel" },
        { " " },
        { r.status, status_group },
        { string.rep(" ", pad + 1) },
        { value, "DotnetCountersValue" },
      })
    end
  end

  return b.lines
end

return M
