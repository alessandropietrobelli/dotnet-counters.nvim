-- The nvim-dap hooks and the processes collected, with .NET debug sessions running at once
-- (#1, #2).
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
  local dc, dap, started, stopped, panel_open, last_view, last_state
  -- What collector.start throws, when set; the panel's next-process callback; vim.notify calls
  local start_error, on_next, notified
  local real_notify = vim.notify

  -- The options each fake collector was started with, by pid: on_events and on_exit
  local collectors

  before_each(function()
    collectors = {}
    started, stopped, panel_open, last_view, last_state = {}, {}, false, nil, nil
    start_error, on_next, notified = nil, nil, {}
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    dap = fake_dap()
    package.loaded["dap"] = dap
    package.loaded["dotnet-counters.collector"] = {
      find_cmd = function()
        return "dotnet-counters"
      end,
      start = function(opts)
        if start_error then
          error(start_error, 0)
        end
        table.insert(started, opts.pid)
        collectors[opts.pid] = opts
        return {
          stop = function()
            table.insert(stopped, opts.pid)
          end,
        }
      end,
    }
    package.loaded["dotnet-counters.panel"] = {
      open = function(_, _, next)
        panel_open, on_next = true, next
      end,
      close = function()
        panel_open = false
      end,
      is_open = function()
        return panel_open
      end,
      draw = function(state, view)
        last_state, last_view = state, vim.deepcopy(view)
      end,
    }
    package.loaded["dotnet-counters"] = nil
    dc = require("dotnet-counters")
    dc.setup({})
    dc.hook_dap()
  end)

  after_each(function()
    vim.notify = real_notify
    dc.detach_all()
    for _, name in ipairs({ "dap", "dotnet-counters", "dotnet-counters.collector", "dotnet-counters.panel" }) do
      package.loaded[name] = nil
    end
  end)

  local function start(s)
    dap.fire("event_process", s, { systemProcessId = s.pid })
  end

  local function tick(pid, mb)
    collectors[pid].on_events({
      { provider = "System.Runtime", name = "Working Set (MB)", tags = "", value = mb, timestamp = "" },
    })
  end

  local function pids()
    return vim.tbl_map(function(p)
      return p.pid
    end, dc.processes())
  end

  it("attaches to the process a session starts", function()
    start(session(1, 100))
    assert.are.same({ 100 }, started)
    assert.is_true(panel_open)
    assert.are.equal(100, last_view.pid)
  end)

  it("collects every session's process and shows the one that started last", function()
    start(session(1, 100))
    start(session(2, 200))
    assert.are.same({ 100, 200 }, started)
    assert.are.same({}, stopped)
    assert.are.equal(200, last_view.pid)
    assert.are.same({ { pid = 100, name = "App1", status = "starting" } }, last_view.others)
    assert.are.same({ 2, 2 }, { last_view.index, last_view.count })
  end)

  it("cycles between the processes", function()
    start(session(1, 100))
    start(session(2, 200))
    start(session(3, 300))
    dc.next(1)
    assert.are.equal(100, last_view.pid)
    dc.next(-1)
    assert.are.equal(300, last_view.pid)
    dc.next(-1)
    assert.are.equal(200, last_view.pid)
  end)

  it("keeps each process's data apart, and draws only the one shown", function()
    start(session(1, 100))
    start(session(2, 200))
    -- A tick is committed when the next one starts
    tick(100, 1) -- running now: the header of the one shown says so
    assert.are.equal("running", last_view.others[1].status)
    last_view = nil
    tick(100, 2)
    assert.is_nil(last_view, "a sample of the process not shown does not redraw")
    tick(200, 7)
    tick(200, 8)
    assert.are.equal(200, last_view.pid)
    assert.are.equal(7 * 1024 * 1024, last_state.current.working_set)
    dc.next()
    assert.are.equal(1024 * 1024, last_state.current.working_set)
  end)

  it("follows the session that stops at a breakpoint", function()
    local api, worker = session(1, 100), session(2, 200)
    start(worker)
    start(api)
    dap.fire("event_stopped", worker)
    assert.are.equal(200, last_view.pid)
    assert.are.equal("paused", last_view.status)
    assert.are.same({ { pid = 100, name = "App1", status = "starting" } }, last_view.others)
  end)

  it("stays on the process shown with dap.follow off", function()
    dc.setup({ dap = { follow = false } })
    local api, worker = session(1, 100), session(2, 200)
    start(worker)
    start(api)
    dap.fire("event_stopped", worker)
    assert.are.equal(100, last_view.pid)
    assert.are.same({ { pid = 200, name = "App2", status = "paused" } }, last_view.others)
  end)

  it("adds a process attached by hand, and only shows one already collected", function()
    start(session(1, 100))
    dc.attach(300, "Manual")
    dc.attach(100)
    assert.are.same({ 100, 300 }, started)
    assert.are.equal(100, last_view.pid)
    assert.are.equal(2, #dc.processes())
  end)

  it("takes processes that stopped off the list when another one is attached", function()
    start(session(1, 100))
    dc.detach()
    assert.are.equal("stopped", last_view.status)
    dc.attach(300, "Manual")
    assert.are.same({ 300 }, pids())
  end)

  it("stops every process with detach_all", function()
    start(session(1, 100))
    start(session(2, 200))
    dc.detach_all()
    table.sort(stopped)
    assert.are.same({ 100, 200 }, stopped)
    assert.is_true(panel_open)
    assert.are.equal("stopped", last_view.status)
    assert.are.equal("stopped", last_view.others[1].status)
  end)

  it("keeps collecting when another session ends, and takes that one off", function()
    local api, worker = session(1, 100), session(2, 200)
    start(worker)
    start(api)
    dc.show(200)
    dap.fire("event_terminated", worker)
    dap.fire("event_exited", worker)
    dap.fire("disconnect", worker)
    assert.are.same({ 200 }, stopped)
    assert.is_true(panel_open)
    assert.are.equal(100, last_view.pid, "the other process is shown")
    assert.are.same({}, last_view.others)
  end)

  it("stops and closes when its own session ends", function()
    local api = session(1, 100)
    start(api)
    dap.fire("event_terminated", api)
    assert.are.same({ 100 }, stopped)
    assert.is_false(panel_open)
  end)

  it("pauses only the process of the session that stopped", function()
    local api, worker = session(1, 100), session(2, 200)
    start(worker)
    start(api)
    dap.fire("event_stopped", worker)
    assert.are.same({ 200, "paused" }, { last_view.pid, last_view.status })
    dc.show(100)
    assert.are_not.equal("paused", last_view.status)
  end)

  it("keeps a session's process on the panel, stopped, with close_on_exit off", function()
    dc.setup({ dap = { close_on_exit = false } })
    local api = session(1, 100)
    start(api)
    dap.fire("event_terminated", api)
    assert.is_true(panel_open)
    assert.are.equal("stopped", last_view.status)
    assert.are.equal(100, last_view.pid)
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

  it("shows why a collector failed, and keeps collecting the others", function()
    start(session(1, 100))
    start(session(2, 200))
    collectors[100].on_exit("Process 100 is not running.")
    assert.are.equal(200, last_view.pid)
    assert.are.same({ { pid = 100, name = "App1", status = "error" } }, last_view.others)
    assert.are.same({}, stopped)
    assert.are.equal(1, #notified)
    assert.truthy(notified[1].msg:find("pid 100): Process 100 is not running.", 1, true))
    dc.show(100)
    assert.are.equal("Process 100 is not running.", last_view.message)
    dc.attach(300)
    assert.are.same({ 200, 300 }, pids(), "the failed one leaves the list once another starts")
  end)

  it("shows a process that could not be started as failed, and keeps the stopped ones", function()
    start(session(1, 100))
    dc.detach()
    start_error = "ENOENT: no such file or directory"
    dc.attach(300)
    assert.are.equal(300, last_view.pid)
    assert.are.equal("error", last_view.status)
    assert.are.equal(start_error, last_view.message)
    assert.are.same({ 100, 300 }, pids())
    start_error = nil
    dc.attach(300)
    assert.are.same({ 300 }, pids(), "the failed attempt is replaced, the stopped one leaves")
    assert.are.equal("starting", last_view.status)
  end)

  it("stops only the process shown with detach", function()
    start(session(1, 100))
    start(session(2, 200))
    dc.detach()
    assert.are.same({ 200 }, stopped)
    assert.are.equal(200, last_view.pid)
    assert.are.equal("stopped", last_view.status)
    assert.are.equal("starting", last_view.others[1].status)
    dc.next()
    assert.are.equal(100, last_view.pid)
  end)

  it("says when there is nothing to detach or switch to", function()
    dc.detach()
    dc.next()
    start(session(1, 100))
    dc.next()
    dc.detach()
    dc.detach()
    assert.are.same(
      {
        "No .NET process is collected",
        "No .NET process is collected",
        "Only one .NET process is collected",
        "No .NET process is collected",
      },
      vim.tbl_map(function(n)
        return n.msg
      end, notified)
    )
    assert.is_false(dc.show(999))
  end)

  it("ignores events a collector sends after it was stopped", function()
    start(session(1, 100))
    start(session(2, 200))
    dc.detach()
    last_view = nil
    tick(200, 1)
    assert.is_nil(last_view)
    assert.are.equal("stopped", dc.processes()[2].status)
    -- Session 1's process is taken off, and the panel closed as none is collected
    dap.fire("event_terminated", session(1, 100))
    last_view = nil
    tick(100, 1)
    assert.is_nil(last_view)
    assert.are.same({}, dc.processes())
  end)

  it("keeps collecting a process attached by hand when the session debugging it ends", function()
    dc.attach(100, "Manual")
    local api = session(1, 100)
    start(api)
    assert.are.same({ 100 }, started, "not started twice")
    dap.fire("event_stopped", api)
    assert.are.equal("paused", last_view.status)
    dap.fire("event_terminated", api)
    assert.are.same({}, stopped)
    assert.is_true(panel_open)
    assert.are.equal("running", last_view.status)
  end)

  it("still ends with its session a process detached and attached again", function()
    local api = session(1, 100)
    start(api)
    dc.detach()
    dc.attach(100)
    assert.are.equal("App1", last_view.name)
    assert.are.same({ 100, 100 }, started)
    dap.fire("event_terminated", api)
    assert.are.same({ 100, 100 }, stopped)
    assert.is_false(panel_open)
  end)

  it("resets only the process shown", function()
    start(session(1, 100))
    start(session(2, 200))
    tick(100, 1)
    tick(100, 2)
    tick(200, 1)
    tick(200, 2)
    dc.reset()
    assert.are.equal(0, last_state.samples)
    dc.next()
    assert.is_true(last_state.samples > 0)
  end)

  it("gives the panel the next-process key's action", function()
    start(session(1, 100))
    start(session(2, 200))
    on_next(1)
    assert.are.equal(100, last_view.pid)
    on_next(-1)
    assert.are.equal(200, last_view.pid)
  end)

  it("reports an error in a hook instead of passing it to nvim-dap", function()
    local api = session(1, 100)
    start(api)
    local fake_panel = package.loaded["dotnet-counters.panel"]
    local draw = fake_panel.draw
    fake_panel.draw = function()
      error("boom")
    end
    assert.has_no.errors(function()
      dap.fire("event_stopped", api)
    end)
    fake_panel.draw = draw
    assert.are.equal(vim.log.levels.ERROR, notified[1].level)
    assert.truthy(notified[1].msg:find("event_stopped: .*boom"))
  end)

  it("ignores sessions of other adapters", function()
    local js = { id = 9, config = { type = "pwa-node" } }
    dap.fire("event_process", js, { systemProcessId = 900 })
    assert.are.same({}, started)
  end)
end)
