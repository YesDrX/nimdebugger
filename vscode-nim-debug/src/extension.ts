import * as vscode from 'vscode';
import * as child_process from 'child_process';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';

export function activate(context: vscode.ExtensionContext) {
    console.log('Nim Debugger extension activated');

    // Check installation and updates periodically on activation
    checkNimDebuggerMiInstallationAndUpdates(context);

    // Register commands
    context.subscriptions.push(
        vscode.commands.registerCommand('nim-debugger.installDebugger', installNimDebuggerMi)
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('nim-debugger.checkInstallation', () => checkNimDebuggerMiInstallationAndUpdates(context))
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('nim-debugger.checkForUpdates', async () => {
            const installedVersion = await getInstalledVersion();
            if (!installedVersion) {
                vscode.window.showWarningMessage('nim-debugger-mi is not installed.');
                return;
            }
            
            const latestVersion = await getLatestVersion();
            if (!latestVersion) {
                vscode.window.showErrorMessage('Could not check for updates. Please try again later.');
                return;
            }
            
            if (compareVersions(latestVersion, installedVersion) > 0) {
                const choice = await vscode.window.showInformationMessage(
                    `nim-debugger-mi update available: ${installedVersion} → ${latestVersion}`,
                    'Update', 'Cancel'
                );
                
                if (choice === 'Update') {
                    await updateNimDebuggerMi();
                }
            } else {
                vscode.window.showInformationMessage(
                    `nim-debugger-mi is up to date (version ${installedVersion})`
                );
            }
        })
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
        if (!config.miDebuggerPath || config.miDebuggerPath.includes('nim_debugger_mi')) {
            const debuggerPath = await findNimDebuggerMi(config.miDebuggerPath);
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

async function findNimDebuggerMi(nim_debugger_mi : string = "nim_debugger_mi"): Promise<string | null> {
    // Try common locations
    const possiblePaths = [
        path.join(os.homedir(), '.nimble', 'bin', 'nim_debugger_mi'),
        nim_debugger_mi,
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

async function checkNimDebuggerMiInstallationAndUpdates(context: vscode.ExtensionContext) {
    const debuggerPath = await findNimDebuggerMi();

    if (debuggerPath) {
        vscode.window.showInformationMessage(
            `nim-debugger-mi is installed at: ${debuggerPath}`
        );
        // Check for updates periodically (at most once per week)
        await checkForUpdatesIfNeeded(context);
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

async function checkForUpdatesIfNeeded(context: vscode.ExtensionContext) {
    const LAST_CHECK_KEY = 'nimDebuggerMi.lastUpdateCheck';
    const ONE_WEEK_MS = 7 * 24 * 60 * 60 * 1000; // 7 days in milliseconds

    const lastCheck = context.globalState.get<number>(LAST_CHECK_KEY, 0);
    const now = Date.now();

    // Check if it's been more than a week since the last check
    if (now - lastCheck < ONE_WEEK_MS) {
        console.log('Update check skipped - checked recently');
        return;
    }

    // Update the last check timestamp
    await context.globalState.update(LAST_CHECK_KEY, now);

    // Perform the update check
    await checkForUpdates();
}

async function getInstalledVersion(): Promise<string | null> {
    try {
        const output = await exec('nimble dump nim_debugger_mi');
        // Parse output looking for: version: "X.Y.Z"
        const versionMatch = output.match(/version:\s*"([^"]+)"/);
        if (versionMatch && versionMatch[1]) {
            return versionMatch[1];
        }
    } catch (e) {
        // Package not installed or nimble not available
        console.error('Failed to get installed version:', e);
    }
    return null;
}

async function getLatestVersion(): Promise<string | null> {
    try {
        const output = await exec('nimble search nim_debugger_mi --ver');
        // Parse output looking for: versions: X.Y.Z, ...
        const versionMatch = output.match(/versions:\s*([0-9]+\.[0-9]+\.[0-9]+)/);
        if (versionMatch && versionMatch[1]) {
            return versionMatch[1];
        }
    } catch (e) {
        console.error('Failed to get latest version:', e);
    }
    return null;
}

function compareVersions(v1: string, v2: string): number {
    const parts1 = v1.split('.').map(Number);
    const parts2 = v2.split('.').map(Number);
    
    for (let i = 0; i < 3; i++) {
        const p1 = parts1[i] || 0;
        const p2 = parts2[i] || 0;
        if (p1 > p2) return 1;
        if (p1 < p2) return -1;
    }
    return 0;
}

async function checkForUpdates() {
    const installedVersion = await getInstalledVersion();
    if (!installedVersion) {
        return; // Not installed, nothing to update
    }

    const latestVersion = await getLatestVersion();
    if (!latestVersion) {
        console.log('Could not determine latest version');
        return;
    }

    if (compareVersions(latestVersion, installedVersion) > 0) {
        const choice = await vscode.window.showInformationMessage(
            `nim-debugger-mi update available: ${installedVersion} → ${latestVersion}`,
            'Update', 'Later'
        );

        if (choice === 'Update') {
            await updateNimDebuggerMi();
        }
    } else {
        console.log(`nim-debugger-mi is up to date (${installedVersion})`);
    }
}

async function updateNimDebuggerMi() {
    const terminal = vscode.window.createTerminal('Update nim-debugger-mi');
    terminal.show();

    // terminal.sendText('echo "Updating nim_debugger_mi..."');
    terminal.sendText('nimble install nim_debugger_mi -y');

    vscode.window.showInformationMessage(
        'Updating nim-debugger-mi... Please wait for the update to complete in the terminal.'
    );
}
