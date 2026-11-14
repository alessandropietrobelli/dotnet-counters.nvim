# dotnet-counters.nvim

Live .NET runtime metrics in a Neovim side panel — CPU, memory, GC, thread pool, exceptions and
HTTP latency, with btop-style graphs — right next to the debugger.

<!-- panvimdoc-ignore-start -->

![dotnet-counters.nvim while debugging jellyfin: the panel opens with the session, fills with
CPU, memory, GC, exception and HTTP data, pauses with a breakpoint, hides and shows, and closes
when the session stops](assets/demo.gif)

<sub>Recorded while debugging [jellyfin](https://github.com/jellyfin/jellyfin) under netcoredbg,
with a curl loop calling a few endpoints. The demo is a script:
[`assets/demo.tape`](assets/demo.tape).</sub>

<!-- panvimdoc-ignore-end -->

The panel opens by itself when an [nvim-dap](https://github.com/mfussenegger/nvim-dap) session
starts a .NET process, shows when the debugger has paused it, and closes when the last session ends.
It can also attach to any running .NET process, debugger or not, and follow several at once: an API
and its worker, debugged together, each keep their own graphs.

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
- **Your own meters** show up too: add their provider to `counters`, e.g.
  `"System.Runtime,Microsoft.AspNetCore.Hosting,MyCompany.Orders"`. See [Custom counters](#custom-counters).
- **CPU** is a percentage of the whole machine (all cores), like the .NET 8 counter and Task Manager.
- **While the debugger is stopped** the process is suspended, so the graphs pause with it.
- **Several processes** are collected at once, one `dotnet-counters` each. The panel shows one, with
  the others listed under its header; `<Tab>` switches. Every debug session adds its process, a
  session that ends takes its own away, and the process that stops at a breakpoint is shown.

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
| `:DotnetCounters attach [pid]` | Add a process; without a pid, pick one from `dotnet-counters ps`. One already collected is shown |
| `:DotnetCounters next` / `prev` | Show the next or previous process collected |
| `:DotnetCounters detach` | Stop collecting from the process shown, keep its last data on screen |
| `:DotnetCounters detach all` | Stop collecting from every process |
| `:DotnetCounters reset` | Clear history, peaks and totals of the process shown |
| `:DotnetCounters open` / `close` | Open or close the panel |

In the panel, `q` closes it, `r` resets the history of the process shown, and `<Tab>` / `<S-Tab>`
show the next or previous process. Processes that stopped leave the list when another one starts
being collected. A process you attached by hand stays collected when a debug session that attached
to it ends.

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
  -- Counters of providers other than System.Runtime and Microsoft.AspNetCore.Hosting (your own
  -- meters, added to `counters`) go to the Custom section, one line per tag set with a sparkline
  custom = {
    -- Tag sets shown per instrument, the first ones seen; the others are counted in a
    -- "+N more" line
    max_tag_sets = 5,
    -- Instruments that get a full graph instead of a line, e.g. { "orders.processed" }
    graphs = {},
  },
  dap = {
    -- Attach and open the panel when a debug session of one of these adapters starts a process
    enabled = true,
    adapters = { "coreclr", "netcoredbg" },
    -- When a debug session ends, take its process off the panel, and close the panel once none
    -- is still collected (those stopped go too); false keeps it there, stopped, with its last data
    close_on_exit = true,
    -- Show the process that stops at a breakpoint, with several debugged at once
    follow = true,
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

### Custom counters

Every provider in `counters` other than `System.Runtime` and `Microsoft.AspNetCore.Hosting` goes
to a Custom section at the bottom of the panel: your own `System.Diagnostics.Metrics` meters, or
built-in ones the panel has no section for, such as `Microsoft.AspNetCore.Server.Kestrel` or
`System.Net.Http`. Counters of `System.Runtime` and `Microsoft.AspNetCore.Hosting` that the panel
has no row for (JIT, heap fragmentation…) are not shown.

With `custom = { max_tag_sets = 2 }`:

```
Custom ─────────────────────────────────────
orders.duration
  region=us            ▆█▇█▇█▇▆█▇ p95 275 ms
  region=asia          ██▇██▇███▇ p95 276 ms
  +1 more
orders.queue.length    ▄▃▆▇▃██▄▃▆         15
orders.payload.size    █▇▇▇█▆██▇▇   115 KB/s
orders.processed
  region=us            ▇█▄▇▇▄▇▇█▄       11/s
  region=asia          █▇█▄█▅██▇█       15/s
  +1 more
```

- **One line per instrument and tag set**, with the last value and a sparkline of the recent
  ones. An instrument with tags gets its name on a line of its own, and each tag set
  (`region=eu,status=ok`) is shortened with `…` when it does not fit.
- **`custom.max_tag_sets`** tag sets are shown per instrument, the first ones seen; the others are
  counted in a `+N more` line.
- **Units** come from the suffix `dotnet-counters` adds to the name: `By` reads as bytes, `s`,
  `ms`, `us` and `ns` as durations, `%` as a percentage, `{order}` as a plain number; any other
  unit is written after the number. A counter (`/ 1 sec`, or `/ 2 sec` with `refresh_interval = 2`)
  is shown per second, and as 0 in a sample where nothing was counted.
- **Histograms** show their 95th percentile, and 0 in a sample where nothing was recorded.
- **Up/down counters** are reported by `dotnet-counters` as the change since the last sample (see
  Limitations): to see a level, such as a queue length, publish an observable gauge.
- **`custom.graphs`** lists instrument names (without the unit, e.g. `orders.processed`) that get
  a full graph instead of a line, one per tag set. Their graphs have no thresholds.

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
- **The cost grows with each process.** Every process collected runs its own `dotnet-counters`
  and writes its own temporary file, so three services debugged together cost three times one.
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

## See also

Two more plugins for .NET in Neovim, by the same author:

- [dotnet-tree.nvim](https://github.com/alessandropietrobelli/dotnet-tree.nvim) — a .NET solution explorer, as a neo-tree source: solution folders, projects, references and packages the way the solution declares them
- [nuget.nvim](https://github.com/alessandropietrobelli/nuget.nvim) — a NuGet package manager: browse, update, consolidate and audit the packages of the whole solution in one window

## Trademarks

dotnet-counters.nvim is an independent project. It is not affiliated with, endorsed or sponsored by
Microsoft or the .NET Foundation. It runs Microsoft's `dotnet-counters` tool, whose name it takes to
say what it works with; .NET and ASP.NET Core are trademarks of their respective owners.

## License

[Apache 2.0](LICENSE)
