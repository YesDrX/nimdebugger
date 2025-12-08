
import strutils, tables, re, json, osproc

type
  SymbolMap* = ref object
    # Cache for global symbols found via nm/parsing
    globalMangledToDemangled*: Table[string, string]
    globalDemangledToMangled*: Table[string, seq[string]]
    
    # Active scope symbols (from GDB info locals/args)
    localDemangledToMangled*: Table[string, string]

proc newSymbolMap*(): SymbolMap =
  new(result)
  result.globalMangledToDemangled = initTable[string, string]()
  result.globalDemangledToMangled = initTable[string, seq[string]]()
  result.localDemangledToMangled = initTable[string, string]()

# Regex for Nim mangling
# Locals: variableName_123, arg_p0
# Globals: variableName__package_123
let reGlobal = re"^([a-zA-Z_][a-zA-Z0-9_]*)__[a-zA-Z0-9_]+$"
let reLocal = re"^([a-zA-Z_][a-zA-Z0-9_]*)_[a-zA-Z0-9]+$"

proc demangle*(self: SymbolMap, mangled: string): string =
  # Special cases for common Nim compiler-generated variables
  if mangled == "FR_":
    return "[StackFrame]"  # Exception/debug stack frame
  
  # Temporary variables: T1_, T2_, T3_, etc.
  if mangled.len >= 2 and mangled[0] == 'T' and mangled[^1] == '_':
    # Check if middle part is all digits
    let middlePart = mangled[1..^2]
    var isAllDigits = true
    for c in middlePart:
      if not c.isDigit:
        isAllDigits = false
        break
    if isAllDigits and middlePart.len > 0:
      return "[tmp" & middlePart & "]"
  
  # Special internal variables that end with underscore
  if mangled.endsWith("_") and mangled.len > 1:
    let baseName = mangled[0..^2]
    # Check for known patterns
    if baseName == "TM":
      return "[ThreadMem]"  # Thread-local memory
    elif baseName.startsWith("colonTmp") or baseName.startsWith("colontmp"):
      # Compiler temporary for expressions
      return "[tmp:" & baseName[8..^1] & "]"
  
  # Standard Nim symbol demangling
  var matches: array[1, string]
  if match(mangled, reGlobal, matches):
    return matches[0]
  if match(mangled, reLocal, matches):
    return matches[0]
  return mangled

proc addGlobal*(self: SymbolMap, mangled: string) =
  let demangled = self.demangle(mangled)
  if demangled == mangled: return
  
  self.globalMangledToDemangled[mangled] = demangled
  if not self.globalDemangledToMangled.hasKey(demangled):
    self.globalDemangledToMangled[demangled] = @[]
  self.globalDemangledToMangled[demangled].add(mangled)

proc clearLocals*(self: SymbolMap) =
  self.localDemangledToMangled.clear()

proc addLocal*(self: SymbolMap, mangled: string) =
  let demangled = self.demangle(mangled)
  if demangled != mangled:
    self.localDemangledToMangled[demangled] = mangled

proc getMangled*(self: SymbolMap, demangled: string): string =
  # Handle reverse mapping for special demangled names
  
  # [StackFrame] → FR_
  if demangled == "[StackFrame]":
    return "FR_"
  
  # [tmp1], [tmp2], etc. → T1_, T2_, etc.
  if demangled.len >= 6 and demangled.startsWith("[tmp") and demangled.endsWith("]"):
    let numPart = demangled[4..^2]  # Extract number between [tmp and ]
    # Check if it's all digits
    var isAllDigits = true
    for c in numPart:
      if not c.isDigit:
        isAllDigits = false
        break
    if isAllDigits and numPart.len > 0:
      return "T" & numPart & "_"
  
  # [ThreadMem] → TM_ (actually TM__<hash>_<number>, but we need to look it up)
  if demangled == "[ThreadMem]":
    # This is trickier - we need to find the actual TM__ variant
    # For now, try common patterns, or the user needs to use the mangled name
    # Let's check if we have it in our reverse map
    if self.localDemangledToMangled.hasKey(demangled) or 
       self.globalDemangledToMangled.hasKey(demangled):
      # Fall through to standard lookup below
      discard
    else:
      # No exact match, return as-is and hope for the best
      return demangled
  
  # [tmp:D_] → colontmpD_
  if demangled.len >= 7 and demangled.startsWith("[tmp:") and demangled.endsWith("]"):
    let innerPart = demangled[5..^2]  # Extract between [tmp: and ]
    return "colontmp" & innerPart
  
  # Standard lookup
  # Prefer local
  if self.localDemangledToMangled.hasKey(demangled):
    return self.localDemangledToMangled[demangled]
  # Fallback to global (pick first for now, or maybe shortest nonce?)
  if self.globalDemangledToMangled.hasKey(demangled):
    return self.globalDemangledToMangled[demangled][0]
  return demangled

proc loadFromNm*(self: SymbolMap, binaryPath: string) =
  # Run nm -n binaryPath
  # Parse lines: address type name
  # e.g. 000000000040f138 D mainVal__hello_u6
  when defined(linux) or defined(macosx):
    try:
      let (outp, errc) = execCmdEx("nm -n " & binaryPath)
      if errc != 0: return # Silently fail or log?
      
      for line in outp.splitLines:
        let parts = line.splitWhitespace()
        if parts.len >= 3:
           # Address Type Name
           let name = parts[2]
           self.addGlobal(name)
    except OSError:
      discard
  else:
    # Windows: implement later or use objdump?
    discard

proc loadFromJson*(self: SymbolMap, jsonPath: string) =
  try:
    let content = readFile(jsonPath)
    let node = parseJson(content)
    # Expected format: {"global": {"mangled": "demangled"}, "local": {"demangled": "mangled"}}
    # Or just a simple list? 
    # Let's assume a simple list of mangled names for globals, and maybe explicit map for others.
    # For now, let's support a map of "mangled" -> "demangled"
    
    if node.hasKey("symbols"):
       for mangled, demangled in node["symbols"].pairs:
          self.globalMangledToDemangled[mangled] = demangled.getStr()
          
    # TODO: More complex format if needed
  except Exception:
    discard
