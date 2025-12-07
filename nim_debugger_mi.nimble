# Package

version       = "0.1.0"
author        = "yesdrx"
description   = "GDB/MI proxy for Nim that handles symbol mangling/demangling"
license       = "MIT"
srcDir        = "src"
bin           = @["nim_debugger_mi"]

# Dependencies

requires "nim >= 1.6.0"

# Tasks

task build, "Build the nim_debugger_mi binary":
  exec "nim c -d:release src/nim_debugger_mi.nim"

task test, "Run tests":
  exec "nim c -r tests/test_transformer.nim"
