// Document Statistics — TypeScript source. Compile with:
//   tsc src/main.ts --outFile main.js --target ES2019 --lib es2019,dom
/// <reference path="../../noteclarity.d.ts" />

interface ExtensionContext {
    pluginId: string;
    pluginPath: string;
    storagePath: string;
    appVersion: string;
    readResource(relativePath: string): string;
}

interface TextStats {
    chars: number;
    words: number;
    lines: number;
    minutes: number;
}

let statsPanel: PanelHandle | null = null;
const READING_WPM = 200;
// Above this size, per-keystroke full-document counting would fight the editor
// for the main thread — statistics suspend instead (documented threshold).
const MAX_LIVE_CHARS = 1500000;

function countText(text: string): TextStats {
    const words = (text.match(/[\p{L}\p{N}_'’-]+/gu) || []).length;
    const lines = text.length === 0 ? 1 : text.split("\n").length;
    const minutes = words === 0 ? 0 : Math.max(1, Math.round(words / READING_WPM));
    return { chars: text.length, words, lines, minutes };
}

function update(): void {
    if (!statsPanel) return;
    const text = noteclarity.editor.getText();
    if (text.length > MAX_LIVE_CHARS) {
        statsPanel.postMessage({
            type: "stats",
            tooLarge: true,
            path: noteclarity.editor.getFilePath(),
        });
        return;
    }
    const selection = noteclarity.editor.getSelection();
    statsPanel.postMessage({
        type: "stats",
        doc: countText(text),
        sel: selection.text.length > 0 ? countText(selection.text) : null,
        path: noteclarity.editor.getFilePath(),
    });
}

function activate(context: ExtensionContext): void {
    const panelHtml = context.readResource("panel.html");
    statsPanel = noteclarity.ui.registerPanel({
        id: "stats",
        title: "Statistics",
        location: "bottom",
        html: panelHtml,
    });
    statsPanel.onMessage((msg: any) => {
        if (msg && msg.type === "ready") update();
    });
    noteclarity.events.on("document.changed", update);
    noteclarity.events.on("document.opened", update);
    noteclarity.events.on("document.saved", update);
    noteclarity.events.on("selection.changed", update);
    statsPanel.reveal();
    update();
}

function deactivate(): void {
    if (statsPanel) {
        statsPanel.dispose();
        statsPanel = null;
    }
}
