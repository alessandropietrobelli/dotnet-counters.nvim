# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version stays below `1.0.0`, breaking changes to configuration and
commands may land in a minor release; they will always be listed here.

## [Unreleased]

### Fixed

- With two .NET debug sessions running at once (an API and a worker, say), the
  panel only reacts to the session whose process it is collecting from. Ending
  the other session no longer stops the metrics and closes the panel, and a
  breakpoint hit in the other process no longer shows this one as paused. A
  process attached by hand with `:DotnetCounters attach` is no longer stopped
  when a debug session ends
  ([#1](https://github.com/alessandropietrobelli/dotnet-counters.nvim/issues/1)).

## [0.1.1] - 2026-11-02

No change to the plugin's code.

### Added

- `:help dotnet-counters`: the help file, generated from the README with panvimdoc, so the
  documentation is there inside Neovim. Sections have short tags, such as
  `dotnet-counters-usage` and `dotnet-counters-configuration`.
- A "See also" section pointing to dotnet-tree.nvim and nuget.nvim.

## [0.1.0] - 2026-11-02

First public release.

### Added

- A side panel with live .NET runtime metrics, drawn as btop-style graphs:
  CPU (as a share of the whole machine), working set, GC heap and committed
  memory, allocation rate and time spent in the GC; GC collections per
  generation; thread pool and lock contention; exceptions per second, with a
  running count per exception type.
- ASP.NET Core: requests in flight and the p95 latency of every route, with its
  status code coloured (4xx, 5xx).
- nvim-dap integration: the panel opens when a debug session of a `coreclr` or
  `netcoredbg` adapter starts a process, says when the debugger has paused it,
  and closes when the session ends.
- `:DotnetCounters attach [pid]` for any running .NET process, with or without a
  debugger; without a pid, a picker over `dotnet-counters ps`.
- `:DotnetCounters toggle`, `open`, `close`, `detach` and `reset`; `q` and `r` in
  the panel.
- Both runtime generations: .NET 8 EventCounters and .NET 9+ `System.Runtime`
  meters are mapped onto the same metrics.
- Graph heights relative to the visible maximum, colours from absolute
  thresholds (`thresholds`), so a steady value is not red for being at its own
  top.
- Highlight groups linked to standard ones, and `:checkhealth dotnet-counters`.

### Known limitations

- The runtime accepts one metrics session per process: attaching fails while
  another `dotnet-counters`, `dotnet-monitor` or IDE profiler is collecting.
- Samples land about one refresh interval late: `dotnet-counters` writes its
  output in chunks.
- On .NET 9+ the thread pool's thread and queue counts are reported as deltas,
  so the panel shows work items per second instead.

[Unreleased]: https://github.com/alessandropietrobelli/dotnet-counters.nvim/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alessandropietrobelli/dotnet-counters.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alessandropietrobelli/dotnet-counters.nvim/releases/tag/v0.1.0
