-- The side window that shows the rendered metrics.
local render = require("dotnet-counters.render")

local M = {}

local ns = vim.api.nvim_create_namespace("dotnet-counters")

---@type integer?
local buf
---@type integer?
local win

local function define_highlights()
  local links = {
    DotnetCountersTitle = "Title",
    DotnetCountersSection = "Special",
    DotnetCountersLabel = "Normal",
    DotnetCountersValue = "Number",
    DotnetCountersMuted = "Comment",
    DotnetCountersRunning = "DiagnosticOk",
    DotnetCountersPaused = "DiagnosticWarn",
    DotnetCountersLow = "DiagnosticOk",
    DotnetCountersMid = "DiagnosticWarn",
    DotnetCountersHigh = "DiagnosticError",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })

---@return boolean
function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param on_reset fun()
local function ensure_buf(on_reset)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "dotnet-counters"
  vim.api.nvim_buf_set_name(buf, "dotnet-counters://panel")
  vim.keymap.set("n", "q", M.close, { buffer = buf, desc = "Close .NET counters" })
  vim.keymap.set("n", "r", on_reset, { buffer = buf, desc = "Reset .NET counters history" })
  return buf
end

---@param opts {position: "left"|"right", width: integer}
---@param on_reset fun()
function M.open(opts, on_reset)
  if M.is_open() then
    return
  end
  local previous = vim.api.nvim_get_current_win()
  vim.cmd((opts.position == "left" and "topleft" or "botright") .. " vertical " .. opts.width .. "split")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, ensure_buf(on_reset))
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.cursorline = false
  wo.wrap = false
  wo.spell = false
  wo.list = false
  wo.winfixwidth = true
  wo.statuscolumn = ""
  -- Keep the cursor where the user was: the panel is for looking, not for editing
  if vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
end

function M.close()
  if M.is_open() then
    -- The last window of a tab cannot be closed; leave it alone in that case
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
end

---@param state DotnetCountersState
---@param view DotnetCountersView
---@param opts {graph_height: integer, thresholds: table}
function M.draw(state, view, opts)
  if not M.is_open() or not buf then
    return
  end
  local width = vim.api.nvim_win_get_width(win)
  local lines = render.build(state, view, {
    width = width,
    graph_height = opts.graph_height,
    thresholds = opts.thresholds,
  })
  local text = {}
  for i, line in ipairs(lines) do
    text[i] = " " .. line.text
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    for _, h in ipairs(line.hl) do
      -- +1 for the left padding space
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, h[1] + 1, { end_col = h[2] + 1, hl_group = h[3] })
    end
  end
end

return M
