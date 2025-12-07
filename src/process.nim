
{.compile: "process.c".}
import sequtils, sugar, os, strutils, posix

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
# We might not strictly need the polling readers if we use selectors, but we include them for completeness if needed
proc read_from_output(handle: ptr ProcessHandle, buffer: cstring, buffer_size: cint, timeout_ms: cint): cint {.importc.}
proc read_from_error(handle: ptr ProcessHandle, buffer: cstring, buffer_size: cint, timeout_ms: cint): cint {.importc.}

type
  Process* = ref object
    handle*: ptr ProcessHandle

proc newProcess*(cmd: string, args: openArray[string]): Process =
  # Convert args to C format (null-terminated array of strings, ending with NULL)
  # process.c expects `char** args`.
  # We need to construct a seq of cstrings, and then pass the address of the first element.
  # The array must be null-terminated? `execvp` expects a NULL terminated array.
  # wrapper in tmp.nim:
  # var all_args = @[cmd] & @args
  # var all_args_cstring = all_args.map(it => it.cstring)
  # let handle = start_process(cmd.cstring, all_args_cstring[0].addr)
  
  # Wait, one detail: `all_args_cstring` needs to be NULL terminated for execvp.
  # The tmp.nim implementation:
  #   var all_args_cstring = all_args.map(it => it.cstring)
  # It doesn't explicitly add `nil`.
  # `seq` in Nim might not be implicitly NULL terminated in a way C expects for `char**`.
  # However, `process.c` calls `execvp(cmd, args)`. 
  # If `tmp.nim` worked, maybe I should stick to it. But `map` returns a seq. 
  # If I pass `addr` of 0th element, I get `char**`. But it needs to end with NULL.
  # `tmp.nim` might have been lucky or strict Nim memory layout is coincidentally zero after the seq buffer? Unlikely.
  # I should verify `process.c`.
  # `execvp` iterates args until NULL.
  # I will add `cstring(nil)` to be safe.
  
  var all_args = @[cmd] & @args
  var cargs = newSeq[cstring](all_args.len + 1)
  for i, arg in all_args:
    cargs[i] = cstring(arg)
  cargs[all_args.len] = nil
  
  let handle = start_process(cmd.cstring, addr cargs[0])
  if handle == nil:
    raise newException(IOError, "Failed to start process: " & cmd)
  
  result = Process(handle: handle)

proc write*(p: Process, data: string): int =
  if p.handle == nil: return -1
  let written = write_to_process(p.handle, data.cstring, data.len.cint)
  return written

proc close*(p: Process) =
  if p.handle != nil:
    close_process(p.handle)
    p.handle = nil

proc isRunning*(p: Process): bool =
  if p.handle == nil: return false
  return is_running(p.handle)

proc pid*(p: Process): int =
  if p.handle != nil: return p.handle.pid
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

# IO Accessors for Selectors
proc inputHandle*(p: Process): cint = p.handle.input_fd
proc outputHandle*(p: Process): cint = p.handle.output_fd
proc errorHandle*(p: Process): cint = p.handle.error_fd

# Direct read helpers (without internal polling)
# Since the FDs are non-blocking, we can just read.
proc readOutputDirect*(p: Process, buffer: pointer, len: int): int =
  return posix.read(p.handle.output_fd, buffer, len)

proc readErrorDirect*(p: Process, buffer: pointer, len: int): int =
  return posix.read(p.handle.error_fd, buffer, len)