import os, strutils

import posix
import symbol_map, mi_transformer, process
import glob

const BUFFER_SIZE = 8192

type
  Argument = object
    debugger    : string = "gdb" # or lldb
    gdbPath     : string = ""
    programPath : string = ""
    symbolsPath : string = ""
    gdbArgs     : seq[string]
    debugMode   : bool = false


proc parseArgs(args: seq[string]): Argument =
  let quotes = {'"', '\'', ' ', '`'}
  var i = 0
  result.gdbPath = findExe("gdb")

  while i < args.len:
    let arg = args[i]
    if arg == "--gdb" or arg.startswith("--gdb=") or arg.startswith("--gdb:"):
      result.debugger = "gdb"
      if arg != "--gdb":
        result.gdbPath = arg[5 .. ^1].strip(chars = quotes).expandTilde
    elif arg == "--lldb" or arg.startswith("--lldb=") or arg.startswith("--lldb:"):
      result.debugger = "lldb"
      if arg == "--lldb":
        for lldb_mi in walkGlob("~/.vscode/extensions/ms-vscode.cpptools-*/**/lldb-mi".expandTilde):
          result.gdbPath = lldb_mi
          break
        if result.gdbPath.len == 0:
          let lldbPath = findExe("lldb-mi")
          if lldbPath.len > 0:
            result.gdbPath = lldbPath
        if result.gdbPath.len == 0:
          stderr.writeLine("Failed to find lldb-mi, did you install ms-vscode.cpptools extension?")
          quit(1)
      else:
        result.gdbPath = arg[6 .. ^1].strip(chars = quotes).expandTilde
    elif arg == "--gdb-path" or arg.startswith("--gdb-path=") or arg.startswith("--gdb-path:"):
      result.debugger = "gdb"
      if arg == "--gdb-path":
        inc i
        if i < args.len:
          result.gdbPath = args[i].expandTilde
      else:
        result.gdbPath = arg[11 .. ^1].strip(chars = quotes).expandTilde
    elif arg == "--lldb-path" or arg.startswith("--lldb-path=") or arg.startswith("--lldb-path:"):
      result.debugger = "lldb"
      if arg == "--lldb-path":
        inc i
        if i < args.len:
          result.gdbPath = args[i].expandTilde
      else:
        result.gdbPath = arg[12 .. ^1].strip(chars = quotes)
    elif arg == "--debug":
      result.debugMode = true
    elif arg.startsWith("--"):
      result.gdbArgs.add(arg)
    else:
      if arg.endsWith(".json"):
        result.symbolsPath = arg
      elif result.programPath == "" and fileExists(arg):
        result.programPath = arg
        result.gdbArgs.add(arg)
      else:
        result.gdbArgs.add(arg)
    inc i


proc main() =
  let cmd_args = commandLineParams()
  let arg = parseArgs(cmd_args)

  stderr.writeLine("Nim Debugger MI Proxy")
  stderr.writeLine("Input args: " & cmd_args.join(" "))
  stderr.writeLine("Parsed args: " & $arg)
  stderr.flushFile()

  # Load symbol map
  let sm = newSymbolMap()
  if arg.symbolsPath != "":
    stderr.writeLine("Loading custom symbol map from: " & arg.symbolsPath)
    discard sm.loadFromFile(arg.symbolsPath)
  elif arg.programPath != "":
    stderr.writeLine("Loading symbols from: " & arg.programPath)
    discard sm.loadFromBinary(arg.programPath)

  # Build GDB command
  stderr.writeLine("Starting Debugger: " & arg.gdbPath & " " & arg.gdbArgs.join(" "))

  # Start GDB process
  var p: Process
  try:
    p = newProcess(arg.gdbPath, arg.gdbArgs)
  except Exception as e:
    stderr.writeLine("Failed to start Debugger: " & e.msg)
    quit(1)

  if not p.isRunning:
    stderr.writeLine("Failed to start Debugger process (not running)!")
    quit(1)

  stderr.writeLine("Debugger PID: " & $p.pid)
  stderr.writeLine("Proxy started. Entering I/O loop...")
  
  # UNIFIED LOOP FOR BOTH PLATFORMS
  var inBuffer = ""
  var outBuffer = ""
  var pfd: array[1, TPollfd]
  pfd[0].fd = 0
  pfd[0].events = POLLIN
  
  while true:
    # 1. Try to read stdin
    # Unix: Use poll
    let ret = poll(addr pfd[0], 1, 10)
    if ret > 0 and (pfd[0].revents and POLLIN) != 0:
      var buf = newString(BUFFER_SIZE)
      let n = read(0, addr buf[0], BUFFER_SIZE)
      if n > 0:
        inBuffer.add(buf[0 ..< n])
      elif n <= 0:
        p.close()
        quit(0)
    
    # 2. Process stdin lines
    while true:
      let nlPos = inBuffer.find('\n')
      if nlPos == -1: break
      let rawLine = inBuffer[0 ..< nlPos]
      inBuffer = inBuffer[(nlPos + 1) .. ^1]
      if rawLine.len == 0: continue
      
      if rawLine.startsWith("-file-exec-and-symbols"):
        let parts = rawLine.split(maxsplit=1)
        if parts.len == 2:
          let path = parts[1].strip
          if fileExists(path):
            if arg.debugMode:
              stderr.writeLine("Dynamically loading symbols from: " & path)
            discard sm.loadFromBinary(path)
      
      try:
        if arg.debugMode:
          stderr.writeLine("Input: " & rawLine)
        let transformed = transformInput(rawLine, sm)
        if arg.debugMode and transformed != rawLine:
          stderr.writeLine("Transformed Input: " & transformed)
        discard p.write(transformed & "\n")
      except Exception as e:
        stderr.writeLine("Error transforming input: " & e.msg)
        discard p.write(rawLine & "\n")
    
    # 3. Check GDB Output
    let gdbOut = p.readOutput(10)
    if gdbOut.len > 0:
      outBuffer.add(gdbOut)
      while true:
        let nlPos = outBuffer.find('\n')
        if nlPos == -1: break
        let rawLine = outBuffer[0 ..< nlPos]
        outBuffer = outBuffer[(nlPos + 1) .. ^1]
        if rawLine.len == 0:
          stdout.write("\n"); stdout.flushFile(); continue
        
        try:
          let transformed = transformOutput(rawLine, sm, debug = arg.debugMode)
          if arg.debugMode:
            stderr.writeLine("Transformed Output: " & transformed)
          stdout.write(transformed & "\n")
          stdout.flushFile()
        except Exception as e:
          stderr.writeLine("Error transforming output: " & e.msg)
          stdout.write(rawLine & "\n")
          stdout.flushFile()
    
    # 4. Check GDB Stderr
    let gdbErr = p.readError(0)
    if gdbErr.len > 0:
      stderr.write(gdbErr)
      stderr.flushFile()
    
    # 5. Check if process is still running
    if not p.isRunning:
      stderr.writeLine("GDB Exited")
      quit(0)
    
    # 6. Small sleep
    sleep(10)
  
  p.close()

main()