// Shedman Merge Helper — activates for shedman config --review staging
// workspaces (identified by a `.shedman/` marker directory) and focuses
// the Source Control panel. No-op in any other workspace.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

let attempted = false;

function tryFocusScm() {
    if (attempted) return;
    attempted = true;
    vscode.commands.executeCommand('workbench.view.scm').then(undefined, () => {});
}

function activate(_context) {
    const folders = vscode.workspace.workspaceFolders;
    if (!folders || folders.length === 0) return;
    if (!fs.existsSync(path.join(folders[0].uri.fsPath, '.shedman'))) return;
    tryFocusScm();
}

function deactivate() {}

module.exports = { activate, deactivate };
