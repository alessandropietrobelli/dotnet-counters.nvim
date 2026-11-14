-- :DotnetCounters subcommands and their completion, against a fake module.

describe(":DotnetCounters", function()
  local calls, notified
  local real_notify = vim.notify

  before_each(function()
    calls, notified = {}, {}
    local function record(name)
      return function(...)
        table.insert(calls, { name, ... })
      end
    end
    package.loaded["dotnet-counters"] = {
      toggle = record("toggle"),
      attach = record("attach"),
      pick = record("pick"),
      detach = record("detach"),
      detach_all = record("detach_all"),
      next = record("next"),
      reset = record("reset"),
    }
    vim.notify = function(msg)
      table.insert(notified, msg)
    end
    vim.g.loaded_dotnet_counters = nil
    vim.cmd.runtime("plugin/dotnet-counters.lua")
  end)

  after_each(function()
    vim.notify = real_notify
    package.loaded["dotnet-counters"] = nil
  end)

  it("runs the subcommands", function()
    vim.cmd("DotnetCounters detach all")
    vim.cmd("DotnetCounters detach")
    vim.cmd("DotnetCounters next")
    vim.cmd("DotnetCounters prev")
    vim.cmd("DotnetCounters attach 123")
    vim.cmd("DotnetCounters attach")
    vim.cmd("DotnetCounters")
    assert.same({
      { "detach_all" },
      { "detach" },
      { "next", 1 },
      { "next", -1 },
      { "attach", 123 },
      { "pick" },
      { "toggle" },
    }, calls)
  end)

  it("rejects arguments it does not know instead of guessing", function()
    vim.cmd("DotnetCounters detach 123")
    vim.cmd("DotnetCounters attach 12a4")
    assert.same({}, calls)
    assert.same({ "Usage: :DotnetCounters detach [all]", "Not a pid: 12a4" }, notified)
  end)

  it("completes the subcommands, and all after detach", function()
    local subs = vim.fn.getcompletion("DotnetCounters ", "cmdline")
    assert.is_true(vim.tbl_contains(subs, "next") and vim.tbl_contains(subs, "prev"))
    assert.same({ "all" }, vim.fn.getcompletion("DotnetCounters detach ", "cmdline"))
    assert.same({}, vim.fn.getcompletion("DotnetCounters detach all ", "cmdline"))
    assert.same({}, vim.fn.getcompletion("DotnetCounters next ", "cmdline"))
  end)
end)
