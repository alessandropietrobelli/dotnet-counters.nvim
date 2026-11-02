# The README demo, as a script. Regenerate it with:
#
#   brew install vhs                  # or see github.com/charmbracelet/vhs
#   export DEMO_REPO=~/src/jellyfin   # any ASP.NET Core app; see below
#   export NETCOREDBG=/path/to/netcoredbg
#   vhs assets/demo.tape
#
# Recorded against a jellyfin checkout, run under netcoredbg: a real ASP.NET
# Core server that starts in a few seconds and has public endpoints to call.
# Build it first:
#
#   git clone --depth 1 https://github.com/jellyfin/jellyfin "$DEMO_REPO"
#   cd "$DEMO_REPO" && dotnet build Jellyfin.Server -c Debug
#
# A curl loop in the background calls a few endpoints while the demo runs, one
# of them without credentials (401), so the HTTP section has routes to show.
#
# assets/demo-config.lua is the Neovim configuration used here: nvim-dap with
# netcoredbg, and this plugin. Copy it to ~/.config/dotnet-counters-demo/init.lua.
# jellyfin keeps its data in $DEMO_DATA (default: a cache directory).
#
# VHS emits a frame when the screen changes, so a long Sleep over a still screen
# shortens in the recording. Tune the Sleeps by looking at the output.

Output "assets/demo.gif"
Set Shell "zsh"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 16
Set Width 1600
Set Height 1080
Set Theme "TokyoNight"
Set Padding 12

Hide
Type `cd "$DEMO_REPO" && clear`
Enter
# Traffic for the HTTP section; it fails quietly until jellyfin is up
Type `(while true; do for u in /System/Info/Public /health /System/Ping /Branding/Configuration /Users; do curl -s -o /dev/null localhost:8096$u; done; sleep 0.05; done) &! LOAD=$!; clear`
Enter
Type "NVIM_APPNAME=dotnet-counters-demo nvim +95 Jellyfin.Api/Controllers/SystemController.cs"
Enter
Sleep 4s
Show

# --- 1. start debugging: the panel opens with the process -------------------
Sleep 1500ms
Type " r"
Sleep 20s

# --- 2. a breakpoint: the process is suspended, and so are the graphs --------
Type " b"
Sleep 5s

# --- 3. remove it and carry on ------------------------------------------------
Type " b"
Sleep 700ms
Type " r"
Sleep 6s

# --- 4. the panel comes and goes ---------------------------------------------
Type " m"
Sleep 2s
Type " m"
Sleep 4s

# --- 5. stop: the panel closes with the session --------------------------------
Type " s"
Sleep 3s

Hide
Type ":qa!"
Enter
Type "kill $LOAD"
Enter
