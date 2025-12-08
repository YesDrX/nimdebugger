# Nim Debugger - VSCode Extension

A VSCode extension that provides seamless native debugging for Nim with automatic symbol demangling.

## Features

- **Automatic Installation Check**: Detects if `nim-debugger-mi` is installed
- **One-Click Installation**: Install `nim-debugger-mi` directly from VSCode
- **Debug Configuration Snippets**: Pre-configured debug templates for Nim programs
- **Automatic Path Detection**: Finds `nim_debugger_mi` in `~/.nimble/bin` or PATH
- **Symbol Demangling**: Shows readable variable and function names during debugging

## Requirements

- [Nim](https://nim-lang.org/) installed
- [Nimble](https://github.com/nim-lang/nimble) package manager
- **macOS only**: [C/C++ Extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools) for VSCode (provides lldb-mi)

## Installation

1. Install from the VSCode Marketplace (search for "Nim Debugger")
2. The extension will prompt you to install `nim-debugger-mi` if not found
3. Click "Install" to automatically run `nimble install nim_debugger_mi`

## Usage

### Quick Start

1. Open a Nim project
2. Press `F5` or go to Run > Start Debugging
3. Select "Nim: Debug (Native)" from the configuration list
4. Set breakpoints and start debugging!

### Manual Configuration

Add to your `.vscode/launch.json`:

#### Linux/WSL
```json
{
    "name": "Debug Nim",
    "type": "cppdbg",
    "request": "launch",
    "program": "${workspaceFolder}/${fileBasenameNoExtension}",
    "miDebuggerPath": "${userHome}/.nimble/bin/nim_debugger_mi",
    "miDebuggerArgs": "", // you may specify gdb path by --gdb-path=/path/to/your/gdb
    "MIMode": "gdb",
    "args": [],
    "cwd": "${workspaceFolder}"
}
```

#### Mac (Apple Silicon)
```json
{
    "name": "Debug Nim",
    "type": "cppdbg",
    "request": "launch",
    "program": "${workspaceFolder}/${fileBasenameNoExtension}",
    "miDebuggerPath": "${userHome}/.nimble/bin/nim_debugger_mi",
    "miDebuggerArgs": "--lldb", //if --lldb is specified, it will try to load lldb-mi from ms-vscode.cpptools; you may specify --lldb-path as well
    "MIMode": "lldb",
    "args": [],
    "cwd": "${workspaceFolder}"
}
```

### Commands

- **Nim: Install nim-debugger-mi** - Install or reinstall the debugger proxy
- **Nim: Check nim-debugger-mi Installation** - Verify installation status

## What Gets Transformed

The extension uses `nim-debugger-mi` to transform symbols:

**Variables:**
- `localVar_1` → `localVar`
- `T5_` → `[tmp5]` (compiler temporaries)
- `FR_` → `[StackFrame]`

**Functions:**
- `_ZN4test4mainE` → `test::main`
- `myFunc__hello_u6` → `myFunc`

**Debug Console:**
- Type `p myVar` instead of `p myVar_1`
- All commands work with demangled names

## Building from Source

```bash
cd vscode-nim-debug
npm install
npm run compile
```

Press `F5` in VSCode to launch the extension development host.

## License

MIT - see LICENSE file

## Author

yesdrx

## Links

- [GitHub Repository](https://github.com/YesDrX/nimdebugger)
- [Report Issues](https://github.com/YesDrX/nimdebugger/issues)
