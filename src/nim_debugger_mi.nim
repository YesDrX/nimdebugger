when not defined(windows):
  import posix

import std/[asyncdispatch, asyncfile, os, strformat, locks,os, strutils, times]
import glob
import symbol_map, mi_transformer, process

const BUFFER_SIZE = 8192

type
  Argument = object
    debugger    : string = "gdb" # or lldb
    gdbPath     : string = ""
    programPath : string = ""
    symbolsPath : string = ""
    gdbArgs     : seq[string]
    debugMode   : bool = false

proc toStdout(line: string, debugStdoutFileName: string = "") =
  if line.len == 0: return
  if debugStdoutFileName.len > 0:
    let file = open(debugStdoutFileName, fmAppend)
    file.writeLine(now().format("yyyyMMddHHmmss") & ": " & line)
    file.close()
  stdout.writeLine(line)
  stdout.flushFile()

proc toStderr(line: string, debugStderrFileName: string = "") =
  if line.len == 0: return
  if debugStderrFileName.len > 0:
    let file = open(debugStderrFileName, fmAppend)
    file.writeLine(now().format("yyyyMMddHHmmss") & ": " & line)
    file.close()
  
  when not defined(windows):
    # somehow stderr on windows is quite easy to get stuck
    stderr.writeLine(line)
    stderr.flushFile()

proc parseArgs(args: seq[string]): Argument =
  let quotes = {'"', '\'', ' ', '`'}
  var i = 0
  result.debugger = "gdb"
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
          toStderr("Failed to find lldb-mi, did you install ms-vscode.cpptools extension?")
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

var
  stdinChann: Channel[string]

proc stdinReader() {.thread.} =
  try:
    while true:
      let line = stdin.readLine()
      if line.len > 0:
        stdinChann.send(line)
      sleep(5)
  except EOFError:
    # VS Code closed the pipe
    stdinChann.send("__EOF__") 
  except Exception as e:
    # Catch crashes
    stdinChann.send("__ERROR__: " & e.msg)

proc main() =
  let cmd_args = commandLineParams()
  let arg = parseArgs(cmd_args)

  var
    debugStdoutFileName = ""
    debugStderrFileName = ""

  if arg.debugMode:
    debugStdoutFileName = fmt"""debugger_stdout_{now().format("yyyyMMddHHmmss")}.log"""
    debugStderrFileName = fmt"""debugger_stderr_{now().format("yyyyMMddHHmmss")}.log"""
    writeFile(debugStdoutFileName, "")
    writeFile(debugStderrFileName, "")

  toStderr("Nim Debugger MI Proxy", debugStderrFileName)
  toStderr("Input args: " & cmd_args.join(" "), debugStderrFileName)
  toStderr("Parsed args: " & $arg, debugStderrFileName)

  # Load symbol map
  let sm = newSymbolMap()
  if arg.symbolsPath != "":
    toStderr("Loading custom symbol map from: " & arg.symbolsPath, debugStderrFileName)
    discard sm.loadFromFile(arg.symbolsPath)
  elif arg.programPath != "":
    toStderr("Loading symbols from: " & arg.programPath, debugStderrFileName)
    discard sm.loadFromBinary(arg.programPath)

  # Build GDB command
  toStderr("Starting Debugger: " & arg.gdbPath & " " & arg.gdbArgs.join(" "), debugStderrFileName)

  # Initialize input channel and reader thread
  stdinChann.open()
  var stdinChanThread: Thread[void]
  createThread(stdinChanThread, stdinReader)

  # Start GDB process
  var p: Process
  try:
    p = newProcess(arg.gdbPath, arg.gdbArgs)
  except Exception as e:
    toStderr("Failed to start Debugger: " & e.msg, debugStderrFileName)
    quit(1)

  if not p.isRunning:
    toStderr("Failed to start Debugger process (not running)!", debugStderrFileName)
    quit(1)

  var inBuffer = ""
  var outBuffer = ""
  while true:
    # 1. Check GDB Output
    while true:
      let gdbOut = p.readOutput(5)

      if gdbOut.len == 0: break
      outBuffer.add(gdbOut)

      while true:
        let nlPos = outBuffer.find('\n')
        if nlPos == -1: break
        let rawLine = outBuffer[0 ..< nlPos].strip()
        outBuffer = outBuffer[(nlPos + 1) .. ^1]
        try:
          let transformed = transformOutput(rawLine, sm, debug = arg.debugMode)
          if arg.debugMode: toStderr("Transformed Output: " & transformed, debugStderrFileName)
          toStdout(transformed, debugStdoutFileName)
        except Exception as e:
          toStdout(rawLine, debugStdoutFileName)
    
    # 2. Check GDB Stderr
    while true:
      let gdbErr = p.readError(5)
      if gdbErr.len == 0: break
      toStderr(gdbErr.strip(), debugStderrFileName)
    
    # 3. Read from stdin
    let (stdinReceived, stdinRawInput) = stdinChann.tryRecv()
    if stdinReceived: inBuffer.add(stdinRawInput & "\n")
    
    # 4. Process stdin lines
    while true:
      let nlPos = inBuffer.find('\n')
      if nlPos == -1: break
      var rawLine = inBuffer[0 ..< nlPos].strip()
      inBuffer = inBuffer[(nlPos + 1) .. ^1]

      if rawLine.len == 0: continue
      
      # [CHECK 1] Check for Reader Thread Crash/EOF
      if rawLine == "__EOF__":
        toStderr("Stdin closed by VS Code.", debugStderrFileName)
        quit(0)
      
      if rawLine.startsWith("__ERROR__"):
        toStderr("Reader Thread Crashed: " & rawLine, debugStderrFileName)
        quit(1)

      # [CHECK 2] Handle Symbols loading
      if rawLine.contains("-file-exec-and-symbols"):
        let parts = rawLine.split(maxsplit=1)
        if parts.len == 2:
          let path = parts[1].strip
          if fileExists(path):
            if arg.debugMode: toStderr("Dynamically loading symbols from: " & path, debugStderrFileName)
            discard sm.loadFromBinary(path)

      # [CHECK 3] TRANSFORM INPUT
      # Sanitize "CON" arguments to prevent GDB/MIEngine confusion
      if rawLine.contains("-exec-arguments"):
         rawLine = rawLine.replace("2>CON", "").replace("1>CON", "").replace("<CON", "").strip()
      
      try:
        if arg.debugMode: toStderr("VS -> GDB: " & rawLine, debugStderrFileName)
        let transformed = transformInput(rawLine, sm)
        discard p.write(transformed & "\n")
      except Exception as e:
        toStderr("Error forwarding input: " & e.msg, debugStderrFileName)
        discard p.write(rawLine & "\n")
    
    # 5. Check if process is still running
    if not p.isRunning:
      toStderr("GDB Exited", debugStderrFileName)
      quit(0)
    
    # 6. Small sleep
    sleep(5)
  
  p.close()

main()