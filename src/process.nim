# process.nim
when defined(windows):
  {.compile: "process_windows.c".}
  import winlean
else:
  {.compile: "process.c".}

when defined(windows):
  type
    ProcessHandle* = object
      pid*: DWORD
      hProcess*: Handle
      input_fd*: Handle
      output_fd*: Handle
      error_fd*: Handle
else:
  type
    ProcessHandle* = object
      pid*: cint
      input_fd*: cint
      output_fd*: cint
      error_fd*: cint

proc start_process(cmd: cstring, args: ptr cstring): ptr ProcessHandle {.importc.}
proc close_process(handle: ptr ProcessHandle) {.importc.}
proc is_running(handle: ptr ProcessHandle): bool {.importc.}
proc write_to_process(handle: ptr ProcessHandle, data: cstring, length: cint): cint {.importc.}
proc read_from_output(handle: ptr ProcessHandle, buffer: cstring, buffer_size: cint, timeout_ms: cint): cint {.importc.}
proc read_from_error(handle: ptr ProcessHandle, buffer: cstring, buffer_size: cint, timeout_ms: cint): cint {.importc.}
proc read_available(handle: ptr ProcessHandle, buffer: cstring, buffer_size: cint, timeout_ms: cint, source: ptr cint): cint {.importc.}

type
  Process* = ref object
    handle*: ptr ProcessHandle

proc newProcess*(cmd: string, args: openArray[string]): Process =
  # Convert args to C format (null-terminated array)
  when defined(windows):
    var cargs : seq[cstring] = newSeq[cstring](args.len + 1)
    for i, arg in args:
      cargs[i] = cstring(arg)
    cargs[args.len] = nil
  else:
    var cargs : seq[cstring] = newSeq[cstring](args.len + 2)
    cargs[0] = cstring(cmd)
    for i, arg in args:
      cargs[i + 1] = cstring(arg)
    cargs[args.len + 1] = nil
  
  let handle = start_process(cmd.cstring, addr cargs[0])
  if handle == nil:
    raise newException(IOError, "Failed to start process: " & cmd)
  
  result = Process(handle: handle)

proc write*(p: Process, data: string): int =
  if p.handle == nil: return -1
  let written = write_to_process(p.handle, data.cstring, data.len.cint)
  if written < 0:
    raise newException(IOError, "Failed to write to process")
  return written

proc close*(p: Process) =
  if p.handle != nil:
    close_process(p.handle)
    p.handle = nil

proc isRunning*(p: Process): bool =
  if p.handle == nil: return false
  return is_running(p.handle)

proc pid*(p: Process): int =
  if p.handle != nil:
    return p.handle.pid.int
  return 0

proc readOutput*(p: Process, timeoutMs: int): string =
  var buffer = newString(4096)
  let bytesRead = read_from_output(p.handle, buffer.cstring, buffer.len.cint, timeoutMs.cint)
  if bytesRead > 0:
    result = buffer[0..<bytesRead]
  else:
    result = ""

proc readError*(p: Process, timeoutMs: int): string =
  var buffer = newString(4096)
  let bytesRead = read_from_error(p.handle, buffer.cstring, buffer.len.cint, timeoutMs.cint)
  if bytesRead > 0:
    result = buffer[0..<bytesRead]
  else:
    result = ""


when isMainModule:
  # Example usage
  let p = newProcess("cmd", @["help"])
  echo "Started process with PID: ", p.pid()
  let output = p.readOutput(8000)
  echo "Output: ", output
  p.close()