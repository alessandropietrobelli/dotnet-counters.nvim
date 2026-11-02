# Contributing

Thanks for taking a look. Issues and pull requests are both welcome.

## Reporting a bug

Please include:

- Neovim version (`nvim --version`)
- The output of `:checkhealth dotnet-counters`
- The target framework of the app (`net8.0`, `net9.0`, `net10.0`…) and whether it is an ASP.NET Core
  app — .NET 8 and .NET 9+ publish different counters, and the HTTP section only exists for web apps
- How the panel was started: by an nvim-dap session (and the adapter's `type` in your configuration)
  or with `:DotnetCounters attach`
- For a wrong or missing number, the raw output the plugin reads. Run this against the process for a
  few seconds and attach the file:

  ```sh
  dotnet-counters collect --process-id <pid> --format json --output capture.json \
    --refresh-interval 1 --counters System.Runtime,Microsoft.AspNetCore.Hosting
  ```

  Sanitise it first: the HTTP counters carry your routes in their tags. A retyped or reformatted
  fragment usually hides the bug — the parser reads the file exactly as `dotnet-counters` writes it.

The most common reports, and what they usually are:

- *"The panel doesn't open when I debug"*: the adapter's `type` is not in `dap.adapters` (the default
  is `{ "coreclr", "netcoredbg" }`), or the plugin is loaded only by a command or a key and so never
  hooked into nvim-dap. Load it on `VeryLazy`, as the README shows.
- *"concurrent sessions are not supported"*: something else — another `dotnet-counters`,
  `dotnet-monitor` or an IDE profiler — is already collecting from that process. The runtime allows
  one session at a time.

## Development setup

Point your plugin manager at a local checkout instead of the GitHub repo. With lazy.nvim:

```lua
{ "alessandropietrobelli/dotnet-counters.nvim", dir = "~/src/dotnet-counters.nvim", event = "VeryLazy", opts = {} }
```

The quickest loop does not need the debugger: start any .NET app, then `:DotnetCounters attach` and
pick it. Restart Neovim (or `:Lazy reload dotnet-counters.nvim`) to pick up changes.

## Before opening a pull request

```sh
stylua lua/ plugin/ tests/   # formatting is enforced in CI
luacheck lua/ plugin/ tests/
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

The suite needs [plenary.nvim](https://github.com/nvim-lua/plenary.nvim): clone it into `deps/`, or it
is picked up from lazy.nvim's install directory. CI additionally loads every module and runs the
suite against Neovim stable and nightly.

Keep `README.md` in sync when you change behaviour, commands or configuration defaults — the
`setup()` block there mirrors `default_config` in `lua/dotnet-counters/init.lua`.

`doc/dotnet-counters.txt`, the `:help` file, is generated from `README.md` with
[panvimdoc](https://github.com/kdheepak/panvimdoc): when you change the README, regenerate it and
commit both together. With [pandoc](https://pandoc.org) installed, from a panvimdoc checkout:

```sh
./panvimdoc.sh --project-name dotnet-counters --input-file /path/to/README.md \
  --vim-version "Neovim >= 0.10" --description "Live .NET runtime metrics in a side panel, next to the debugger" \
  --toc true --treesitter true --ignore-rawblocks true --shift-heading-level-by -1
```

Parts of the README that make no sense in `:help` (the demo) sit between
`<!-- panvimdoc-ignore-start -->` and `<!-- panvimdoc-ignore-end -->`.

## Code layout

| Path | Responsibility |
|---|---|
| `lua/dotnet-counters/init.lua` | `setup`, configuration, attach/detach, the nvim-dap hooks |
| `lua/dotnet-counters/collector.lua` | runs `dotnet-counters collect`, tails its output file, rotates it |
| `lua/dotnet-counters/parser.lua` | cuts complete events out of the JSON while it is still being written |
| `lua/dotnet-counters/metrics.lua` | maps .NET 8 and .NET 9+ counters onto one set of metrics; ticks, history, totals |
| `lua/dotnet-counters/render.lua` | panel lines, graphs and highlights — pure, no window access |
| `lua/dotnet-counters/panel.lua` | the side window and its highlight groups |
| `lua/dotnet-counters/health.lua` | `:checkhealth dotnet-counters` |
| `plugin/dotnet-counters.lua` | the `:DotnetCounters` command |

`metrics.lua` is where most contributions will land: a counter that is not mapped yet, a new runtime
that renames one, a provider worth showing. Every counter is a handler in `HANDLERS`, keyed by its
name without the unit suffix.

### Fixtures

`tests/fixtures/` holds real `dotnet-counters` output — a .NET 8 app, a .NET 10 app and an
ASP.NET Core app — cut mid-array, which is how the plugin sees the file while the collector is still
writing it. When a fix depends on what a runtime actually publishes, add a capture rather than a
hand-written event: the counter names, units and tag formats are exactly what tends to differ.

## Scope

This is a *live metrics panel*. Things that belong here: reading runtime and ASP.NET Core counters
and showing them while the app runs. Things that do not: traces and CPU profiles (`dotnet-trace`),
memory dumps (`dotnet-dump`), stepping and breakpoints (`nvim-dap`).

## License

By contributing you agree that your contributions are licensed under the [Apache-2.0](LICENSE)
license that covers this project.
