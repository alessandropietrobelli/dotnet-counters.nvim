if vim.g.loaded_dotnet_counters then
  return
end
vim.g.loaded_dotnet_counters = true

local subcommands = {
  toggle = function()
    require("dotnet-counters").toggle()
  end,
  open = function()
    require("dotnet-counters").open()
  end,
  close = function()
    require("dotnet-counters").close()
  end,
  attach = function(args)
    local pid = tonumber(args[1])
    if pid then
      require("dotnet-counters").attach(pid)
    else
      require("dotnet-counters").pick()
    end
  end,
  detach = function()
    require("dotnet-counters").detach()
  end,
  reset = function()
    require("dotnet-counters").reset()
  end,
}

vim.api.nvim_create_user_command("DotnetCounters", function(opts)
  local args = vim.split(vim.trim(opts.args), "%s+", { trimempty = true })
  local name = table.remove(args, 1) or "toggle"
  local fn = subcommands[name]
  if not fn then
    vim.notify("Unknown subcommand: " .. name, vim.log.levels.ERROR, { title = "dotnet-counters" })
    return
  end
  fn(args)
end, {
  nargs = "*",
  desc = ".NET runtime counters panel",
  complete = function(arg_lead, line)
    if line:match("^%S+%s+%S+%s") then
      return {}
    end
    return vim.tbl_filter(function(name)
      return name:find(arg_lead, 1, true) == 1
    end, vim.tbl_keys(subcommands))
  end,
})
