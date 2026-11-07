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
  dap = {
    -- Attach and open the panel when a debug session of one of these adapters starts a process
    enabled = true,
    adapters = { "coreclr", "netcoredbg" },
    -- Close the panel when the debug session ends
    close_on_exit = true,
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

local state = metrics.new(M.config.history)
---@type DotnetCountersView
local view = { status = "stopped" }
---@type DotnetCountersCollector?
local active
-- The id of the nvim-dap session whose process is being collected, nil when the
-- collection was started by hand. Only that session's events touch the panel: with
-- two sessions running (an API and a worker), the other one must not pause it or
-- stop it.
---@type integer?
local owner
local last_event = 0
---@type uv.uv_timer_t?
local idle_timer

local uv = vim.uv or vim.loop

local function redraw()
  panel.draw(state, view, { graph_height = M.config.window.graph_height, thresholds = M.config.thresholds })
end

local function reset()
  state:reset()
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

-- A tick is only committed when the next one starts. When the process is paused the next
-- one never comes, so commit after a quiet period to show the last sample anyway.
local function start_idle_timer()
  if idle_timer then
    return
  end
  idle_timer = uv.new_timer()
  idle_timer:start(
    500,
    500,
    vim.schedule_wrap(function()
      local quiet = uv.now() - last_event
      if quiet > (M.config.refresh_interval * 1000 * 1.5) then
        state:commit()
        redraw()
      end
    end)
  )
end

local function stop_idle_timer()
  if idle_timer then
    idle_timer:stop()
    idle_timer:close()
    idle_timer = nil
  end
end

--- Stop collecting. The panel stays open with the last data unless `close` is true.
---@param close boolean?
function M.detach(close)
  if active then
    active:stop()
    active = nil
  end
  stop_idle_timer()
  if view.status ~= "error" then
    view.status = "stopped"
  end
  if close then
    panel.close()
  else
    redraw()
  end
end

--- Start collecting from a process and open the panel.
---@param pid integer
---@param name string?
function M.attach(pid, name)
  local cmd = find_cmd()
  if not cmd then
    return
  end
  M.detach()
  owner = nil
  state = metrics.new(M.config.history)
  view = { status = "starting", pid = pid, name = name }
  panel.open(M.config.window, reset)
  redraw()

  local this
  this = collector.start({
    cmd = cmd,
    pid = pid,
    counters = M.config.counters,
    refresh_interval = M.config.refresh_interval,
    max_file_size = M.config.max_file_size,
    on_events = function(events)
      if active ~= this then
        return
      end
      last_event = uv.now()
      if view.status == "starting" or view.status == "paused" then
        view.status = "running"
      end
      if state:add(events) then
        redraw()
      end
    end,
    on_exit = function(code, output)
      if active ~= this then
        return
      end
      active = nil
      stop_idle_timer()
      state:commit()
      local err = output:match("[Ee]rror:?%s*([^\n]+)")
      if code ~= 0 and err then
        view.status = "error"
        view.message = err
        vim.notify(err, vim.log.levels.WARN, { title = "dotnet-counters" })
      else
        view.status = "stopped"
      end
      redraw()
    end,
  })
  active = this
  start_idle_timer()
end

function M.open()
  panel.open(M.config.window, reset)
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
        vim.notify("No .NET processes found", vim.log.levels.INFO, { title = "dotnet-counters" })
        return
      end
      vim.ui.select(items, {
        prompt = "Attach .NET counters to",
        format_item = function(item)
          return ("%d  %s  %s"):format(item.pid, item.name, item.path)
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

--- Hook into nvim-dap: attach when a .NET debuggee starts, track pause/continue, detach at the end.
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

  -- The session that started the current collection, not just any .NET session
  local function owns(session)
    return ours(session) and owner ~= nil and session.id == owner
  end

  dap.listeners.after.event_process[key] = function(session, body)
    if M.config.dap.enabled and ours(session) and body and body.systemProcessId then
      local name = session.config.program and vim.fn.fnamemodify(session.config.program, ":t:r") or body.name
      M.attach(body.systemProcessId, name)
      if active then
        owner = session.id
      end
    end
  end
  dap.listeners.after.event_stopped[key] = function(session)
    if owns(session) and active then
      view.status = "paused"
      state:commit()
      redraw()
    end
  end
  dap.listeners.after.event_continued[key] = function(session)
    if owns(session) and active and view.status == "paused" then
      view.status = "running"
      redraw()
    end
  end
  local function finished(session)
    if owns(session) and (active or panel.is_open()) and view.pid then
      owner = nil
      M.detach(M.config.dap.close_on_exit)
    end
  end
  dap.listeners.before.event_terminated[key] = finished
  dap.listeners.before.event_exited[key] = finished
  dap.listeners.before.disconnect[key] = finished
end

---@param opts DotnetCountersConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.default_config), opts or {})
  state = metrics.new(M.config.history)
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
