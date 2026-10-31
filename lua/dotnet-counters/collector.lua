-- Runs `dotnet-counters collect` against a process and streams its events.
--
-- `monitor` only draws a console UI, so `collect --format json` is used instead. It can only
-- write to a file (a FIFO gets replaced by a regular file), which is polled and read from
-- the last offset. The file grows by ~10 KB/s, so it is restarted past `max_file_size`.
local parser = require("dotnet-counters.parser")

local M = {}

local uv = vim.uv or vim.loop

---@class DotnetCountersCollectorOpts
---@field cmd string dotnet-counters executable
---@field pid integer
---@field counters string
---@field refresh_interval integer seconds
---@field max_file_size integer bytes
---@field on_events fun(events: DotnetCountersEvent[])
---@field on_exit fun(code: integer, stderr: string)

---@class DotnetCountersCollector
---@field private opts DotnetCountersCollectorOpts
---@field private proc vim.SystemObj?
---@field private file string?
---@field private offset integer
---@field private parser DotnetCountersParser
---@field private timer uv.uv_timer_t?
---@field private stopping boolean
---@field private rotating boolean
local Collector = {}
Collector.__index = Collector

--- Resolve the dotnet-counters executable: explicit config, PATH, then the global tools dir.
---@param cmd string?
---@return string?
function M.find_cmd(cmd)
  if cmd and cmd ~= "" then
    return vim.fn.executable(cmd) == 1 and cmd or nil
  end
  local path = vim.fn.exepath("dotnet-counters")
  if path ~= "" then
    return path
  end
  local tools = vim.fn.expand("~/.dotnet/tools/dotnet-counters")
  if vim.fn.executable(tools) == 1 then
    return tools
  end
end

---@param opts DotnetCountersCollectorOpts
---@return DotnetCountersCollector
function M.start(opts)
  local self = setmetatable({ opts = opts, offset = 0, stopping = false, rotating = false }, Collector)
  self:spawn()
  self.timer = uv.new_timer()
  self.timer:start(
    250,
    250,
    vim.schedule_wrap(function()
      self:poll()
    end)
  )
  return self
end

function Collector:spawn()
  local file = vim.fn.tempname() .. ".json"
  self.file = file
  self.offset = 0
  self.parser = parser.new()
  local o = self.opts
  local stderr = {}
  self.proc = vim.system({
    o.cmd,
    "collect",
    "--process-id",
    tostring(o.pid),
    "--format",
    "json",
    "--output",
    self.file,
    "--refresh-interval",
    tostring(o.refresh_interval),
    "--counters",
    o.counters,
  }, {
    -- dotnet-counters prints its errors (e.g. "Concurrent sessions are not supported") on stdout
    stdout = function(_, data)
      table.insert(stderr, data)
    end,
    stderr = function(_, data)
      table.insert(stderr, data)
    end,
  }, function(result)
    vim.schedule(function()
      if self.rotating then
        -- The old session is gone: the runtime accepts a new one now
        self.rotating = false
        os.remove(file)
        if not self.stopping then
          self:spawn()
        end
        return
      end
      self:cleanup()
      if not self.stopping then
        o.on_exit(result.code, table.concat(stderr))
      end
    end)
  end)
end

function Collector:poll()
  if not self.file then
    return
  end
  local stat = uv.fs_stat(self.file)
  if not stat or stat.size <= self.offset then
    return
  end
  local fd = uv.fs_open(self.file, "r", 438)
  if not fd then
    return
  end
  local data = uv.fs_read(fd, stat.size - self.offset, self.offset)
  uv.fs_close(fd)
  if not data or #data == 0 then
    return
  end
  self.offset = self.offset + #data
  local events = self.parser:feed(data)
  if #events > 0 then
    self.opts.on_events(events)
  end
  if self.offset > self.opts.max_file_size then
    self:rotate()
  end
end

--- Start over on a new file. The runtime only allows one session per process, so the new
--- collector is spawned from the old one's exit callback.
function Collector:rotate()
  if self.rotating or not self.proc then
    return
  end
  self.rotating = true
  self.file = nil
  self.proc:kill("sigint")
end

function Collector:cleanup()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  if self.file then
    os.remove(self.file)
    self.file = nil
  end
end

--- Stop collecting. SIGINT lets dotnet-counters close the EventPipe session cleanly,
--- otherwise the next attach to the same process can fail with "concurrent sessions".
function Collector:stop()
  if self.stopping then
    return
  end
  self.stopping = true
  if self.proc and not self.proc:is_closing() then
    self.proc:kill("sigint")
    local proc = self.proc
    vim.defer_fn(function()
      if not proc:is_closing() then
        proc:kill("sigkill")
      end
    end, 3000)
  end
  self:cleanup()
end

return M
