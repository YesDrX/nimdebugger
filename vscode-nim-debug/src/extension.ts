import * as vscode from 'vscode';
import * as child_process from 'child_process';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';

export function activate(context: vscode.ExtensionContext) {
    console.log('Nim Debugger extension activated');

    // Check installation on activation
    checkNimDebuggerMiInstallation();

    // Register commands
    context.subscriptions.push(
        vscode.commands.registerCommand('nim-debugger.installDebugger', installNimDebuggerMi)
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('nim-debugger.checkInstallation', checkNimDebuggerMiInstallation)
    );

    // Register debug configuration provider
    context.subscriptions.push(
        vscode.debug.registerDebugConfigurationProvider('nim', new NimDebugConfigurationProvider())
    );
}

export function deactivate() { }

class NimDebugConfigurationProvider implements vscode.DebugConfigurationProvider {
    async resolveDebugConfiguration(
        folder: vscode.WorkspaceFolder | undefined,
        config: vscode.DebugConfiguration,
        token?: vscode.CancellationToken
    ): Promise<vscode.DebugConfiguration | undefined> {

        // If no miDebuggerPath specified, try to find it
        if (!config.miDebuggerPath || config.miDebuggerPath === 'nim_debugger_mi') {
            const debuggerPath = await findNimDebuggerMi();
            if (debuggerPath) {
                config.miDebuggerPath = debuggerPath;
            } else {
                // Prompt user to install
                const choice = await vscode.window.showWarningMessage(
                    'nim-debugger-mi is not installed. Install it now?',
                    'Install', 'Cancel'
                );

                if (choice === 'Install') {
                    await installNimDebuggerMi();
                    const newPath = await findNimDebuggerMi();
                    if (newPath) {
                        config.miDebuggerPath = newPath;
                    } else {
                        return undefined; // Cancel debugging
                    }
                } else {
                    return undefined; // Cancel debugging
                }
            }
        }

        // Auto-detect cpptools on macOS and configure lldb-mi
        if (os.platform() === 'darwin') {
            const cppTools = vscode.extensions.getExtension('ms-vscode.cpptools');
            if (cppTools) {
                config.MIMode = 'lldb';

                let currentArgs = config.miDebuggerArgs || '';
                if (Array.isArray(currentArgs)) {
                    currentArgs = currentArgs.join(' ');
                }
                
                config.miDebuggerArgs = `${currentArgs} --lldb`;
            }
        }

        return config;
    }
}

async function findNimDebuggerMi(): Promise<string | null> {
    // Try common locations
    const possiblePaths = [
        path.join(os.homedir(), '.nimble', 'bin', 'nim_debugger_mi'),
        'nim_debugger_mi' // Will use PATH
    ];

    for (const p of possiblePaths) {
        if (await commandExists(p)) {
            return p;
        }
    }

    // Try 'which' command
    try {
        const result = await exec('which nim_debugger_mi');
        if (result.trim()) {
            return result.trim();
        }
    } catch (e) {
        // Command failed, continue
    }

    return null;
}

async function commandExists(command: string): Promise<boolean> {
    try {
        await exec(`command -v ${command}`);
        return true;
    } catch (e) {
        return false;
    }
}

function exec(command: string): Promise<string> {
    return new Promise((resolve, reject) => {
        child_process.exec(command, (error, stdout, stderr) => {
            if (error) {
                reject(error);
            } else {
                resolve(stdout);
            }
        });
    });
}

async function installNimDebuggerMi() {
    const terminal = vscode.window.createTerminal('Install nim-debugger-mi');
    terminal.show();

    // Try package name first, then GitHub URL as fallback
    terminal.sendText('echo "Attempting to install nim_debugger_mi from nimble packages..."');
    terminal.sendText('nimble install nim_debugger_mi -y || (echo "Package not found, installing from GitHub..." && nimble install https://github.com/YesDrX/nimdebugger -y)');

    vscode.window.showInformationMessage(
        'Installing nim-debugger-mi... Please wait for the installation to complete in the terminal.'
    );
}

async function checkNimDebuggerMiInstallation() {
    const debuggerPath = await findNimDebuggerMi();

    if (debuggerPath) {
        vscode.window.showInformationMessage(
            `nim-debugger-mi is installed at: ${debuggerPath}`
        );
    } else {
        const choice = await vscode.window.showWarningMessage(
            'nim-debugger-mi is not installed. Would you like to install it?',
            'Install', 'Later'
        );

        if (choice === 'Install') {
            await installNimDebuggerMi();
        }
    }
}
