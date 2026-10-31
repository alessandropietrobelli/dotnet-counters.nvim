local render = require("dotnet-counters.render")
local metrics = require("dotnet-counters.metrics")
local parser = require("dotnet-counters.parser")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

describe("formatting", function()
  it("formats bytes", function()
    assert.equals("512 B", render.bytes(512))
    assert.equals("1.5 KB", render.bytes(1536))
    assert.equals("412 MB", render.bytes(412 * 1024 * 1024))
    assert.equals("2.0 GB", render.bytes(2 * 1024 ^ 3))
  end)

  it("formats durations", function()
    assert.equals("43 µs", render.duration(0.000043))
    assert.equals("12 ms", render.duration(0.012))
    assert.equals("1.50 s", render.duration(1.5))
  end)

  it("formats counts with thousands separators", function()
    assert.equals("7", render.count(7))
    assert.equals("1,234", render.count(1234))
    assert.equals("1,234,567", render.count(1234567))
  end)
end)

describe("graph", function()
  it("has the requested size, newest sample on the right", function()
    local rows = render.graph({ 1, 2, 4 }, 6, 2, 0)
    assert.equals(2, #rows)
    for _, row in ipairs(rows) do
      assert.equals(6, vim.fn.strchars(row))
    end
    -- The maximum fills both rows in the last column
    assert.equals("█", vim.fn.strcharpart(rows[1], 5, 1))
    assert.equals("█", vim.fn.strcharpart(rows[2], 5, 1))
    -- Left padding where there is no history yet
    assert.equals("   ", vim.fn.strcharpart(rows[2], 0, 3))
  end)

  it("keeps only the latest samples that fit", function()
    local rows = render.graph({ 9, 9, 9, 1, 1 }, 2, 1, 0)
    -- 9s are scrolled out, so the 1s are the maximum
    assert.equals("██", rows[1])
  end)

  it("uses the floor so small values do not look maxed out", function()
    local rows, levels = render.graph({ 1 }, 1, 1, 100)
    assert.equals("▁", rows[1])
    assert.is_true(levels[1] < 0.1)
  end)

  it("draws nothing for zero", function()
    assert.equals("  ", render.graph({ 0, 0 }, 2, 1, 1)[1])
  end)
end)

describe("graph colours", function()
  local MB = 1024 * 1024

  it("follow absolute thresholds, not the top of the graph", function()
    assert.equals("DotnetCountersLow", render.severity(300 * MB, { 3000 * MB, 9000 * MB }))
    assert.equals("DotnetCountersMid", render.severity(4000 * MB, { 3000 * MB, 9000 * MB }))
    assert.equals("DotnetCountersHigh", render.severity(9000 * MB, { 3000 * MB, 9000 * MB }))
  end)

  it("stay green without thresholds", function()
    assert.equals("DotnetCountersLow", render.severity(1e12, nil))
  end)

  it("keep a steady memory graph green although it fills the height", function()
    local state = metrics.new(10)
    for _ = 1, 5 do
      state:add({ { name = "Working Set (MB)", tags = "", value = 300, timestamp = "" } })
      state:commit()
    end
    local lines = render.build(state, { status = "running" }, {
      width = 46,
      graph_height = 2,
      thresholds = { memory = { 0.10, 0.25 } },
      total_memory = 36 * 1024 * MB,
    })
    local graph_groups = {}
    for i, line in ipairs(lines) do
      if line.text:find("^Working set") then
        for _, h in ipairs(lines[i + 1].hl) do
          graph_groups[h[3]] = true
        end
        -- The steady value is the top of its own scale: the graph is full height
        assert.matches("█", lines[i + 1].text)
      end
    end
    assert.same({ DotnetCountersLow = true }, graph_groups)
  end)
end)

describe("panel content", function()
  local function state_from(name)
    local text = table.concat(vim.fn.readfile(root .. "/fixtures/" .. name), "\n")
    local state = metrics.new(50)
    state:add(parser.new():feed(text))
    state:commit()
    return state
  end

  for _, name in ipairs({ "net10.json", "net8.json", "aspnet8.json" }) do
    it("fits the window for " .. name, function()
      local lines = render.build(state_from(name), { status = "running", pid = 42, name = "App" }, {
        width = 46,
        graph_height = 2,
      })
      assert.is_true(#lines > 10)
      for _, line in ipairs(lines) do
        assert.is_true(vim.fn.strdisplaywidth(line.text) <= 44, line.text)
        for _, h in ipairs(line.hl) do
          assert.is_true(h[1] >= 0 and h[2] <= #line.text, line.text)
        end
      end
    end)
  end

  it("shows the HTTP section only for web apps", function()
    local function has_http(name)
      local lines = render.build(state_from(name), { status = "running" }, { width = 46, graph_height = 2 })
      for _, line in ipairs(lines) do
        if line.text:find("^HTTP") then
          return true
        end
      end
      return false
    end
    assert.is_false(has_http("net10.json"))
    assert.is_true(has_http("aspnet8.json"))
  end)

  it("says it is waiting before the first sample", function()
    local lines = render.build(metrics.new(10), { status = "starting" }, { width = 46, graph_height = 2 })
    assert.matches("Waiting", lines[#lines].text)
  end)
end)
