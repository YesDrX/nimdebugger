import os, strutils, streams, posix
import symbol_map, mi_transformer, process

const BUFFER_SIZE = 8192

proc main() =
  var gdbPath = "gdb"
  var programPath = ""
  var symbolsPath = ""
  var gdbArgs: seq[string] = @[]
  var debugMode = false  # Verbose logging flag

  # Parse arguments
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--gdb-path":
      inc i
      if i < args.len:
        gdbPath = args[i]
    elif arg == "--debug":
      debugMode = true
    elif arg.startsWith("--"):
      gdbArgs.add(arg)
    else:
      # Heuristic: json = symbols, executable = program
      if arg.endsWith(".json"):
        symbolsPath = arg
      elif programPath == "" and fileExists(arg):
        programPath = arg
        gdbArgs.add(arg)  # GDB will load it; harmless if VSCode also sends -file-exec-and-symbols
      else:
        gdbArgs.add(arg)
    inc i

  # Load symbol map if we have an executable
  let sm = newSymbolMap()
  if symbolsPath != "":
    if debugMode:
      stderr.writeLine("Loading custom symbol map from: " & symbolsPath)
    sm.loadFromJson(symbolsPath)
  elif programPath != "": # Fallback to loading from executable if no custom map specified
    if debugMode:
      stderr.writeLine("Loading symbols from: " & programPath)
    sm.loadFromNm(programPath)

  # Build GDB command
  if debugMode:
    stderr.writeLine("Starting GDB: " & gdbPath & " " & gdbArgs.join(" "))

  # Start GDB process using custom Process
  var p: Process
  try:
    p = newProcess(gdbPath, gdbArgs)
  except Exception as e:
    stderr.writeLine("Failed to start GDB: " & e.msg)
    quit(1)

  if not p.isRunning:
    stderr.writeLine("Failed to start GDB process (not running)!")
    quit(1)

  if debugMode:
    stderr.writeLine("GDB PID: " & $p.pid)
    stderr.writeLine("Proxy started. Entering I/O loop...")
  
  # Manual polling loop
  var pfd: array[1, TPollfd]
  pfd[0].fd = 0 # Stdin
  pfd[0].events = POLLIN
  
  var inBuffer = ""
  var outBuffer = ""
  
  while true:
    # 1. Check stdin
    let ret = poll(addr pfd[0], 1, 10) # 10ms timeout
    if ret > 0 and (pfd[0].revents and POLLIN) != 0:
       # Read stdin
       var buf = newString(BUFFER_SIZE)
       let n = read(0, addr buf[0], BUFFER_SIZE)
       if n <= 0:
         # stderr.writeLine("stdin closed — shutting down")
         p.close()
         quit(0)
         
       let chunk = buf[0 ..< n]
       inBuffer.add(chunk)
       
       # Process stdin lines
       while true:
         let nlPos = inBuffer.find('\n')
         if nlPos == -1: break
         let rawLine = inBuffer[0 ..< nlPos]
         inBuffer = inBuffer[(nlPos + 1) .. ^1]
         if rawLine.len == 0: continue
         
         # Hook for loading symbols dynamically
         if rawLine.startsWith("-file-exec-and-symbols"):
            let parts = rawLine.split(maxsplit=1)
            if parts.len == 2:
              let path = parts[1].strip
              if fileExists(path):
                if debugMode:
                  stderr.writeLine("Dynamically loading symbols from: " & path)
                sm.loadFromNm(path)

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

    # 2. Check GDB Output
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
             let transformed = transformOutput(rawLine, sm, debugMode)
             # The original instruction had a syntax error here. Assuming the intent was to add a debug log if debugMode is true.
             if debugMode:
               stderr.writeLine("Transformed Output: " & transformed)
             stdout.write(transformed & "\n")
             stdout.flushFile()
          except Exception as e:
             stderr.writeLine("Error transforming output: " & e.msg)
             stdout.write(rawLine & "\n")
             stdout.flushFile()

    # 3. Check GDB Stderr
    let gdbErr = p.readError(0)
    if gdbErr.len > 0:
       stderr.write(gdbErr)
       stderr.flushFile()

    if not p.isRunning:
      stderr.writeLine("GDB Exited")
      quit(0)

  p.close()

main()