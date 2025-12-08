# Nim Debugger Extension - Development Guide

## Setup

1. Install dependencies:
```bash
npm install
```

2. Compile TypeScript:
```bash
npm run compile
```

## Testing Locally

1. Open this folder in VSCode
2. Press `F5` to launch Extension Development Host
3. In the new VSCode window, open a Nim project
4. Try the debugging features

## Publishing

1. Install vsce:
```bash
npm install -g @vscode/vsce
```

2. Package the extension:
```bash
vsce package
```

3. Publish:
```bash
vsce publish
```

## Debugging the Extension

- Set breakpoints in `src/extension.ts`
- Press `F5` to start debugging
- Check Debug Console for logs
