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
    // Add .exe extension on Windows if not already present
    const isWindows = os.platform() === 'win32';
    const executableName = isWindows && !nim_debugger_mi.endsWith('.exe') 
        ? `${nim_debugger_mi}.exe` 
        : nim_debugger_mi;
    
    // Try common locations
    const possiblePaths = [
        path.join(os.homedir(), '.nimble', 'bin', executableName),
        nim_debugger_mi,
        executableName
    ];

    for (const p of possiblePaths) {
        if (fs.existsSync(p)) {
            console.log(`Found nim_debugger_mi at: ${p}`);
            return p;
        }
    }

    // Try platform-specific command to find executable in PATH
    try {
        const findCommand = isWindows ? 'where' : 'which';
        const result = await exec(`${findCommand} ${executableName}`);
        if (result.trim()) {
            // On Windows, 'where' may return multiple paths, take the first one
            const firstPath = result.trim().split('\n')[0];
            console.log(`Found nim_debugger_mi at: ${firstPath}`);
            return firstPath;
        }
    } catch (e) {
        // Command failed, continue
    }

    console.log('nim_debugger_mi not found');
    
    return null;
}

function getNimblePath(): string {
    // Try to get nimble path from Nim extension settings
    const nimConfig = vscode.workspace.getConfiguration('nim');
    const nimblePath = nimConfig.get<string>('nimblePath');
    if (nimblePath) {
        return nimblePath;
    }
    
    // Try from our own extension settings
    const debugConfig = vscode.workspace.getConfiguration('nim-debugger');
    const configNimblePath = debugConfig.get<string>('nimblePath');
    if (configNimblePath) {
        return configNimblePath;
    }
    
    // Default to 'nimble' assuming it's in PATH
    return 'nimble';
}

function exec(command: string): Promise<string> {
    return new Promise((resolve, reject) => {
        const isWindows = os.platform() === 'win32';
        
        // On Unix-like systems, source shell config files to get proper PATH
        let execCommand = command;
        if (!isWindows) {
            // Try to source common shell configuration files
            const shellConfigSources = [
                'source ~/.bashrc 2>/dev/null || true',
                'source ~/.bash_profile 2>/dev/null || true',
                'source ~/.profile 2>/dev/null || true',
                'source ~/.zshrc 2>/dev/null || true'
            ].join('; ');
            execCommand = `${shellConfigSources}; ${command}`;
        }
        
        const options: child_process.ExecOptions = {
            shell: isWindows ? 'powershell.exe' : '/bin/bash',
            env: { ...process.env }
        };
        
        // On Windows, add common nimble paths if not already in PATH
        if (isWindows && options.env) {
            const userProfile = process.env.USERPROFILE || '';
            const nimbleBinPath = path.join(userProfile, '.nimble', 'bin');
            if (!options.env.PATH?.includes(nimbleBinPath)) {
                options.env.PATH = `${nimbleBinPath};${options.env.PATH || ''}`;
            }
        }
        
        child_process.exec(execCommand, options, (error, stdout, stderr) => {
            if (error) {
                reject(error);
            } else {
                resolve(stdout.toString());
            }
        });
    });
}

async function installNimDebuggerMi() {
    const nimble = getNimblePath();
    const outputChannel = vscode.window.createOutputChannel('nim-debugger-mi Installation');
    outputChannel.show();

    return vscode.window.withProgress({
        location: vscode.ProgressLocation.Notification,
        title: 'Installing nim-debugger-mi',
        cancellable: false
    }, async (progress) => {
        progress.report({ message: 'Attempting to install from nimble packages...' });
        outputChannel.appendLine('Attempting to install nim_debugger_mi from nimble packages...');
        
        try {
            // Try package name first
            await runNimbleInstall(nimble, 'nim_debugger_mi', outputChannel);
            vscode.window.showInformationMessage('nim-debugger-mi installed successfully!');
        } catch (error) {
            // Fallback to GitHub URL
            outputChannel.appendLine('Package not found in nimble registry, trying GitHub...');
            progress.report({ message: 'Installing from GitHub...' });
            
            try {
                await runNimbleInstall(nimble, 'https://github.com/YesDrX/nimdebugger', outputChannel);
                vscode.window.showInformationMessage('nim-debugger-mi installed successfully from GitHub!');
            } catch (githubError) {
                const errorMsg = githubError instanceof Error ? githubError.message : String(githubError);
                outputChannel.appendLine(`Installation failed: ${errorMsg}`);
                vscode.window.showErrorMessage(`Failed to install nim-debugger-mi: ${errorMsg}`);
                throw githubError;
            }
        }
    });
}

function runNimbleInstall(nimble: string, packageOrUrl: string, outputChannel: vscode.OutputChannel): Promise<void> {
    return new Promise((resolve, reject) => {
        const args = ['install', packageOrUrl, '-y'];
        outputChannel.appendLine(`Running: ${nimble} ${args.join(' ')}`);
        
        const isWindows = os.platform() === 'win32';
        const env = { ...process.env };
        
        // On Windows, ensure .nimble/bin is in PATH
        if (isWindows) {
            const userProfile = process.env.USERPROFILE || '';
            const nimbleBinPath = path.join(userProfile, '.nimble', 'bin');
            if (!env.PATH?.includes(nimbleBinPath)) {
                env.PATH = `${nimbleBinPath};${env.PATH || ''}`;
            }
        }
        
        const proc = child_process.spawn(nimble, args, {
            env,
            shell: false  // Don't use shell to avoid platform-specific issues
        });
        
        proc.stdout.on('data', (data) => {
            outputChannel.append(data.toString());
        });
        
        proc.stderr.on('data', (data) => {
            outputChannel.append(data.toString());
        });
        
        proc.on('error', (error) => {
            outputChannel.appendLine(`\nError: ${error.message}`);
            reject(error);
        });
        
        proc.on('close', (code) => {
            if (code === 0) {
                outputChannel.appendLine('\nInstallation completed successfully.');
                resolve();
            } else {
                const error = new Error(`nimble install exited with code ${code}`);
                outputChannel.appendLine(`\nInstallation failed with exit code ${code}`);
                reject(error);
            }
        });
    });
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
        const nimble = getNimblePath();
        const output = await exec(`"${nimble}" dump nim_debugger_mi`);
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
        const nimble = getNimblePath();
        const output = await exec(`"${nimble}" search nim_debugger_mi --ver`);
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
    const nimble = getNimblePath();
    const outputChannel = vscode.window.createOutputChannel('nim-debugger-mi Update');
    outputChannel.show();

    return vscode.window.withProgress({
        location: vscode.ProgressLocation.Notification,
        title: 'Updating nim-debugger-mi',
        cancellable: false
    }, async (progress) => {
        progress.report({ message: 'Updating package...' });
        outputChannel.appendLine('Updating nim_debugger_mi...');
        
        try {
            await runNimbleInstall(nimble, 'nim_debugger_mi', outputChannel);
            vscode.window.showInformationMessage('nim-debugger-mi updated successfully!');
        } catch (error) {
            const errorMsg = error instanceof Error ? error.message : String(error);
            outputChannel.appendLine(`Update failed: ${errorMsg}`);
            vscode.window.showErrorMessage(`Failed to update nim-debugger-mi: ${errorMsg}`);
        }
    });
}
