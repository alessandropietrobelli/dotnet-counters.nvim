-- setup(): defaults kept by a partial config, bad values replaced, options reaching the panel.
local dc = require("dotnet-counters")
local panel = require("dotnet-counters.panel")

describe("setup", function()
  local notify, draw, open, messages, drawn

  before_each(function()
    notify, draw, open = vim.notify, panel.draw, panel.open
    messages, drawn = {}, nil
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      table.insert(messages, msg)
    end
    panel.open = function() end
    panel.draw = function(state, _, opts)
      drawn = { state = state, opts = opts }
    end
  end)

  after_each(function()
    vim.notify, panel.draw, panel.open = notify, draw, open
    dc.setup({})
  end)

  it("keeps the defaults a partial config leaves out", function()
    dc.setup({ custom = { graphs = { "orders.processed" } } })
    assert.equals(5, dc.config.custom.max_tag_sets)
    assert.same({ "orders.processed" }, dc.config.custom.graphs)
  end)

  it("passes the custom options to the panel and the metrics", function()
    dc.setup({ custom = { max_tag_sets = 2, graphs = { "orders.processed" } } })
    dc.open()
    assert.same({ "orders.processed" }, drawn.opts.custom_graphs)
    assert.equals(2, drawn.state.max_tag_sets)
  end)

  it("says when a custom option is wrong, and uses the default", function()
    dc.setup({ custom = { max_tag_sets = 0, graphs = "orders.processed" } })
    assert.equals(5, dc.config.custom.max_tag_sets)
    assert.same({}, dc.config.custom.graphs)
    assert.equals(1, #messages)
    assert.matches("custom", messages[1])
  end)
end)
