import os, strutils

import posix
import symbol_map, mi_transformer, process
import glob

const BUFFER_SIZE = 8192

proc main() =
  var debugger = "gdb"
  var gdbPath = ""
  var programPath = ""
  var symbolsPath = ""
  var gdbArgs: seq[string] = @[]
  var debugMode = false

  # Parse arguments
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--gdb":
      debugger = "gdb"
      gdbPath = "gdb"
    elif arg == "--lldb":
      debugger = "lldb"
      for lldb_mi in walkGlob("~/.vscode/extensions/ms-vscode.cpptools-*/**/lldb-mi".expandTilde):
        gdbPath = lldb_mi
        stderr.writeLine("Found lldb-mi: " & gdbPath)
        stderr.flushFile()
        break
      if gdbPath == "":
        gdbPath = "lldb-mi"
    elif arg == "--gdb-path":
      inc i
      if i < args.len:
        gdbPath = args[i].expandTilde
    elif arg == "--lldb-path":
      inc i
      if i < args.len:
        gdbPath = args[i].expandTilde
    elif arg == "--debug":
      debugMode = true
    elif arg.startsWith("--"):
      gdbArgs.add(arg)
    else:
      if arg.endsWith(".json"):
        symbolsPath = arg
      elif programPath == "" and fileExists(arg):
        programPath = arg
        gdbArgs.add(arg)
      else:
        gdbArgs.add(arg)
    inc i

  stderr.writeLine("Nim Debugger MI Proxy")
  stderr.writeLine("Input args: " & args.join(" "))
  stderr.flushFile()

  # Load symbol map
  let sm = newSymbolMap()
  if symbolsPath != "":
    if debugMode:
      stderr.writeLine("Loading custom symbol map from: " & symbolsPath)
    discard sm.loadFromFile(symbolsPath)
  elif programPath != "":
    if debugMode:
      stderr.writeLine("Loading symbols from: " & programPath)
    discard sm.loadFromBinary(programPath)

  # Build GDB command
  if debugMode:
    stderr.writeLine("Starting Debugger: " & gdbPath & " " & gdbArgs.join(" "))

  # Start GDB process
  var p: Process
  try:
    p = newProcess(gdbPath, gdbArgs)
  except Exception as e:
    stderr.writeLine("Failed to start Debugger: " & e.msg)
    quit(1)

  if not p.isRunning:
    stderr.writeLine("Failed to start Debugger process (not running)!")
    quit(1)

  if debugMode:
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
            if debugMode:
              stderr.writeLine("Dynamically loading symbols from: " & path)
            discard sm.loadFromBinary(path)
      
      try:
        if debugMode:
          stderr.writeLine("Input: " & rawLine)
        let transformed = transformInput(rawLine, sm)
        if debugMode and transformed != rawLine:
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
          let transformed = transformOutput(rawLine, sm, debug = debugMode)
          if debugMode:
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