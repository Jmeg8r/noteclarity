// JSON Formatter — compiled from src/main.ts.
// Exercises: commands, menu, editor.read, editor.write.
"use strict";

function transformJson(indent) {
    var selection = noteclarity.editor.getSelection();
    var usingSelection = selection.text.length > 0;
    var source = usingSelection ? selection.text : noteclarity.editor.getText();
    if (source.trim().length === 0) {
        noteclarity.ui.showNotification("JSON Formatter: nothing to format.");
        return;
    }
    var parsed;
    try {
        parsed = JSON.parse(source);
    } catch (e) {
        noteclarity.ui.showNotification("JSON Formatter: invalid JSON — " + e.message);
        return;
    }
    var result = indent > 0 ? JSON.stringify(parsed, null, indent) : JSON.stringify(parsed);
    if (usingSelection) {
        noteclarity.editor.replaceSelection(result);
    } else {
        noteclarity.editor.setText(result);
    }
    noteclarity.ui.showNotification(indent > 0 ? "JSON formatted." : "JSON minified.");
}

function activate(context) {
    noteclarity.commands.register("jsonFormatter.pretty", function () { transformJson(2); });
    noteclarity.commands.register("jsonFormatter.minify", function () { transformJson(0); });
    // Menu items for these commands are declared in plugin.json ("contributes.menus");
    // menu.addItem below demonstrates the dynamic route for a bonus entry.
    noteclarity.menu.addItem({ title: "Format JSON (4-space indent)", command: "jsonFormatter.pretty4" });
    noteclarity.commands.register("jsonFormatter.pretty4", function () { transformJson(4); });
}

function deactivate() {}
