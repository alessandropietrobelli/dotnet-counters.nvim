-- The Neovim configuration used to record assets/demo.gif. Copy it to
-- ~/.config/dotnet-counters-demo/init.lua and run:
--
--   NVIM_APPNAME=dotnet-counters-demo nvim
--
-- NVIM_APPNAME moves config, data and state into their own directories, so this
-- touches nothing in ~/.config/nvim.
--
-- It is dressed for the camera (colorscheme, no line numbers, no statusline) and
-- drives the debugger from <leader> keys, because VHS cannot press F5.
--
-- Paths to point at your machine:

-- where this repository is checked out
local PLUGIN_DIR = vim.env.DOTNET_COUNTERS_DIR or vim.fn.expand("~/src/dotnet-counters.nvim")
-- a netcoredbg binary (on Apple Silicon, an arm64 build: Mason's is x86_64)
local NETCOREDBG = vim.env.NETCOREDBG or vim.fn.exepath("netcoredbg")
-- where jellyfin keeps its data during the demo; anything throwaway
local DATA_DIR = vim.env.DEMO_DATA or (vim.fn.stdpath("cache") .. "/jellyfin-demo")

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "

vim.opt.termguicolors = true
vim.opt.number = false
vim.opt.signcolumn = "yes"
vim.opt.hlsearch = false
-- VHS emits a frame when the screen changes; a blinking cursor gives still
-- frames something to differ by.
vim.opt.guicursor = "n-v-c:block-blinkwait200-blinkon450-blinkoff450,i:ver25-blinkwait200-blinkon450-blinkoff450"
vim.opt.laststatus = 0
vim.opt.cmdheight = 1
vim.opt.showmode = false
vim.opt.fillchars = { eob = " " }

--- Say what a key does at the bottom of the screen, for whoever watches the demo.
local function say(text)
  vim.api.nvim_echo({ { text, "Title" } }, false, {})
end

require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = { style = "night" },
    config = function(_, opts)
      require("tokyonight").setup(opts)
      vim.cmd.colorscheme("tokyonight")
    end,
  },
  {
    "mfussenegger/nvim-dap",
    lazy = false,
    config = function()
      local dap = require("dap")
      dap.adapters.coreclr = { type = "executable", command = NETCOREDBG, args = { "--interpreter=vscode" } }
      local jellyfin = {
        type = "coreclr",
        request = "launch",
        name = "Jellyfin.Server",
        program = vim.fn.getcwd() .. "/Jellyfin.Server/bin/Debug/net10.0/jellyfin.dll",
        cwd = vim.fn.getcwd() .. "/Jellyfin.Server/bin/Debug/net10.0",
        args = {
          "--datadir",
          DATA_DIR .. "/data",
          "--cachedir",
          DATA_DIR .. "/cache",
          "--configdir",
          DATA_DIR .. "/config",
          "--logdir",
          DATA_DIR .. "/log",
          "--nowebclient",
        },
        justMyCode = true,
      }
      vim.keymap.set("n", "<leader>r", function()
        if dap.session() then
          say("▶ continue")
          dap.continue()
        else
          say("▶ debug Jellyfin.Server")
          dap.run(jellyfin)
        end
      end)
      -- dap.pause() asks which thread when there are several; pause the first one
      vim.keymap.set("n", "<leader>p", function()
        local session = dap.session()
        if session then
          say("⏸ pause")
          session:request("pause", { threadId = next(session.threads) or 1 }, function() end)
        end
      end)
      vim.keymap.set("n", "<leader>b", function()
        say("● toggle breakpoint")
        dap.toggle_breakpoint()
      end)
      vim.keymap.set("n", "<leader>s", function()
        say("■ stop")
        dap.terminate()
      end)
      vim.fn.sign_define("DapStopped", { text = "▶", texthl = "DiagnosticWarn", linehl = "Visual" })
      vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError" })
    end,
  },
  {
    "dotnet-counters.nvim",
    dir = PLUGIN_DIR,
    lazy = false,
    opts = { window = { width = 50 } },
    keys = {
      {
        "<leader>m",
        function()
          say("󰪚 toggle the .NET runtime panel")
          vim.cmd("DotnetCounters toggle")
        end,
      },
    },
  },
}, {
  install = { colorscheme = { "tokyonight" } },
  change_detection = { notify = false },
  ui = { backdrop = 100 },
})
