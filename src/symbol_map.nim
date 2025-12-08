import strutils, tables, re, osproc, os, json

type
  SymbolMap* = ref object
    globalMangledToDemangled*: Table[string, string]
    globalDemangledToMangled*: Table[string, seq[string]]
    localDemangledToMangled*: Table[string, string]

proc newSymbolMap*(): SymbolMap =
  new(result)
  result.globalMangledToDemangled = initTable[string, string]()
  result.globalDemangledToMangled = initTable[string, seq[string]]()
  result.localDemangledToMangled = initTable[string, string]()

# Updated regex patterns to include _p0, _p1, _p2, etc.
let reGlobal = re"^([a-zA-Z_][a-zA-Z0-9_]*)__[a-zA-Z0-9_]+$"
let reLocal = re"^([a-zA-Z_][a-zA-Z0-9_]*)_[0-9a-fA-F]+$"
let reParam = re"^([a-zA-Z_][a-zA-Z0-9_]*)_p[0-9]+$"  # NEW: for function parameters

proc demangle*(self: SymbolMap, mangled: string): string =
  # Special cases first
  if mangled == "FR_":
    return "[StackFrame]"
  
  # Temporary variables: T1_, T2_, T3_, etc.
  if mangled.len >= 2 and mangled[0] == 'T' and mangled[^1] == '_':
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
    if baseName == "TM":
      return "[ThreadMem]"
    elif baseName.startsWith("colonTmp") or baseName.startsWith("colontmp"):
      return "[tmp:" & baseName[8..^1] & "]"
  
  # Handle function parameters: abc_p0, def_p1, etc. - NEW
  var matches: array[1, string]
  if match(mangled, reParam, matches):
    return matches[0]
  
  # Handle i_1, res_1, data_1 patterns
  if mangled.endsWith("_1"):
    let baseName = mangled[0..^3]
    if baseName.len > 0 and baseName[0].isAlphaAscii:
      return baseName
  
  # Handle patterns like TM_ipcYmBC9b... (Thread Local with hash)
  if mangled.startsWith("TM_") and mangled.len > 3:
    return "[ThreadLocal]"
  
  # Standard Nim symbol demangling
  if match(mangled, reGlobal, matches):
    return matches[0]
  if match(mangled, reLocal, matches):
    return matches[0]
  
  # Try one more pattern: name_123 (with decimal numbers)
  let parts = mangled.split('_')
  if parts.len == 2 and parts[1].len > 0:
    # Check if it's a parameter pattern (p followed by number)
    if parts[1].len >= 2 and parts[1][0] == 'p' and parts[1][1..^1].allCharsInSet({'0'..'9'}):
      return parts[0]
    
    # Check if it's just decimal numbers
    var allDigits = true
    for c in parts[1]:
      if not c.isDigit:
        allDigits = false
        break
    if allDigits and parts[0].len > 0 and parts[0][0].isAlphaAscii:
      return parts[0]
  
  return mangled

proc addGlobal*(self: SymbolMap, mangled: string) =
  let demangled = self.demangle(mangled)
  if demangled == mangled: 
    return
  
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
  if demangled == "[StackFrame]":
    return "FR_"
  
  if demangled.startsWith("[tmp") and demangled.endsWith("]"):
    let numPart = demangled[4..^2]
    var allDigits = true
    for c in numPart:
      if not c.isDigit:
        allDigits = false
        break
    if allDigits and numPart.len > 0:
      return "T" & numPart & "_"
  
  if demangled == "[ThreadMem]" or demangled == "[ThreadLocal]":
    # Try to find a TM_ symbol
    for mangled in self.globalMangledToDemangled.keys:
      if mangled.startsWith("TM_"):
        return mangled
    for mangled in self.localDemangledToMangled.values:
      if mangled.startsWith("TM_"):
        return mangled
    return "TM_"  # Fallback
  
  if demangled.startsWith("[tmp:") and demangled.endsWith("]"):
    let innerPart = demangled[5..^2]
    return "colontmp" & innerPart
  
  # For function parameters, we need to find the right suffix (_p0, _p1, etc.)
  # Check if this is likely a parameter by looking in local symbols first
  if self.localDemangledToMangled.hasKey(demangled):
    let mangledName = self.localDemangledToMangled[demangled]
    # If it's already a parameter (ends with _pX), return it
    if mangledName.contains("_p") and mangledName[mangledName.len-1].isDigit:
      return mangledName
  
  # Standard lookup
  if self.localDemangledToMangled.hasKey(demangled):
    return self.localDemangledToMangled[demangled]
  
  if self.globalDemangledToMangled.hasKey(demangled):
    # For parameters, prefer the one with _p suffix
    var candidates = self.globalDemangledToMangled[demangled]
    for mangled in candidates:
      if mangled.contains("_p") and mangled[mangled.len-1].isDigit:
        return mangled
    
    # Otherwise return shortest
    var best = candidates[0]
    for mangled in candidates:
      if mangled.len < best.len:
        best = mangled
    return best
  
  # If not found, try to construct parameter name with _p0
  # (common default for first parameter)
  return demangled

proc loadFromBinary*(self: SymbolMap, binaryPath: string): bool =
  ## Load symbols from binary using nm or objdump
  if not fileExists(binaryPath):
    return false
  
  # Helper to parse nm output
  proc parseNmOutput(output: string) =
    for line in output.splitLines:
      if line.len == 0: continue
      let parts = line.splitWhitespace(maxsplit=2)
      if parts.len >= 3:
        let name = parts[2]
        if name.len > 0 and not name.startsWith("."):
          self.addGlobal(name)
  
  # Try nm first (fastest)
  try:
    # Try with demangling
    let (outp1, code1) = execCmdEx("nm --demangle --defined-only " & binaryPath & " 2>/dev/null")
    if code1 == 0 and outp1.len > 0:
      parseNmOutput(outp1)
      return true
    
    # Try without demangling
    let (outp2, code2) = execCmdEx("nm --defined-only " & binaryPath & " 2>/dev/null")
    if code2 == 0 and outp2.len > 0:
      parseNmOutput(outp2)
      return true
  except OSError:
    discard
  
  # Fallback to objdump
  try:
    let (outp, code) = execCmdEx("objdump -t " & binaryPath & " 2>/dev/null")
    if code == 0:
      for line in outp.splitLines:
        if line.len < 30: continue
        if line[0] in HexDigits:
          let parts = line.splitWhitespace()
          if parts.len >= 6:
            let name = parts[^1]
            if name.len > 0 and not name.startsWith("."):
              self.addGlobal(name)
      return true
  except OSError:
    discard
  
  return false

proc loadFromGdbInfo*(self: SymbolMap, gdbOutput: string) =
  ## Parse GDB 'info locals' and 'info args' output
  self.clearLocals()
  
  for line in gdbOutput.splitLines:
    let cleanLine = line.strip
    if cleanLine.len == 0 or " = " notin cleanLine:
      continue
    
    let eqPos = cleanLine.find(" = ")
    if eqPos > 0:
      let varName = cleanLine[0..<eqPos].strip
      if varName.len > 0:
        self.addLocal(varName)

proc toJson*(self: SymbolMap): JsonNode =
  ## Convert to GDB-compatible JSON format
  var j = newJObject()
  
  # Global symbols: {"mangled": "demangled"}
  var globalObj = newJObject()
  for mangled, demangled in self.globalMangledToDemangled:
    globalObj[mangled] = %demangled
  j["global"] = globalObj
  
  # Local symbols: {"demangled": "mangled"}
  var localObj = newJObject()
  for demangled, mangled in self.localDemangledToMangled:
    localObj[demangled] = %mangled
  j["local"] = localObj
  
  return j

proc toJsonString*(self: SymbolMap, pretty: bool = false): string =
  let j = self.toJson()
  if pretty:
    return pretty(j, 2)
  else:
    return $j

proc saveToFile*(self: SymbolMap, filepath: string, pretty: bool = false) =
  let jsonStr = self.toJsonString(pretty)
  writeFile(filepath, jsonStr)

proc loadFromFile*(self: SymbolMap, filepath: string): bool =
  try:
    let content = readFile(filepath)
    let j = parseJson(content)
    
    self.globalMangledToDemangled.clear()
    self.globalDemangledToMangled.clear()
    self.localDemangledToMangled.clear()
    
    if "global" in j:
      for mangled, demangled in j["global"]:
        let mangledStr = mangled
        let demangledStr = demangled.getStr
        self.globalMangledToDemangled[mangledStr] = demangledStr
        if not self.globalDemangledToMangled.hasKey(demangledStr):
          self.globalDemangledToMangled[demangledStr] = @[]
        self.globalDemangledToMangled[demangledStr].add(mangledStr)
    
    if "local" in j:
      for demangled, mangled in j["local"]:
        self.localDemangledToMangled[demangled] = mangled.getStr
    
    return true
    
  except Exception:
    return false
