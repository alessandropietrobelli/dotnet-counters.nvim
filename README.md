# dotnet-counters.nvim

Live .NET runtime metrics in a Neovim side panel — CPU, memory, GC, thread pool, exceptions and
HTTP latency, with btop-style graphs — right next to the debugger.

```
 󰪚 .NET runtime
 ● running  MyApi · pid 26054

 CPU                          3.2%  peak 7.9%
                              ▁▂▂▃▅▇▅▃▂▂▃▂▁▁▂
 Working set              412 MB  peak 520 MB
                          ▃▃▄▄▅▅▅▆▆▆▆▇▇▇▇▇
                          ███████████████
 GC heap             188 MB  committed 240 MB
 Allocations                         24 MB/s
 Time in GC                              3.1%

 GC ─────────────────────────────────────────
 Collections gen0                   142  9/s
 Exceptions ─────────────────────────────────
 Thrown                         2/s  16 total
   InvalidOperationException              ×16
 HTTP ───────────────────────────────────────
 In flight                                  3
 p95 (slowest route)                    12 ms
 GET /orders/{id} 200                   12 ms
 POST /orders 500                        4 ms
```

The panel opens by itself when an [nvim-dap](https://github.com/mfussenegger/nvim-dap) session
starts a .NET process, shows when the debugger has paused it, and closes when the session ends. It
can also attach to any running .NET process, debugger or not.

## How it works

The numbers come from [`dotnet-counters`](https://learn.microsoft.com/dotnet/core/diagnostics/dotnet-counters),
Microsoft's diagnostics tool, which reads the runtime's EventPipe counters. The plugin runs
`dotnet-counters collect --format json` against the process, reads its output as it grows and
renders the panel once per sample.

- **.NET 8 and .NET 9+** are both supported. .NET 8 publishes EventCounters (`CPU Usage (%)`),
  .NET 9+ publishes `System.Runtime` meters (`dotnet.process.cpu.time`); both are mapped onto the
  same metrics.
- **ASP.NET Core** apps also get requests in flight and the p95 latency of each route, with the
  status code.
- **CPU** is a percentage of the whole machine (all cores), like the .NET 8 counter and Task Manager.
- **While the debugger is stopped** the process is suspended, so the graphs pause with it.

## Requirements

- Neovim 0.10+
- `dotnet-counters`: `dotnet tool install -g dotnet-counters`
- [nvim-dap](https://github.com/mfussenegger/nvim-dap) with a .NET adapter (netcoredbg) for the
  automatic panel — optional, `:DotnetCounters attach` works without it

`:checkhealth dotnet-counters` checks all of the above.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "alessandropietrobelli/dotnet-counters.nvim",
  -- Load early (setup is cheap) so it can hook into nvim-dap before the first session
  event = "VeryLazy",
  cmd = "DotnetCounters",
  opts = {},
  keys = {
    { "<leader>dm", "<cmd>DotnetCounters toggle<cr>", desc = ".NET metrics panel" },
    { "<leader>dM", "<cmd>DotnetCounters attach<cr>", desc = ".NET metrics: attach to process" },
  },
}
```

## Usage

| Command | |
|---|---|
| `:DotnetCounters` / `:DotnetCounters toggle` | Show or hide the panel |
| `:DotnetCounters attach [pid]` | Attach to a process; without a pid, pick one from `dotnet-counters ps` |
| `:DotnetCounters detach` | Stop collecting, keep the last data on screen |
| `:DotnetCounters reset` | Clear history, peaks and totals |
| `:DotnetCounters open` / `close` | Open or close the panel |

In the panel, `q` closes it and `r` resets the history.

## Configuration

Defaults:

```lua
require("dotnet-counters").setup({
  -- dotnet-counters executable; nil looks in PATH and then ~/.dotnet/tools
  cmd = nil,
  -- Providers passed to `dotnet-counters collect --counters`
  counters = "System.Runtime,Microsoft.AspNetCore.Hosting",
  -- Seconds between samples
  refresh_interval = 1,
  -- Restart the collector when its output file grows past this many bytes
  max_file_size = 32 * 1024 * 1024,
  -- Samples kept for the graphs
  history = 200,
  dap = {
    -- Attach and open the panel when a debug session of one of these adapters starts a process
    enabled = true,
    adapters = { "coreclr", "netcoredbg" },
    -- Close the panel when the debug session ends
    close_on_exit = true,
  },
  window = {
    position = "right",
    width = 46,
    graph_height = 2,
  },
  -- Graph colours: {warn, critical} in each metric's unit. Below warn is green, then yellow, then
  -- red. Graph heights stay relative to the visible maximum; only the colour uses these.
  thresholds = {
    cpu = { 25, 60 }, -- % of the whole machine
    memory = { 0.10, 0.25 }, -- fraction of the machine's RAM (working set and GC heap)
    alloc_rate = { 256 * 1024 * 1024, 1024 * 1024 * 1024 }, -- bytes/s
    gc_time = { 5, 10 }, -- % of time paused by the GC
    http_active = nil, -- requests in flight: no threshold, always green
    http_p95 = { 0.2, 1 }, -- seconds
  },
})
```

### Highlights

Every group links to a standard one by default, so the panel follows your colour scheme:

| Group | Default link |
|---|---|
| `DotnetCountersTitle` | `Title` |
| `DotnetCountersSection` | `Special` |
| `DotnetCountersLabel` | `Normal` |
| `DotnetCountersValue` | `Number` |
| `DotnetCountersMuted` | `Comment` |
| `DotnetCountersRunning` | `DiagnosticOk` |
| `DotnetCountersPaused` | `DiagnosticWarn` |
| `DotnetCountersLow` / `Mid` / `High` | `DiagnosticOk` / `DiagnosticWarn` / `DiagnosticError` |

A graph's height is relative to its visible maximum, so its shape is always readable, but its
colour comes from absolute thresholds (`thresholds` in the configuration): a memory graph that
fills its height at a steady 300 MB stays green, and only turns yellow and red as the process uses
10% and 25% of the machine's RAM.

## Limitations

- **One collector per process.** The runtime accepts a single metrics session at a time: if
  another `dotnet-counters`, `dotnet-monitor` or IDE profiler is already collecting from the same process,
  attaching fails with "concurrent sessions are not supported" and the panel says so.
- **About a second of delay.** `dotnet-counters` only writes to a file, in chunks of ~10 KB, so
  samples land with roughly one refresh interval of lag.
- **Temporary file.** The collector writes ~10 KB/s to a temporary file, which is restarted past
  `max_file_size` (a gap of a sample or two) and deleted when collection stops.
- **Thread pool on .NET 9+.** The thread and queue counts are published as up/down counters, which
  `dotnet-counters` reports as deltas; the panel shows work items per second instead. On .NET 8
  all three are shown.

## Development

```sh
git clone --depth 1 https://github.com/nvim-lua/plenary.nvim deps/plenary.nvim
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

The fixtures in `tests/fixtures/` are real `dotnet-counters` output from a .NET 8 app, a .NET 10
app and an ASP.NET Core app, cut mid-array the way the plugin reads them while they are written.

## License

[Apache 2.0](LICENSE)
