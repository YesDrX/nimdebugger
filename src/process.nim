# process.nim
when defined(windows):
  {.compile: "process_windows.c".}
  {.passC: "-D_WIN32 -DWIN32_LEAN_AND_MEAN".}
else:
  {.compile: "process.c".}

when defined(windows):
  import winlean
  # Define Windows API constants and types
  type
    WINBOOL = int32
    LPOVERLAPPED = pointer
  
  # Declare Windows API functions with correct signatures
  proc ReadFile(hFile: Handle, lpBuffer: pointer, nNumberOfBytesToRead: DWORD,
                lpNumberOfBytesRead: ptr DWORD, lpOverlapped: LPOVERLAPPED): WINBOOL {.stdcall, dynlib: "kernel32", importc: "ReadFile".}
  
  proc WriteFile(hFile: Handle, lpBuffer: pointer, nNumberOfBytesToWrite: DWORD,
                 lpNumberOfBytesWritten: ptr DWORD, lpOverlapped: LPOVERLAPPED): WINBOOL {.stdcall, dynlib: "kernel32", importc: "WriteFile".}
  
  proc FlushFileBuffers(hFile: Handle): WINBOOL {.stdcall, dynlib: "kernel32", importc: "FlushFileBuffers".}
  
  proc GetExitCodeProcess(hProcess: Handle, lpExitCode: ptr DWORD): WINBOOL {.stdcall, dynlib: "kernel32", importc: "GetExitCodeProcess".}
  
  proc WaitForSingleObject(hHandle: Handle, dwMilliseconds: DWORD): DWORD {.stdcall, dynlib: "kernel32", importc: "WaitForSingleObject".}
  
  proc CloseHandle(hObject: Handle): WINBOOL {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}
  
  const
    STILL_ACTIVE = 259.DWORD
else:
  import posix

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
    when defined(windows):
      return p.handle.pid.int
    else:
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

# IO Accessors for compatibility with existing code
when defined(windows):
  proc inputHandle*(p: Process): Handle = 
    if p.handle != nil: p.handle.input_fd else: Handle(0)
  
  proc outputHandle*(p: Process): Handle = 
    if p.handle != nil: p.handle.output_fd else: Handle(0)
  
  proc errorHandle*(p: Process): Handle = 
    if p.handle != nil: p.handle.error_fd else: Handle(0)
  
  # Direct read helpers for Windows
  proc readOutputDirect*(p: Process, buffer: pointer, len: int): int =
    var bytesRead: DWORD = 0
    if p.handle != nil and p.handle.output_fd != Handle(0):
      let success = ReadFile(p.handle.output_fd, buffer, len.DWORD, addr bytesRead, nil)
      if success != 0:  # WINBOOL success (non-zero means success)
        return bytesRead.int
    return -1
  
  proc readErrorDirect*(p: Process, buffer: pointer, len: int): int =
    var bytesRead: DWORD = 0
    if p.handle != nil and p.handle.error_fd != Handle(0):
      let success = ReadFile(p.handle.error_fd, buffer, len.DWORD, addr bytesRead, nil)
      if success != 0:  # WINBOOL success (non-zero means success)
        return bytesRead.int
    return -1

else:
  proc inputHandle*(p: Process): cint = 
    if p.handle != nil: p.handle.input_fd else: -1
  
  proc outputHandle*(p: Process): cint = 
    if p.handle != nil: p.handle.output_fd else: -1
  
  proc errorHandle*(p: Process): cint = 
    if p.handle != nil: p.handle.error_fd else: -1
  
  # Direct read helpers for Unix
  proc readOutputDirect*(p: Process, buffer: pointer, len: int): int =
    if p.handle != nil:
      return posix.read(p.handle.output_fd, buffer, len)
    return -1
  
  proc readErrorDirect*(p: Process, buffer: pointer, len: int): int =
    if p.handle != nil:
      return posix.read(p.handle.error_fd, buffer, len)
    return -1