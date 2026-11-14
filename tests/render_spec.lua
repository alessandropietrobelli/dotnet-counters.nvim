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
      state:add({ { provider = "System.Runtime", name = "Working Set (MB)", tags = "", value = 300, timestamp = "" } })
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

  for _, name in ipairs({ "net10.json", "net8.json", "aspnet8.json", "custom10.json" }) do
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

  it("lists the other processes under the header, inside the panel", function()
    local lines = render.build(metrics.new(10), {
      status = "running",
      pid = 100,
      name = "Api",
      index = 1,
      count = 3,
      others = {
        { pid = 200, name = "Worker", status = "paused" },
        { pid = 300, name = "A.Very.Long.Service.Name.That.Does.Not.Fit", status = "stopped" },
      },
    }, { width = 46, graph_height = 2 })
    assert.matches("1/3  <Tab> next", lines[1].text)
    assert.equals("  ⏸ Worker · pid 200", lines[3].text)
    assert.matches("^  ■ A%.Very.*…$", lines[4].text)
    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line.text) <= 44, line.text)
    end
  end)

  it("says it is waiting before the first sample", function()
    local lines = render.build(metrics.new(10), { status = "starting" }, { width = 46, graph_height = 2 })
    assert.matches("Waiting", lines[#lines].text)
  end)

  --- The lines of the Custom section, from its title to the end.
  local function custom_lines(state, opts)
    local lines =
      render.build(state, { status = "running" }, vim.tbl_extend("force", { width = 46, graph_height = 2 }, opts or {}))
    local out, inside = {}, false
    for _, line in ipairs(lines) do
      inside = inside or line.text:find("^Custom") ~= nil
      if inside then
        table.insert(out, line.text)
      end
    end
    return out
  end

  --- A state with one tick of the given custom events, of provider "App".
  local function custom_state(list, opts)
    local state = metrics.new(10, opts)
    local batch = {}
    for _, e in ipairs(list) do
      table.insert(batch, { provider = "App", name = e[1], tags = e.tags or "", value = e[2], timestamp = "" })
    end
    state:add(batch)
    state:commit()
    return state
  end

  local function fits(lines, width)
    for _, line in ipairs(lines) do
      assert.is_true(
        vim.fn.strdisplaywidth(line) <= width,
        ("%d > %d: %s"):format(vim.fn.strdisplaywidth(line), width, line)
      )
    end
  end

  it("shows other providers' counters in a Custom section, one line per tag set", function()
    local lines = custom_lines(state_from("custom10.json"))
    local text = table.concat(lines, "\n")
    assert.matches("^Custom", lines[1])
    assert.matches("\norders%.processed\n", text, nil, "a name line above its tag sets")
    assert.matches("\n  region=eu +[\128-\255 ]+ +%d+/s", text)
    assert.matches("\n  region=eu +[\128-\255 ]+ +p95 %d+ ms", text, nil, "a histogram shows its p95")
    assert.matches("\norders%.payload%.size +[\128-\255 ]+ +[%d.]+ KB/s", text)
    assert.matches("\norders%.queue%.length +[\128-\255 ]+ +%d+\n", text)
    assert.not_matches("fragmentation", text, "System.Runtime counters the panel has no section for")
    assert.same({}, custom_lines(state_from("net10.json")))
  end)

  it("lines the sparklines and the values up, and limits the tag sets shown", function()
    local text = table.concat(vim.fn.readfile(root .. "/fixtures/custom10.json"), "\n")
    local state = metrics.new(50, { max_tag_sets = 2 })
    state:add(parser.new():feed(text))
    state:commit()
    local lines = custom_lines(state)
    local starts, ends = {}, {}
    for _, line in ipairs(lines) do
      local at = line:find("[\128-\255]")
      if at and not line:find("^Custom") then
        starts[vim.fn.strdisplaywidth(line:sub(1, at - 1))] = true
        ends[vim.fn.strdisplaywidth(line)] = true
      end
    end
    assert.equals(1, vim.tbl_count(starts), "sparklines start in one column")
    assert.same({ [44] = true }, ends)
    assert.equals(2, #vim.tbl_filter(function(l)
      return l == "  +1 more"
    end, lines))
  end)

  it("draws a full graph for the instruments asked for, by name with or without the unit", function()
    for _, name in ipairs({ "orders.queue.length", "orders.queue.length ({order})" }) do
      local lines = custom_lines(state_from("custom10.json"), { custom_graphs = { name } })
      local found = false
      for i, line in ipairs(lines) do
        if line:find("^orders%.queue%.length") then
          assert.not_matches("[\128-\255]", line, "no sparkline on the value line")
          assert.matches("^[ \128-\255]+$", lines[i + 1])
          assert.matches("^[ \128-\255]+$", lines[i + 2])
          found = true
        end
      end
      assert.is_true(found, name)
    end
  end)

  it("draws a graph for each tag set of a graphed instrument", function()
    local lines = custom_lines(state_from("custom10.json"), { custom_graphs = { "orders.processed" } })
    for i, line in ipairs(lines) do
      if line == "orders.processed" then
        for k = 0, 2 do
          assert.matches("^  region=%a+ +%d+/s$", lines[i + 1 + k * 3])
          assert.matches("^[ \128-\255]+$", lines[i + 2 + k * 3])
        end
        return
      end
    end
    error("orders.processed not shown")
  end)

  it("keeps long names, tags and values inside the panel", function()
    local long = "a.really.long.instrument.name.that.goes.on.and.on.forever"
    local state = custom_state({
      { long .. " ({x})", 1, tags = "k=v" },
      { long .. " ({x})", 2, tags = "tenant=一二三四五六七八九十一二三四五六七八九十" },
      { "short (s)", 0.012, tags = "Percentile=95" },
      { "big ({x} / 1 sec)", 1234567890 },
    })
    -- The panel's content is never narrower than 20 columns
    for _, width in ipairs({ 46, 30, 22 }) do
      fits(custom_lines(state, { width = width }), width - 2)
      fits(custom_lines(state, { width = width, custom_graphs = { long } }), width - 2)
    end
    local text = table.concat(custom_lines(state), "\n")
    assert.matches("…", text)
  end)

  it("drops the sparklines rather than the values when the panel is narrow", function()
    local lines = custom_lines(custom_state({ { "big ({x} / 1 sec)", 1234567890 } }), { width = 24 })
    assert.matches("1,234,567,890/s$", lines[2])
    assert.not_matches("[\128-\255]", lines[2])
  end)
end)

describe("custom values", function()
  it("are read in their unit", function()
    assert.equals("1.5 KB/s", render.value(1536, "By", true))
    assert.equals("512 B", render.value(512, "B", false))
    assert.equals("12 ms", render.value(0.012, "s", false))
    assert.equals("12 ms", render.value(12, "ms", false))
    assert.equals("2 ms", render.value(1500 + 500, "us", false))
    assert.equals("7.5%", render.value(7.5, "%", false))
    assert.equals("1,234/s", render.value(1234, "{order}", true))
    assert.equals("12", render.value(12, "Count", false))
    assert.equals("3 KiBy", render.value(3, "KiBy", false), "an unknown unit is written out")
  end)

  it("keep small, negative and large numbers readable", function()
    assert.equals("0.25", render.value(0.25, nil, false))
    assert.equals("0.004/s", render.value(0.004, nil, true))
    assert.equals("-123", render.value(-123, nil, false))
    assert.equals("-1,234", render.value(-1234, "{x}", false))
    assert.equals("-512 B", render.value(-512, "By", false))
    assert.equals("123", render.value(123.4, nil, false))
    assert.equals("9,007,199,254,740,992", render.value(2 ^ 53, nil, false))
  end)
end)
