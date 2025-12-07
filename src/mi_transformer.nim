
import strutils, re, symbol_map, osproc

# ----- Output Transformer -----

proc transformOutput*(line: string, sm: SymbolMap, debug: bool = false): string =
  # Transform both name="..." and func="..." fields
  # name="..." contains variable/parameter names
  # func="..." contains function names in stack frames
  
  result = ""
  var pos = 0
  
  # Pattern matches both name="..." and func="..."
  let pattern = re(r"""(name|func)="([^"]+)"""")
  var matches: array[2, string]  # [0] = field type (name/func), [1] = value
  
  while true:
    let bounds = findBounds(line, pattern, matches, start=pos)
    if bounds.first == -1:
      result.add(line[pos .. ^1])
      break
    
    result.add(line[pos ..< bounds.first])
    
    # Process match
    let fieldType = matches[0]  # "name" or "func"
    let mangled = matches[1]
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
    result.add(fieldType & "=\"" & demangled & "\"")
    
    pos = bounds.last + 1

# ----- Input Transformer -----

proc transformInput*(line: string, sm: SymbolMap): string =
  # Handle -data-evaluate-expression "expr" (quoted expression)
  if line.startsWith("-data-evaluate-expression"):
       let quoteStart = line.find('"')
       if quoteStart == -1: return line
       let quoteEnd = line.rfind('"')
       if quoteEnd <= quoteStart: return line
       
       let exprChunk = line[quoteStart+1 .. quoteEnd-1]
       var newExpr = ""
       
       # Replace identifiers AND special demangled names (like [tmp5], [StackFrame])
       # Pattern matches: [SpecialName] OR normalIdentifier
       let identPattern = re"(\[[^\]]+\]|\b[a-zA-Z_][a-zA-Z0-9_]*\b)"
       var matches: array[1, string]
       
       var pos = 0
       while true:
         let bounds = findBounds(exprChunk, identPattern, matches, start=pos)
         if bounds.first == -1:
           newExpr.add(exprChunk[pos .. ^1])
           break
           
         newExpr.add(exprChunk[pos ..< bounds.first])
         
         let identifier = matches[0]  # Could be "[tmp5]" or "normalVar"
         let mangled = sm.getMangled(identifier)
         newExpr.add(mangled)
         
         pos = bounds.last + 1
          
       return line[0..quoteStart] & newExpr & line[quoteEnd..^1]
  
  # Handle -var-create with quoted expression
  # Format: "{token}-var-create [--thread N] [--frame N] {name} {frame} "expr""
  # Example: "1029-var-create --thread 1 --frame 0  - * \"i\""
  elif line.contains("-var-create"):
       let quoteStart = line.find('"')
       if quoteStart != -1:
         # Expression is quoted - handle like -data-evaluate-expression
         let quoteEnd = line.rfind('"')
         if quoteEnd <= quoteStart: return line
         
         let exprChunk = line[quoteStart+1 .. quoteEnd-1]
         var newExpr = ""
         
         # Transform identifiers AND special demangled names
         let identPattern = re"(\[[^\]]+\]|\b[a-zA-Z_][a-zA-Z0-9_]*\b)"
         var matches: array[1, string]
         var pos = 0
         
         while true:
           let bounds = findBounds(exprChunk, identPattern, matches, start=pos)
           if bounds.first == -1:
             newExpr.add(exprChunk[pos .. ^1])
             break
             
           newExpr.add(exprChunk[pos ..< bounds.first])
           let identifier = matches[0]
           let mangled = sm.getMangled(identifier)
           newExpr.add(mangled)
           pos = bounds.last + 1
         
         return line[0..quoteStart] & newExpr & line[quoteEnd..^1]
       else:
         # Unquoted expression (space-separated) - original handling
         let parts = line.splitWhitespace()
         # Find where actual -var-create command starts (skip token if present)
         var cmdIdx = 0
         for i, part in parts:
           if part.contains("-var-create"):
             cmdIdx = i
             break
         
         # parts after -var-create: [--thread, N, --frame, N, name, frame, ...expression]
         # We need to skip flags and find the expression
         var exprStartIdx = cmdIdx + 1
         
         # Skip --thread N and --frame N flags
         while exprStartIdx < parts.len:
           if parts[exprStartIdx].startsWith("--"):
             exprStartIdx += 2  # Skip flag and its value
           else:
             break
         
         # Skip name and frame (typically "- *" or similar)
         exprStartIdx += 2
         
         if exprStartIdx >= parts.len: return line
         
         # Collect expression parts
         var exprParts: seq[string] = @[]
         for i in exprStartIdx..<parts.len:
           exprParts.add(parts[i])
         let expr = exprParts.join(" ")
         
         # Transform identifiers
         let identPattern = re"\b[a-zA-Z_][a-zA-Z0-9_]*\b"
         var matches: array[1, string]
         var newExpr = ""
         var pos = 0
         
         while true:
           let bounds = findBounds(expr, identPattern, matches, start=pos)
           if bounds.first == -1:
             newExpr.add(expr[pos .. ^1])
             break
             
           newExpr.add(expr[pos ..< bounds.first])
           let identifier = expr[bounds.first .. bounds.last]
           let mangled = sm.getMangled(identifier)
           newExpr.add(mangled)
           pos = bounds.last + 1
         
         # Rebuild command
         var resultParts: seq[string] = @[]
         for i in 0..<exprStartIdx:
           resultParts.add(parts[i])
         resultParts.add(newExpr)
         return resultParts.join(" ")
  
  # Handle -interpreter-exec console "command" (Debug Console commands)
  # Format: "{token}-interpreter-exec console "p i""
  # Example: "1067-interpreter-exec console "p i""
  elif line.contains("-interpreter-exec") and line.contains("console"):
       let quoteStart = line.find('"')
       if quoteStart == -1: return line
       let quoteEnd = line.rfind('"')
       if quoteEnd <= quoteStart: return line
       
       let consoleCmd = line[quoteStart+1 .. quoteEnd-1]
       
       # Parse the console command - typically "p varname" or "print varname"
       let cmdParts = consoleCmd.splitWhitespace()
       if cmdParts.len < 2: return line
       
       # First part is the command (p, print, etc.), rest is expression
       let gdbCmd = cmdParts[0]
       var exprParts: seq[string] = @[]
       for i in 1..<cmdParts.len:
         exprParts.add(cmdParts[i])
       let expr = exprParts.join(" ")
       
       # Transform identifiers AND special demangled names
       let identPattern = re"(\[[^\]]+\]|\b[a-zA-Z_][a-zA-Z0-9_]*\b)"
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
         let mangled = sm.getMangled(identifier)
         newExpr.add(mangled)
         pos = bounds.last + 1
       
       let newConsoleCmd = gdbCmd & " " & newExpr
       return line[0..quoteStart] & newConsoleCmd & line[quoteEnd..^1]
  
  # Handle -exec commands (console commands like "p i", "print i", etc.)
  elif line.startsWith("-exec"):
       # Format: "-exec p i" or "-exec print someVar"
       # We need to transform the expression after the command
       let parts = line.splitWhitespace()
       if parts.len < 3: return line # Need at least "-exec", command, and expression
       
       # parts[1] is the command (p, print, etc.)
       # parts[2..] is the expression
       var exprParts: seq[string] = @[]
       for i in 2..<parts.len:
         exprParts.add(parts[i])
       let expr = exprParts.join(" ")
       
       # Transform identifiers
       let identPattern = re"\b[a-zA-Z_][a-zA-Z0-9_]*\b"
       var matches: array[1, string]
       var newExpr = ""
       var pos = 0
       
       while true:
         let bounds = findBounds(expr, identPattern, matches, start=pos)
         if bounds.first == -1:
           newExpr.add(expr[pos .. ^1])
           break
           
         newExpr.add(expr[pos ..< bounds.first])
         let identifier = expr[bounds.first .. bounds.last]
         let mangled = sm.getMangled(identifier)
         newExpr.add(mangled)
         pos = bounds.last + 1
       
       return parts[0] & " " & parts[1] & " " & newExpr
       
  return line
