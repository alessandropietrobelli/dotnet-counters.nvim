local collector = require("dotnet-counters.collector")

describe("collector failure", function()
  it("is nil when dotnet-counters just ended with the process", function()
    assert.is_nil(collector.failure(0, 0, "Starting a counter session. Press Q to quit.\nFile saved to x.json\n"))
  end)

  it("reads an error line", function()
    assert.equals(
      "Concurrent sessions are not supported.",
      collector.failure(1, 0, "Starting a counter session.\n[ERROR] Concurrent sessions are not supported.  \n")
    )
  end)

  it("reads the innermost exception", function()
    -- What dotnet-counters 9 prints for a pid that is not running
    local output = table.concat({
      "Unhandled exception: System.InvalidOperationException: Failed to start the event pipe session",
      " ---> Microsoft.Diagnostics.NETCore.Client.ServerNotAvailableException: Process 999999 is not running.",
      "   at Microsoft.Diagnostics.NETCore.Client.PidIpcEndpoint.GetDefaultAddress(Int32 pid) in /_/src/x.cs:line 506",
      "   --- End of inner exception stack trace ---",
      "--- End of stack trace from previous location ---",
    }, "\n")
    assert.equals("Process 999999 is not running.", collector.failure(1, 0, output))
    assert.equals(
      "Failed to start the event pipe session",
      collector.failure(
        1,
        0,
        "Unhandled exception: System.InvalidOperationException: Failed to start the event pipe session"
      )
    )
  end)

  it("falls back to the first line, then to the exit", function()
    assert.equals("Something went wrong", collector.failure(2, 0, "\n  Something went wrong \nmore"))
    assert.equals("exited with code 3", collector.failure(3, 0, ""))
    assert.equals("killed by signal 9", collector.failure(0, 9, ""))
  end)
end)
