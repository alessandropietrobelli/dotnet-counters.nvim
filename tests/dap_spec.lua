-- The nvim-dap hooks, with two .NET debug sessions running at once (#1).
-- nvim-dap, the collector and the panel are replaced by fakes: what is checked is
-- which session's events reach the panel.

local function fake_dap()
  local listeners = { before = {}, after = {} }
  for _, phase in pairs(listeners) do
    for _, event in ipairs({
      "event_process",
      "event_stopped",
      "event_continued",
      "event_terminated",
      "event_exited",
      "disconnect",
    }) do
      phase[event] = {}
    end
  end
  local dap = { listeners = listeners }
  -- Fire every listener nvim-dap would call for `event`, in both phases.
  function dap.fire(event, session, body)
    for _, phase in ipairs({ "before", "after" }) do
      for _, listener in pairs(listeners[phase][event]) do
        listener(session, body)
      end
    end
  end
  return dap
end

local function session(id, pid)
  return { id = id, config = { type = "coreclr", program = "/src/App" .. id .. "/bin/App" .. id .. ".dll" }, pid = pid }
end

describe("nvim-dap hooks", function()
  local dc, dap, started, stopped, panel_open, last_view

  before_each(function()
    started, stopped, panel_open, last_view = {}, {}, false, nil
    dap = fake_dap()
    package.loaded["dap"] = dap
    package.loaded["dotnet-counters.collector"] = {
      find_cmd = function()
        return "dotnet-counters"
      end,
      start = function(opts)
        table.insert(started, opts.pid)
        return {
          stop = function()
            table.insert(stopped, opts.pid)
          end,
        }
      end,
    }
    package.loaded["dotnet-counters.panel"] = {
      open = function()
        panel_open = true
      end,
      close = function()
        panel_open = false
      end,
      is_open = function()
        return panel_open
      end,
      draw = function(_, view)
        last_view = vim.deepcopy(view)
      end,
    }
    package.loaded["dotnet-counters"] = nil
    dc = require("dotnet-counters")
    dc.setup({})
    dc.hook_dap()
  end)

  after_each(function()
    dc.detach()
    for _, name in ipairs({ "dap", "dotnet-counters", "dotnet-counters.collector", "dotnet-counters.panel" }) do
      package.loaded[name] = nil
    end
  end)

  local function start(s)
    dap.fire("event_process", s, { systemProcessId = s.pid })
  end

  it("attaches to the process a session starts", function()
    start(session(1, 100))
    assert.are.same({ 100 }, started)
    assert.is_true(panel_open)
    assert.are.equal(100, last_view.pid)
  end)

  it("follows the session that started last", function()
    start(session(1, 100))
    start(session(2, 200))
    assert.are.same({ 100, 200 }, started)
    assert.are.same({ 100 }, stopped)
    assert.are.equal(200, last_view.pid)
  end)

  it("keeps collecting when another session ends", function()
    local api, worker = session(1, 100), session(2, 200)
    start(worker)
    start(api)
    dap.fire("event_terminated", worker)
    dap.fire("event_exited", worker)
    dap.fire("disconnect", worker)
    assert.are.same({ 200 }, stopped) -- only the hand-over from the worker to the api
    assert.is_true(panel_open)
    assert.are.equal(100, last_view.pid)
  end)

  it("stops and closes when its own session ends", function()
    local api = session(1, 100)
    start(api)
    dap.fire("event_terminated", api)
    assert.are.same({ 100 }, stopped)
    assert.is_false(panel_open)
  end)

  it("ignores a breakpoint hit in another session", function()
    local api, worker = session(1, 100), session(2, 200)
    start(worker)
    start(api)
    dap.fire("event_stopped", worker)
    assert.are_not.equal("paused", last_view.status)
  end)

  it("pauses and resumes with its own session", function()
    local api = session(1, 100)
    start(api)
    dap.fire("event_stopped", api)
    assert.are.equal("paused", last_view.status)
    dap.fire("event_continued", api)
    assert.are.equal("running", last_view.status)
  end)

  it("leaves a process attached by hand alone when a session ends", function()
    local api = session(1, 100)
    start(api)
    dc.attach(300, "Manual")
    dap.fire("event_stopped", api)
    dap.fire("event_terminated", api)
    assert.are.same({ 100 }, stopped)
    assert.is_true(panel_open)
    assert.are.equal(300, last_view.pid)
    assert.are_not.equal("paused", last_view.status)
  end)

  it("ignores sessions of other adapters", function()
    local js = { id = 9, config = { type = "pwa-node" } }
    dap.fire("event_process", js, { systemProcessId = 900 })
    assert.are.same({}, started)
  end)
end)
