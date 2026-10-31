local parser = require("dotnet-counters.parser")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

local function fixture(name)
  return table.concat(vim.fn.readfile(root .. "/fixtures/" .. name), "\n")
end

local function count_events(text)
  local n = 0
  for _ in text:gmatch('{ "timestamp"') do
    n = n + 1
  end
  return n
end

describe("parser", function()
  it("decodes every event of a file read in one go", function()
    local text = fixture("net10.json")
    local events = parser.new():feed(text)
    -- The last event of a live file may still be incomplete
    assert.is_true(#events >= count_events(text) - 1)
    for _, e in ipairs(events) do
      assert.equals("number", type(e.value))
      assert.equals("string", type(e.name))
    end
  end)

  it("gives the same events when the file arrives in small chunks", function()
    local text = fixture("net8.json")
    local whole = parser.new():feed(text)
    local p = parser.new()
    local chunked = {}
    local i = 1
    while i <= #text do
      -- Odd chunk sizes split both events and the `{ "timestamp"` marker
      local size = (i % 7) + 3
      vim.list_extend(chunked, p:feed(text:sub(i, i + size - 1)))
      i = i + size
    end
    assert.equals(#whole, #chunked)
    for k = 1, #whole do
      assert.same(whole[k], chunked[k])
    end
  end)

  it("ignores braces inside strings", function()
    local events = parser.new():feed(
      '{ "Events": [{ "timestamp": "2026-01-01T10:00:00.0+00:00",  "provider": "x",  "name": "n",'
        .. '  "tags": "http.route=/items/{id}",  "counterType": "Metric",  "value": 3 },'
    )
    assert.equals(1, #events)
    assert.equals("http.route=/items/{id}", events[1].tags)
  end)

  it("waits for an event that is not complete yet", function()
    local p = parser.new()
    assert.same({}, p:feed('[{ "timestamp": "2026-01-01T10:00:00.0+00:00",  "name": "n",  "va'))
    local events = p:feed('lue": 1 },')
    assert.equals(1, #events)
  end)

  it("converts timestamps to seconds since midnight", function()
    assert.equals(3600 + 120 + 5.5, parser.seconds("2026-10-31T01:02:05.5000000+01:00"))
    assert.is_nil(parser.seconds("garbage"))
  end)
end)
