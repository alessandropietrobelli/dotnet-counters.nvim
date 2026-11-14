if vim.g.loaded_dotnet_counters then
  return
end
vim.g.loaded_dotnet_counters = true

local function usage(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "dotnet-counters" })
end

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
    elseif args[1] then
      usage("Not a pid: " .. args[1])
    else
      require("dotnet-counters").pick()
    end
  end,
  detach = function(args)
    if args[1] == "all" then
      require("dotnet-counters").detach_all()
    elseif args[1] then
      usage("Usage: :DotnetCounters detach [all]")
    else
      require("dotnet-counters").detach()
    end
  end,
  next = function()
    require("dotnet-counters").next(1)
  end,
  prev = function()
    require("dotnet-counters").next(-1)
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
    local function matching(names)
      return vim.tbl_filter(function(name)
        return name:find(arg_lead, 1, true) == 1
      end, names)
    end
    local sub = line:match("^%S+%s+(%S+)%s")
    if sub then
      return sub == "detach" and not line:match("^%S+%s+%S+%s+%S+%s") and matching({ "all" }) or {}
    end
    local names = vim.tbl_keys(subcommands)
    table.sort(names)
    return matching(names)
  end,
})
