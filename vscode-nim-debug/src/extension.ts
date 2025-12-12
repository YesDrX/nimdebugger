import * as vscode from 'vscode';
import * as cp from 'child_process';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import * as util from 'util';

const execFile = util.promisify(cp.execFile);
const outputChannel = vscode.window.createOutputChannel('Nim Debugger');

// Configuration
const UPDATE_CHECK_INTERVAL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const STORAGE_KEY_LAST_UPDATE = 'nim_debugger_mi_last_update_check';
const PACKAGE_NAME = 'nim_debugger_mi';

function log(message: string, showChannel = false) {
    const timestamp = new Date().toISOString().split('T')[1].slice(0, -1);
    outputChannel.appendLine(`[${timestamp}] ${message}`);
    if (showChannel) outputChannel.show(true);
}

export async function activate(context: vscode.ExtensionContext) {
    log(`Activation started. Platform: ${os.platform()}`);

    context.subscriptions.push(
        vscode.commands.registerCommand('nim-debugger.installDebugger', () => {
            log('Manual install triggered');
            installOrUpdateDebugger(true);
        }),
        vscode.commands.registerCommand('nim-debugger.checkForUpdates', () => {
            log('Manual update check triggered');
            manualUpdateCheck();
        })
    );

    context.subscriptions.push(
        vscode.debug.registerDebugConfigurationProvider('nim', new NimDebugConfigurationProvider())
    );

    performStartupChecks(context).catch(err => log(`Startup error: ${err}`));
}

export function deactivate() {}

/**
 * Startup Logic
 */
async function performStartupChecks(context: vscode.ExtensionContext) {
    const executable = await findExecutable(PACKAGE_NAME);
    if (!executable) {
        log('Debugger not found on startup.');
        const choice = await vscode.window.showInformationMessage(
            `The '${PACKAGE_NAME}' is required for debugging.`,
            'Install Now', 'Cancel'
        );
        if (choice === 'Install Now') await installOrUpdateDebugger(true);
        return;
    }
    log(`Debugger found at: ${executable}`);

    const lastCheck = context.globalState.get<number>(STORAGE_KEY_LAST_UPDATE, 0);
    const now = Date.now();
    
    if (now - lastCheck > UPDATE_CHECK_INTERVAL_MS) {
        log('Checking for updates (scheduled)...');
        await context.globalState.update(STORAGE_KEY_LAST_UPDATE, now);
        
        const updateAvailable = await checkForUpdateAvailability();
        if (updateAvailable) {
            const choice = await vscode.window.showInformationMessage(
                `Update available for ${PACKAGE_NAME}.`,
                'Update', 'Later'
            );
            if (choice === 'Update') await installOrUpdateDebugger(false);
        }
    }
}

async function manualUpdateCheck() {
    outputChannel.show();
    log('Checking for updates (manual)...');
    
    if (!(await findExecutable(PACKAGE_NAME))) {
        vscode.window.showWarningMessage(`${PACKAGE_NAME} is not installed.`);
        return;
    }

    if (await checkForUpdateAvailability(true)) {
        const choice = await vscode.window.showInformationMessage(
            `Update available for ${PACKAGE_NAME}.`,
            'Update', 'Cancel'
        );
        if (choice === 'Update') await installOrUpdateDebugger(false);
    } else {
        vscode.window.showInformationMessage('Extension is up to date.');
    }
}

/**
 * Installation via Terminal
 */
async function installOrUpdateDebugger(isInstall: boolean) {
    const action = isInstall ? 'Installing' : 'Updating';
    log(`${action} ${PACKAGE_NAME} via Terminal...`);

    const nimbleExec = await findNimble();
    if (!nimbleExec) {
        vscode.window.showErrorMessage('Could not find "nimble". Please install Nim.');
        return;
    }

    const env = { ...process.env };
    const nimbleDir = path.dirname(nimbleExec);
    const pathKey = Object.keys(env).find(k => k.toLowerCase() === 'path') || 'PATH';
    const delimiter = os.platform() === 'win32' ? ';' : ':';
    env[pathKey] = `${nimbleDir}${delimiter}${env[pathKey] || ''}`;

    const term = vscode.window.createTerminal({
        name: 'Nim Debugger Installer',
        env: env,
        message: `Starting ${action}...`
    });

    term.show();
    // Accept defaults (-y). 
    // If there's a permission error, user can type password in terminal or see the error.
    term.sendText(`nimble install ${PACKAGE_NAME} -y`);

    vscode.window.showInformationMessage(`Check the "Nim Debugger Installer" terminal for progress.`);
}

/**
 * Robust Version Checking
 */
async function checkForUpdateAvailability(verbose = false): Promise<boolean> {
    const nimbleExec = await findNimble();
    if (!nimbleExec) return false;

    try {
        const env = getNimbleEnv();
        // Force no color to simplify parsing (though we also strip ANSI later)
        const opts = { env };

        // 1. Get Local Version
        let localVer = '0.0.0';
        try {
            const { stdout } = await execFile(nimbleExec, ['dump', PACKAGE_NAME], opts);
            // Robust extract: find 'version:', then grab the first thing that looks like a digit.digit.digit inside quotes
            const cleanOut = stripAnsi(stdout);
            const match = cleanOut.match(/version:\s*"(\d+\.\d+\.\d+)"/);
            if (match) localVer = match[1];
            if(verbose) log(`Local detection: extracted ${localVer} from dump.`);
        } catch (e) { if(verbose) log('Local version check failed'); }

        // 2. Get Remote Version
        let remoteVer = '0.0.0';
        try {
            // Using --ver to get list
            const { stdout } = await execFile(nimbleExec, ['search', PACKAGE_NAME, '--ver', '--noColor'], opts);
            const cleanOut = stripAnsi(stdout); // Double safety against ANSI codes
            
            // Find ALL version strings in the output
            // This ignores "versions:" prefix and just grabs anything looking like X.Y.Z
            const versionPattern = /(\d+\.\d+\.\d+)/g;
            const allVersions = [...cleanOut.matchAll(versionPattern)].map(m => m[1]);
            
            if (allVersions.length > 0) {
                // Deduplicate
                const uniqueVersions = [...new Set(allVersions)];
                
                // Sort Ascending (Oldest -> Newest)
                uniqueVersions.sort(compareVersions);
                
                // Last is newest
                remoteVer = uniqueVersions[uniqueVersions.length - 1];
                
                if(verbose) {
                    log(`Raw remote versions found: ${JSON.stringify(allVersions)}`);
                    log(`Sorted unique versions: ${JSON.stringify(uniqueVersions)}`);
                    log(`Selected latest remote: ${remoteVer}`);
                }
            } else {
                if(verbose) log(`No version pattern matched in search output:\n${cleanOut}`);
            }

        } catch (e) { if(verbose) log(`Remote version check failed: ${e}`); }

        const needsUpdate = compareVersions(remoteVer, localVer) > 0;
        log(`Version check: Local=${localVer}, Remote=${remoteVer}. Needs update: ${needsUpdate}`);
        return needsUpdate;

    } catch (error) {
        log(`Error checking versions: ${error}`);
        return false;
    }
}

// Regex to strip ANSI escape codes (colors, cursor moves, etc)
function stripAnsi(str: string): string {
    return str.replace(/[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g, '');
}

function compareVersions(v1: string, v2: string): number {
    const p1 = v1.split('.').map(Number);
    const p2 = v2.split('.').map(Number);
    for (let i = 0; i < 3; i++) {
        const n1 = p1[i] || 0;
        const n2 = p2[i] || 0;
        if (n1 > n2) return 1;
        if (n1 < n2) return -1;
    }
    return 0;
}

/**
 * Path Utilities
 */
function getNimbleEnv(): NodeJS.ProcessEnv {
    const env = { ...process.env };
    const pathKey = Object.keys(env).find(k => k.toLowerCase() === 'path') || 'PATH';
    const nimbleBin = path.join(os.homedir(), '.nimble', 'bin');
    const delimiter = os.platform() === 'win32' ? ';' : ':';
    env[pathKey] = `${nimbleBin}${delimiter}${env[pathKey] || ''}`;
    return env;
}

async function findNimble(): Promise<string | null> {
    const config = vscode.workspace.getConfiguration('nim').get<string>('nimblePath');
    if (config && fs.existsSync(config)) return config;
    let nimblePath = await findExecutable('nimble');
    log(`Nimble path resolved to: ${nimblePath}`);
    return nimblePath;
}

async function findExecutable(binName: string): Promise<string | null> {
    const isWin = os.platform() === 'win32';
    const candidates = isWin && !binName.match(/\.(cmd|exe)$/) 
        ? [`${binName}.cmd`, `${binName}.exe`, binName] 
        : [binName];

    const env = getNimbleEnv();
    const pathKey = Object.keys(env).find(k => k.toLowerCase() === 'path') || 'PATH';
    const dirs = (env[pathKey] || '').split(os.platform() === 'win32' ? ';' : ':');
    
    dirs.unshift(process.cwd());
    dirs.unshift(path.join(os.homedir(), '.nimble', 'bin'));

    for (const dir of [...new Set(dirs)]) {
        if (!dir) continue;
        for (const name of candidates) {
            const fullPath = path.join(dir, name);
            if (fs.existsSync(fullPath)) return fullPath;
        }
    }
    return null;
}

class NimDebugConfigurationProvider implements vscode.DebugConfigurationProvider {
    async resolveDebugConfiguration(
        folder: vscode.WorkspaceFolder | undefined,
        config: vscode.DebugConfiguration
    ): Promise<vscode.DebugConfiguration | undefined> {
        
        // 1. Auto-detect Debugger Path (nim_debugger_mi)
        if (!config.miDebuggerPath) {
            const found = await findExecutable(PACKAGE_NAME);
            if (found) {
                config.miDebuggerPath = found;
            } else {
                const choice = await vscode.window.showWarningMessage(
                    `${PACKAGE_NAME} missing. Install now?`, 'Install'
                );
                if (choice === 'Install') {
                    await installOrUpdateDebugger(true);
                    vscode.window.showInformationMessage('Restart debugging after installation completes.');
                }
                return undefined;
            }
        }

        // 2. macOS & CppTools Integration
        if (os.platform() === 'darwin') {
            log('Running on macOS, checking for C/C++ Extension for lldb-mi ...');
            if (config.MIMode !== 'lldb') {
                log(`Overriding MIMode from '${config.MIMode}' to 'lldb' for macOS compatibility.`);
            }

            const cppToolsId = 'ms-vscode.cpptools';
            const cppTools = vscode.extensions.getExtension(cppToolsId);
            
            if (cppTools) {
                log('Detected C/C++ Extension. Configuring lldb mode.');

                let args = config.miDebuggerArgs || '';
                if (Array.isArray(args)) args = args.join(' ');
                
                // Add --lldb flag to the nim_debugger_mi wrapper if missing
                if (!args.includes('--lldb')) {
                    config.miDebuggerArgs = `${args} --lldb`.trim();
                }

                // Optional: Check for bundled lldb-mi for debugging purposes
                const bundledMiPath = path.join(
                    cppTools.extensionPath, 
                    'debugAdapters', 
                    'lldb-mi', 
                    'bin', 
                    'lldb-mi'
                );
                if (fs.existsSync(bundledMiPath)) {
                    log(`Found bundled lldb-mi at: ${bundledMiPath}`);
                    if (!args.includes('--lldb')) {
                        log('Appending bundled lldb-mi path to miDebuggerArgs: --lldb=' + bundledMiPath);
                        config.miDebuggerArgs = `${args} --lldb`.trim() + '=' + bundledMiPath;
                    }
                } else {
                    log('Bundled lldb-mi not found in C/C++ Extension.');
                    log('Ensure that lldb-mi is installed and available in PATH for debugging to work correctly.');
                }
            } else {
                // CPP Tools NOT found
                log('C/C++ Extension (ms-vscode.cpptools) missing on macOS.');
                
                const choice = await vscode.window.showErrorMessage(
                    'The C/C++ Extension (ms-vscode.cpptools) is required for debugging on macOS to provide LLDB support.',
                    'Install', 'Cancel'
                );

                if (choice === 'Install') {
                    log('User chose to install C/C++ Extension. Opening marketplace...');
                    // Open the extension details page in VS Code
                    await vscode.commands.executeCommand('extension.open', cppToolsId);
                }

                // Abort debugging because we cannot configure the environment correctly without it
                return undefined;
            }
        }

        return config;
    }
}