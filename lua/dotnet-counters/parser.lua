-- Incremental parser for the JSON that `dotnet-counters collect --format json` writes.
--
-- The file is one big object whose "Events" array grows while the collector runs,
-- and it is flushed in arbitrary chunks, so it is never valid JSON while we read it.
-- Each event is a flat object starting with `{ "timestamp"`: we cut those out as they
-- become complete and decode them one by one.
local M = {}

local EVENT_START = '{ "timestamp"'

---@class DotnetCountersEvent
---@field timestamp string
---@field provider string
---@field name string
---@field tags string
---@field counterType string
---@field value number

---@class DotnetCountersParser
---@field private buf string
local Parser = {}
Parser.__index = Parser

---@return DotnetCountersParser
function M.new()
  return setmetatable({ buf = "" }, Parser)
end

--- Index of the `}` closing the object that starts at `from`, or nil if it is not complete yet.
--- Strings are skipped, since tag values such as http routes can contain braces.
---@param s string
---@param from integer
---@return integer?
local function object_end(s, from)
  local in_string, escaped = false, false
  for i = from + 1, #s do
    local c = s:byte(i)
    if in_string then
      if escaped then
        escaped = false
      elseif c == 92 then -- \
        escaped = true
      elseif c == 34 then -- "
        in_string = false
      end
    elseif c == 34 then
      in_string = true
    elseif c == 125 then -- }
      return i
    end
  end
end

--- Feed a chunk of the file and get back the events it completed.
---@param chunk string
---@return DotnetCountersEvent[]
function Parser:feed(chunk)
  local buf = self.buf .. chunk
  local events = {}
  local pos = 1
  while true do
    local s = buf:find(EVENT_START, pos, true)
    if not s then
      -- Keep a tail long enough to hold a split EVENT_START
      pos = math.max(pos, #buf - #EVENT_START + 2)
      break
    end
    local e = object_end(buf, s)
    if not e then
      pos = s
      break
    end
    local ok, event = pcall(vim.json.decode, buf:sub(s, e))
    if ok and type(event) == "table" and type(event.value) == "number" then
      table.insert(events, event)
    end
    pos = e + 1
  end
  self.buf = buf:sub(pos)
  return events
end

--- Seconds since midnight of an ISO 8601 timestamp; only differences between events matter.
---@param ts string
---@return number?
function M.seconds(ts)
  local h, m, s = ts:match("T(%d%d):(%d%d):(%d%d%.?%d*)")
  if not h then
    return nil
  end
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

return M
