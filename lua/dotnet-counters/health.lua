local M = {}

function M.check()
  local health = vim.health
  local config = require("dotnet-counters").config

  health.start("dotnet-counters.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ is required (vim.system)")
  end

  local cmd = require("dotnet-counters.collector").find_cmd(config.cmd)
  if cmd then
    local result = vim.system({ cmd, "--version" }, { text = true }):wait(5000)
    -- "10.0.750501+ad724c4b…": the build hash is noise
    local version = (result.stdout or ""):match("^%s*([^+%s]+)") or "?"
    health.ok(("dotnet-counters %s (%s)"):format(version, cmd))
  else
    health.error("dotnet-counters not found", { "Install it with `dotnet tool install -g dotnet-counters`" })
  end

  if pcall(require, "dap") then
    health.ok(
      "nvim-dap found: the panel opens with .NET debug sessions (" .. table.concat(config.dap.adapters, ", ") .. ")"
    )
  else
    health.info("nvim-dap not found: use `:DotnetCounters attach` to attach to a running process")
  end
end

return M
