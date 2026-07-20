// JSON Formatter — TypeScript source. Compile with:
//   tsc src/main.ts --outFile main.js --target ES2019 --lib es2019,dom
/// <reference path="../../noteclarity.d.ts" />

interface ExtensionContext {
    pluginId: string;
    pluginPath: string;
    storagePath: string;
    appVersion: string;
    readResource(relativePath: string): string;
}

function transformJson(indent: number): void {
    const selection = noteclarity.editor.getSelection();
    const usingSelection = selection.text.length > 0;
    const source = usingSelection ? selection.text : noteclarity.editor.getText();
    if (source.trim().length === 0) {
        noteclarity.ui.showNotification("JSON Formatter: nothing to format.");
        return;
    }
    let parsed: unknown;
    try {
        parsed = JSON.parse(source);
    } catch (e) {
        noteclarity.ui.showNotification("JSON Formatter: invalid JSON — " + (e as Error).message);
        return;
    }
    const result = indent > 0 ? JSON.stringify(parsed, null, indent) : JSON.stringify(parsed);
    if (usingSelection) {
        noteclarity.editor.replaceSelection(result);
    } else {
        noteclarity.editor.setText(result);
    }
    noteclarity.ui.showNotification(indent > 0 ? "JSON formatted." : "JSON minified.");
}

function activate(context: ExtensionContext): void {
    noteclarity.commands.register("jsonFormatter.pretty", () => transformJson(2));
    noteclarity.commands.register("jsonFormatter.minify", () => transformJson(0));
    // Menu items for these commands are declared in plugin.json ("contributes.menus");
    // menu.addItem below demonstrates the dynamic route for a bonus entry.
    noteclarity.menu.addItem({ title: "Format JSON (4-space indent)", command: "jsonFormatter.pretty4" });
    noteclarity.commands.register("jsonFormatter.pretty4", () => transformJson(4));
}

function deactivate(): void {}
