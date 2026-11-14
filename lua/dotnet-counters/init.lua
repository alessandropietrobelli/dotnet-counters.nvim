local collector = require("dotnet-counters.collector")
local metrics = require("dotnet-counters.metrics")
local panel = require("dotnet-counters.panel")

local M = {}

---@class DotnetCountersConfig
M.default_config = {
  -- dotnet-counters executable; nil looks in PATH and then ~/.dotnet/tools
  cmd = nil,
  -- Providers passed to `dotnet-counters collect --counters`
  counters = "System.Runtime,Microsoft.AspNetCore.Hosting",
  -- Seconds between samples
  refresh_interval = 1,
  -- Restart the collector when its output file grows past this many bytes
  max_file_size = 32 * 1024 * 1024,
  -- Samples kept for the graphs
  history = 200,
  -- Counters of providers other than System.Runtime and Microsoft.AspNetCore.Hosting (your own
  -- meters, added to `counters`) go to the Custom section, one line per tag set with a sparkline
  custom = {
    -- Tag sets shown per instrument, the first ones seen; the others are counted in a
    -- "+N more" line
    max_tag_sets = 5,
    -- Instruments that get a full graph instead of a line, e.g. { "orders.processed" }
    graphs = {},
  },
  dap = {
    -- Attach and open the panel when a debug session of one of these adapters starts a process
    enabled = true,
    adapters = { "coreclr", "netcoredbg" },
    -- When a debug session ends, take its process off the panel, and close the panel once none
    -- is still collected (those stopped go too); false keeps it there, stopped, with its last data
    close_on_exit = true,
    -- Show the process that stops at a breakpoint, with several debugged at once
    follow = true,
  },
  window = {
    position = "right",
    width = 46,
    graph_height = 2,
  },
  -- Graph colours: {warn, critical} in each metric's unit. Below warn is green, then yellow, then
  -- red. Graph heights stay relative to the visible maximum; only the colour uses these.
  thresholds = {
    cpu = { 25, 60 }, -- % of the whole machine
    memory = { 0.10, 0.25 }, -- fraction of the machine's RAM (working set and GC heap)
    alloc_rate = { 256 * 1024 * 1024, 1024 * 1024 * 1024 }, -- bytes/s
    gc_time = { 5, 10 }, -- % of time paused by the GC
    http_active = nil, -- requests in flight: no threshold, always green
    http_p95 = { 0.2, 1 }, -- seconds
  },
}

---@type DotnetCountersConfig
M.config = vim.deepcopy(M.default_config)

local function new_state()
  return metrics.new(M.config.history, { max_tag_sets = M.config.custom.max_tag_sets })
end

---@class DotnetCountersProcess
---@field pid integer
---@field name string?
---@field state DotnetCountersState
---@field view DotnetCountersView
---@field collector DotnetCountersCollector? nil once collection stopped
---@field owner integer? the nvim-dap session debugging it
---@field by_hand boolean? attached by hand before a session debugged it: kept when that ends
---@field last_event integer uv.now() of the last event

-- Every process collected, or stopped but still on screen, in the order they were attached.
-- One `dotnet-counters collect` runs for each, as it takes a single process. The panel shows one of them, `shown`.
---@type DotnetCountersProcess[]
local processes = {}
---@type DotnetCountersProcess?
local shown
---@type uv.uv_timer_t?
local idle_timer

local uv = vim.uv or vim.loop

---@param pid integer
---@return DotnetCountersProcess?, integer?
local function find(pid)
  for i, p in ipairs(processes) do
    if p.pid == pid then
      return p, i
    end
  end
end

local function redraw()
  local state, view
  if shown then
    state = shown.state
    -- The others, listed under the header
    local others = {}
    for _, p in ipairs(processes) do
      if p ~= shown then
        table.insert(others, { pid = p.pid, name = p.name, status = p.view.status })
      end
    end
    view = vim.tbl_extend("force", shown.view, { others = others, index = nil, count = #processes })
    for i, p in ipairs(processes) do
      if p == shown then
        view.index = i
      end
    end
  else
    state, view = new_state(), { status = "stopped" }
  end
  panel.draw(state, view, {
    graph_height = M.config.window.graph_height,
    thresholds = M.config.thresholds,
    custom_graphs = M.config.custom.graphs,
  })
end

---@param p DotnetCountersProcess
local function redraw_if_shown(p)
  if p == shown then
    redraw()
  end
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "dotnet-counters" })
end

local function reset()
  if shown then
    shown.state:reset()
  end
  redraw()
end

---@return string?
local function find_cmd()
  local cmd = collector.find_cmd(M.config.cmd)
  if not cmd then
    vim.notify(
      "dotnet-counters not found. Install it with `dotnet tool install -g dotnet-counters`.",
      vim.log.levels.ERROR,
      { title = "dotnet-counters" }
    )
  end
  return cmd
end

local function stop_idle_timer()
  if idle_timer then
    idle_timer:stop()
    idle_timer:close()
    idle_timer = nil
  end
end

-- A tick is only committed when the next one starts. When a process is paused the next one
-- never comes, so commit after a quiet period to show the last sample anyway.
local function start_idle_timer()
  if idle_timer then
    return
  end
  idle_timer = uv.new_timer()
  idle_timer:start(
    500,
    500,
    vim.schedule_wrap(function()
      local collecting = false
      for _, p in ipairs(processes) do
        if p.collector then
          collecting = true
          if uv.now() - p.last_event > (M.config.refresh_interval * 1000 * 1.5) then
            p.state:commit()
            redraw_if_shown(p)
          end
        end
      end
      if not collecting then
        stop_idle_timer()
      end
    end)
  )
end

--- Stop collecting from one process; it stays listed with its last data.
---@param p DotnetCountersProcess
local function stop(p)
  if p.collector then
    p.collector:stop()
    p.collector = nil
  end
  if p.view.status ~= "error" then
    p.view.status = "stopped"
  end
end

--- Take a process off the list, showing another one if it was shown: the first one still
--- collecting, else the last one attached.
---@param p DotnetCountersProcess
local function remove(p)
  stop(p)
  local _, i = find(p.pid)
  if i then
    table.remove(processes, i)
  end
  if shown == p then
    shown = nil
    for _, other in ipairs(processes) do
      if other.collector then
        shown = other
        break
      end
    end
    shown = shown or processes[#processes]
  end
end

---@return boolean
local function any_collecting()
  for _, p in ipairs(processes) do
    if p.collector then
      return true
    end
  end
  return false
end

--- Stop collecting from the process shown. The panel stays open with its last data unless
--- `close` is true.
---@param close boolean?
function M.detach(close)
  if not (shown and shown.collector) then
    notify(any_collecting() and "The process shown is not collected" or "No .NET process is collected")
  else
    stop(shown)
  end
  if close then
    panel.close()
  else
    redraw()
  end
end

--- Stop collecting from every process.
---@param close boolean?
function M.detach_all(close)
  for _, p in ipairs(processes) do
    stop(p)
  end
  stop_idle_timer()
  if close then
    panel.close()
  else
    redraw()
  end
end

--- Show the next (or, with a negative step, the previous) process in the panel.
---@param step integer?
function M.next(step)
  local _, i = find(shown and shown.pid or -1)
  if not i or #processes < 2 then
    notify(#processes == 0 and "No .NET process is collected" or "Only one .NET process is collected")
    return
  end
  shown = processes[((i - 1 + (step or 1)) % #processes) + 1]
  redraw()
end

--- Show the process `pid` in the panel, if it is listed.
---@param pid integer
---@return boolean shown false when `pid` is not listed
function M.show(pid)
  local p = find(pid)
  if not p then
    notify(("pid %d is not collected"):format(pid), vim.log.levels.WARN)
    return false
  end
  shown = p
  redraw()
  return true
end

--- The processes listed, in the order they were attached.
---@return {pid: integer, name: string?, status: string, shown: boolean}[]
function M.processes()
  return vim.tbl_map(function(p)
    return { pid = p.pid, name = p.name, status = p.view.status, shown = p == shown }
  end, processes)
end

---@param p DotnetCountersProcess
---@param err string
local function failed(p, err)
  p.view.status = "error"
  p.view.message = err
  notify(("%s (pid %d): %s"):format(p.name or "process", p.pid, err), vim.log.levels.WARN)
end

---@param pid integer
---@param name string?
---@param owner integer? the nvim-dap session debugging it
---@return DotnetCountersProcess?
local function attach(pid, name, owner)
  local existing = find(pid)
  if existing and existing.collector then
    if owner then
      existing.by_hand = existing.by_hand or existing.owner == nil
      existing.owner = owner
    end
    shown = existing
    panel.open(M.config.window, reset, M.next)
    redraw()
    return existing
  end
  local cmd = find_cmd()
  if not cmd then
    return
  end
  name = name or (existing and existing.name)
  ---@type DotnetCountersProcess
  local p = {
    pid = pid,
    name = name,
    state = new_state(),
    view = { status = "starting", pid = pid, name = name },
    -- Collected again after a detach: still the same session's process
    owner = owner or (existing and existing.owner),
    by_hand = existing and existing.by_hand,
    last_event = uv.now(),
  }

  local this
  local ok, started = pcall(collector.start, {
    cmd = cmd,
    pid = pid,
    counters = M.config.counters,
    refresh_interval = M.config.refresh_interval,
    max_file_size = M.config.max_file_size,
    on_events = function(events)
      if p.collector ~= this then
        return
      end
      p.last_event = uv.now()
      local changed = p.view.status == "starting" or p.view.status == "paused"
      if changed then
        p.view.status = "running"
      end
      -- Samples redraw only the process shown; a new status also shows in the others' header
      if p.state:add(events) and p == shown or changed then
        redraw()
      end
    end,
    on_exit = function(err)
      if p.collector ~= this then
        return
      end
      p.collector = nil
      p.state:commit()
      if err then
        failed(p, err)
      else
        p.view.status = "stopped"
      end
      redraw()
    end,
  })

  -- Those that stopped leave the list, once this one has started (and its own old entry anyway)
  for i = #processes, 1, -1 do
    if processes[i] == existing or (ok and not processes[i].collector) then
      table.remove(processes, i)
    end
  end
  table.insert(processes, p)
  shown = p
  if ok then
    this = started
    p.collector = this
    start_idle_timer()
  else
    failed(p, tostring(started))
  end
  panel.open(M.config.window, reset, M.next)
  redraw()
  return p
end

--- Start collecting from a process, next to those already collected, and show it. A process
--- already collected is just shown; once it starts, processes that stopped leave the list.
---@param pid integer
---@param name string?
---@return DotnetCountersProcess?
function M.attach(pid, name)
  return attach(pid, name)
end

function M.open()
  panel.open(M.config.window, reset, M.next)
  redraw()
end

function M.close()
  panel.close()
end

function M.toggle()
  if panel.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.reset()
  reset()
end

--- Pick a running .NET process (from `dotnet-counters ps`) and attach to it.
function M.pick()
  local cmd = find_cmd()
  if not cmd then
    return
  end
  vim.system({ cmd, "ps" }, { text = true }, function(result)
    vim.schedule(function()
      local items = {}
      for line in (result.stdout or ""):gmatch("[^\n]+") do
        local pid, pname, path = line:match("^%s*(%d+)%s+(%S+)%s*(.*)$")
        if pid then
          table.insert(items, { pid = tonumber(pid), name = pname, path = vim.trim(path) })
        end
      end
      if #items == 0 then
        notify("No .NET processes found")
        return
      end
      vim.ui.select(items, {
        prompt = "Attach .NET counters to",
        format_item = function(item)
          local collected = find(item.pid)
          local mark = collected and collected.collector and "  (collected)" or ""
          return ("%d  %s  %s%s"):format(item.pid, item.name, item.path, mark)
        end,
      }, function(item)
        if item then
          M.attach(item.pid, item.name)
        end
      end)
    end)
  end)
end

local dap_hooked = false

--- Hook into nvim-dap: each .NET debuggee is collected from when it starts, shows paused at a
--- breakpoint, and stops being collected when its session ends.
function M.hook_dap()
  local ok, dap = pcall(require, "dap")
  if not ok or dap_hooked then
    return
  end
  dap_hooked = true
  local key = "dotnet-counters"

  local function ours(session)
    return session and session.config and vim.tbl_contains(M.config.dap.adapters, session.config.type)
  end

  -- The process a session started, if it is still listed. Only that session's events act on it:
  -- with an API and a worker debugged together, one must not pause or stop the other.
  ---@return DotnetCountersProcess?
  local function owned_by(session)
    if not ours(session) then
      return nil
    end
    for _, p in ipairs(processes) do
      if p.owner ~= nil and p.owner == session.id then
        return p
      end
    end
  end

  -- nvim-dap calls listeners unprotected: an error here would skip its own handling of the
  -- event, and drop the listener if it returned true. Report it instead, and return nothing.
  local function listen(phase, event, fn)
    dap.listeners[phase][event][key] = function(session, body)
      local done, err = xpcall(fn, debug.traceback, session, body)
      if not done then
        notify(("nvim-dap %s: %s"):format(event, err), vim.log.levels.ERROR)
      end
    end
  end

  listen("after", "event_process", function(session, body)
    if M.config.dap.enabled and ours(session) and body and body.systemProcessId then
      local name = session.config.program and vim.fn.fnamemodify(session.config.program, ":t:r") or body.name
      attach(body.systemProcessId, name, session.id)
    end
  end)
  listen("after", "event_stopped", function(session)
    local p = owned_by(session)
    if p and p.collector then
      p.view.status = "paused"
      p.state:commit()
      -- The process you are stepping through is the one to look at
      if M.config.dap.follow then
        shown = p
      end
      -- Also when not shown: the header lists its status
      redraw()
    end
  end)
  listen("after", "event_continued", function(session)
    local p = owned_by(session)
    if p and p.collector and p.view.status == "paused" then
      p.view.status = "running"
      redraw()
    end
  end)
  local function finished(session)
    local p = owned_by(session)
    if not p then
      return
    end
    p.owner = nil
    if p.by_hand then
      -- Attached by hand before the session: collected as before, now that nothing pauses it
      p.by_hand = nil
      if p.view.status == "paused" then
        p.view.status = "running"
      end
    elseif M.config.dap.close_on_exit then
      remove(p)
      if not any_collecting() then
        processes, shown = {}, nil
        stop_idle_timer()
        panel.close()
        return
      end
    else
      stop(p)
    end
    redraw()
  end
  listen("before", "event_terminated", finished)
  listen("before", "event_exited", finished)
  listen("before", "disconnect", finished)
end

---@param opts DotnetCountersConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.default_config), opts or {})
  local custom = M.config.custom
  local ok, err = pcall(vim.validate, {
    ["custom.max_tag_sets"] = {
      custom.max_tag_sets,
      function(n)
        return type(n) == "number" and n >= 1 and n == math.floor(n)
      end,
      "an integer of at least 1",
    },
    ["custom.graphs"] = { custom.graphs, "table" },
  })
  if not ok then
    vim.notify(
      ("dotnet-counters: %s; using the default"):format(err),
      vim.log.levels.WARN,
      { title = "dotnet-counters" }
    )
    if type(custom.graphs) ~= "table" then
      custom.graphs = {}
    end
    if not (type(custom.max_tag_sets) == "number" and custom.max_tag_sets >= 1) then
      custom.max_tag_sets = M.default_config.custom.max_tag_sets
    end
  end
  -- A collector left running keeps the process's EventPipe session, and the next attach to it
  -- fails with "concurrent sessions"
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("dotnet-counters", { clear = true }),
    callback = function()
      for _, p in ipairs(processes) do
        if p.collector then
          p.collector:stop(true)
          p.collector = nil
        end
      end
    end,
  })
  if package.loaded["dap"] then
    M.hook_dap()
  else
    -- nvim-dap is usually lazy-loaded: hook in as soon as it is
    vim.api.nvim_create_autocmd("SourcePost", {
      pattern = "*/nvim-dap/plugin/dap.lua",
      once = true,
      callback = function()
        vim.schedule(M.hook_dap)
      end,
    })
  end
end

return M
