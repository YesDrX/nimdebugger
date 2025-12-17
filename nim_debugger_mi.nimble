# Package

version       = "0.4.0"
author        = "yesdrx"
description   = "GDB/LLDB/MI proxy for Nim that handles symbol mangling/demangling"
license       = "MIT"
srcDir        = "src"
bin           = @["nim_debugger_mi"]

# Dependencies

requires "nim >= 1.6.0"
requires "glob >= 0.1.0"
requires "subprocess >= 0.2.1"

# Tasks

task build, "Build the nim_debugger_mi binary":
  exec "nim c -d:release src/nim_debugger_mi.nim"

task test, "Run tests":
  exec "nim c -r tests/test_transformer.nim"
