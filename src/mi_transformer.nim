import strutils, re, symbol_map, osproc

# ----- Output Transformer -----

proc transformOutput*(line: string, sm: SymbolMap, debugger: string = "gdb", debug: bool = false): string =
  # Transform both name="..." and func="..." fields
  # name="..." contains variable/parameter names
  # func="..." contains function names in stack frames
  
  result = ""
  var pos = 0
  
  # Pattern matches both name="..." and func="..." with escape handling
  let pattern = """(name|func)="((?:[^\"\\]|\\.)*)"""".re
  var matches: array[2, string]  # [0] = field type (name/func), [1] = value
  
  while true:
    let bounds = findBounds(line, pattern, matches, start=pos)
    if bounds.first == -1:
      result.add(line[pos .. ^1])
      break
    
    result.add(line[pos ..< bounds.first])
    
    # Process match
    let fieldType = matches[0]  # "name" or "func"
    var mangled = matches[1]
    
    # Unescape the string
    var unescaped = newStringOfCap(mangled.len)
    var i = 0
    while i < mangled.len:
      if mangled[i] == '\\' and i + 1 < mangled.len:
        case mangled[i+1]:
        of '\\': unescaped.add('\\')
        of '"': unescaped.add('"')
        of 'n': unescaped.add('\n')
        of 't': unescaped.add('\t')
        else: unescaped.add(mangled[i+1])
        i += 2
      else:
        unescaped.add(mangled[i])
        i += 1
    mangled = unescaped
    
    var demangled = mangled  # Start with original
    
    # Only apply Nim demangling if it's NOT a C++ mangled name
    if not mangled.startsWith("_Z"):
      demangled = sm.demangle(mangled)
    
    # For C++ mangled names (or if Nim demangling didn't change it), try c++filt
    if demangled.startsWith("_Z"):
      if debug:
        stderr.writeLine("Attempting C++ demangle of: " & demangled)
      try:
        let (output, exitCode) = execCmdEx("c++filt -n " & demangled)
        if exitCode == 0 and output.len > 0:
          demangled = output.strip()
          if debug:
            stderr.writeLine("  -> Demangled to: " & demangled)
        elif debug:
          stderr.writeLine("  -> c++filt failed or returned empty")
      except Exception as e:
        if debug:
          stderr.writeLine("  -> c++filt exception: " & e.msg)
    
    if debug and fieldType == "func" and demangled != mangled:
      stderr.writeLine("Function transform: " & mangled & " -> " & demangled)
    
    sm.addLocal(mangled) # Auto-register potential locals seen in output
    
    # Re-escape the demangled string
    var escaped = newStringOfCap(demangled.len * 2)
    for ch in demangled:
      case ch:
      of '\\': escaped.add("\\\\")
      of '"': escaped.add("\\\"")
      of '\n': escaped.add("\\n")
      of '\t': escaped.add("\\t")
      else: escaped.add(ch)
    
    result.add(fieldType & "=\"" & escaped & "\"")
    
    pos = bounds.last + 1

# ----- Input Transformer -----

proc transformInput*(line: string, sm: SymbolMap, debugger: string = "gdb", debug: bool = false): string =
  # Helper to transform expression parts
  proc transformExpression(expr: string): string =
    # Transform identifiers AND special demangled names (like [tmp5], [StackFrame])
    # Pattern matches: [SpecialName] OR normalIdentifier OR Nim-specific patterns
    # Also handle operators that might be part of names in Nim/C++ (::, ., ->)
    let identPattern = if debugger == "gdb":
      # GDB: handle C/C++/Nim patterns
      re"(\[[^\]]+\]|@[a-zA-Z_][a-zA-Z0-9_]*|\b[a-zA-Z_][a-zA-Z0-9_:]*(?:->[a-zA-Z_][a-zA-Z0-9_]*)?\b)"
    else:
      # LLDB: similar patterns but might differ
      re"(\[[^\]]+\]|@[a-zA-Z_][a-zA-Z0-9_]*|\b[a-zA-Z_][a-zA-Z0-9_:.]*(?:->[a-zA-Z_][a-zA-Z0-9_]*)?\b)"
    
    var matches: array[1, string]
    var newExpr = ""
    var pos = 0
    
    while true:
      let bounds = findBounds(expr, identPattern, matches, start=pos)
      if bounds.first == -1:
        newExpr.add(expr[pos .. ^1])
        break
        
      newExpr.add(expr[pos ..< bounds.first])
      
      let identifier = matches[0]
      # Skip numeric literals and common operators
      if identifier notin ["true", "false", "null", "this", "super"] and
         not (identifier.len > 0 and identifier[0].isdigit()):
        let mangled = sm.getMangled(identifier)
        newExpr.add(mangled)
      else:
        newExpr.add(identifier)
      
      pos = bounds.last + 1
    return newExpr
  
  # Helper to find quoted expression
  proc transformQuotedExpression(line: string): string =
    let quoteStart = line.find('"')
    if quoteStart == -1: return line
    let quoteEnd = line.rfind('"')
    if quoteEnd <= quoteStart: return line
    
    let before = line[0 .. quoteStart]
    let after = line[quoteEnd .. ^1]
    let exprChunk = line[quoteStart+1 .. quoteEnd-1]
    
    return before & transformExpression(exprChunk) & after
  
  # Helper to handle commands with optional flags before expression
  proc handleCommandWithFlags(line: string, cmd: string): string =
    let parts = line.splitWhitespace()
    var cmdIdx = -1
    for i, part in parts:
      if part.contains(cmd):
        cmdIdx = i
        break
    if cmdIdx == -1: return line
    
    # Skip token if present (e.g., "1029-var-create")
    var startIdx = if cmdIdx > 0 and parts[cmdIdx-1].contains('-'): cmdIdx else: cmdIdx
    
    # Process flags
    var idx = startIdx + 1
    while idx < parts.len:
      if parts[idx].startsWith("--"):
        idx += 2  # Skip flag and its value
      elif parts[idx] in ["-t", "-c", "-i", "-p"]:  # Common short flags
        idx += 2
      else:
        break
    
    # Skip name and frame specifiers (typically "-", "*", or frame numbers)
    # These are usually 1-2 tokens after flags
    if idx < parts.len and parts[idx] in ["-", "*", "@"]:
      idx += 1
    if idx < parts.len and parts[idx].match(re"\d+"):  # Frame number
      idx += 1
    
    if idx >= parts.len: return line
    
    # Transform the remaining expression
    var resultParts: seq[string] = @[]
    for i in 0..<idx:
      resultParts.add(parts[i])
    
    var exprParts: seq[string] = @[]
    for i in idx..<parts.len:
      exprParts.add(parts[i])
    
    let expr = exprParts.join(" ")
    resultParts.add(transformExpression(expr))
    
    return resultParts.join(" ")
  
  # ----- Command Handling -----
  
  # Debugger Console and Expression Evaluation commands
  if line.contains("-data-evaluate-expression"):
    return transformQuotedExpression(line)
  
  elif line.contains("-var-create"):
    return handleCommandWithFlags(line, "-var-create")
  
  elif line.contains("-interpreter-exec") and line.contains("console"):
    return transformQuotedExpression(line)
  
  elif line.startsWith("-exec"):
    # Format: "-exec p i" or "-exec print someVar"
    let parts = line.splitWhitespace()
    if parts.len < 3: return line
    
    var cmdParts: seq[string] = @[parts[0], parts[1]]
    var exprParts: seq[string] = @[]
    for i in 2..<parts.len:
      exprParts.add(parts[i])
    
    let expr = exprParts.join(" ")
    cmdParts.add(transformExpression(expr))
    return cmdParts.join(" ")
  
  # ----- Stack Frame Commands -----
  
  elif line.contains("-stack-list-arguments"):
    # Format: "-stack-list-arguments --all-values 0 1"
    # No symbol transformation needed for arguments themselves, but frame numbers may be present
    return line
  
  elif line.contains("-stack-list-locals"):
    # Format: "-stack-list-locals --all-values"
    # No expression to transform, just lists locals
    return line
  
  elif line.contains("-stack-list-frames"):
    # Format: "-stack-list-frames 0 20"
    # No symbol transformation in this command
    return line
  
  # ----- Variable Object Commands -----
  
  elif line.contains("-var-list-children"):
    # Format: "-var-list-children var1"
    # The variable name may need transformation
    let parts = line.splitWhitespace()
    if parts.len < 2: return line
    
    let lastPart = parts[^1]
    let mangled = sm.getMangled(lastPart)
    
    var resultParts: seq[string] = @[]
    for i in 0..<parts.len-1:
      resultParts.add(parts[i])
    resultParts.add(mangled)
    
    return resultParts.join(" ")
  
  elif line.contains("-var-evaluate-expression"):
    # Format: "-var-evaluate-expression var1"
    let parts = line.splitWhitespace()
    if parts.len < 2: return line
    
    let lastPart = parts[^1]
    let mangled = sm.getMangled(lastPart)
    
    var resultParts: seq[string] = @[]
    for i in 0..<parts.len-1:
      resultParts.add(parts[i])
    resultParts.add(mangled)
    
    return resultParts.join(" ")
  
  elif line.contains("-var-assign"):
    # Format: "-var-assign var1 value"
    let parts = line.splitWhitespace()
    if parts.len < 3: return line
    
    # Transform variable name (first argument after -var-assign)
    let varName = parts[1]
    let mangledVar = sm.getMangled(varName)
    
    var resultParts: seq[string] = @[parts[0], mangledVar]
    
    # The value might be an expression to evaluate
    if parts.len > 2:
      var valueParts: seq[string] = @[]
      for i in 2..<parts.len:
        valueParts.add(parts[i])
      let valueExpr = valueParts.join(" ")
      resultParts.add(transformExpression(valueExpr))
    
    return resultParts.join(" ")
  
  elif line.contains("-var-update"):
    # Format: "-var-update --all-values *" or "-var-update var1 var2"
    # Variable names may need transformation
    let parts = line.splitWhitespace()
    if parts.len < 2: return line
    
    var resultParts: seq[string] = @[parts[0]]
    
    # Skip flags
    var i = 1
    while i < parts.len:
      if parts[i].startsWith("--"):
        resultParts.add(parts[i])
        i += 1
        if i < parts.len and not parts[i].startsWith("-"):
          resultParts.add(parts[i])
          i += 1
      else:
        break
    
    # Transform remaining variable names
    while i < parts.len:
      if parts[i] != "*":
        resultParts.add(sm.getMangled(parts[i]))
      else:
        resultParts.add(parts[i])
      i += 1
    
    return resultParts.join(" ")
  
  # ----- Breakpoint Commands -----
  
  elif line.contains("-break-insert"):
    if line.contains('"'):
      # Has quoted expression (breakpoint location/condition)
      return transformQuotedExpression(line)
    else:
      # Might be just function name or address
      return handleCommandWithFlags(line, "-break-insert")
  
  elif line.contains("-break-condition"):
    # Format: "-break-condition 1 i > 5"
    let parts = line.splitWhitespace()
    if parts.len < 3: return line
    
    var resultParts: seq[string] = @[parts[0], parts[1]]
    
    # Transform condition expression
    var conditionParts: seq[string] = @[]
    for i in 2..<parts.len:
      conditionParts.add(parts[i])
    let condition = conditionParts.join(" ")
    resultParts.add(transformExpression(condition))
    
    return resultParts.join(" ")
  
  elif line.contains("-break-watch"):
    # Format: "-break-watch variableName"
    let parts = line.splitWhitespace()
    if parts.len < 2: return line
    
    let lastPart = parts[^1]
    let mangled = sm.getMangled(lastPart)
    
    var resultParts: seq[string] = @[]
    for i in 0..<parts.len-1:
      resultParts.add(parts[i])
    resultParts.add(mangled)
    
    return resultParts.join(" ")
  
  # ----- Thread/Frame Selection -----
  
  elif line.contains("-thread-select"):
    # Format: "-thread-select 1"
    # No symbol transformation needed
    return line
  
  elif line.contains("-stack-select-frame"):
    # Format: "-stack-select-frame 2"
    # No symbol transformation needed
    return line
  
  # ----- Memory/Register Commands -----
  
  elif line.contains("-data-read-memory"):
    # Format: "-data-read-memory address word-format word-size nr-rows nr-cols aschar"
    # No symbol transformation in address (usually numeric)
    return line
  
  elif line.contains("-data-write-memory"):
    # Might have expression for value
    if line.contains('"'):
      return transformQuotedExpression(line)
    return line
  
  # ----- LLDB-specific commands -----
  
  elif debugger == "lldb" and line.contains("platform-select"):
    # LLDB-specific platform commands
    return line
  
  elif debugger == "lldb" and line.contains("settings set"):
    # LLDB settings - might contain target names
    let parts = line.splitWhitespace()
    if parts.len >= 4 and parts[2] == "target.executable-search-paths":
      # This might contain paths with mangled names
      return transformQuotedExpression(line)
    return line
  
  # ----- Fallthrough for other commands -----
  
  if debug:
    stderr.writeLine("Unhandled command: " & line)
  
  return line