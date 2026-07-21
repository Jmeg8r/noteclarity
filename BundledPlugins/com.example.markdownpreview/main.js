// Markdown Preview — compiled from src/main.ts (no build tooling required).
// Exercises: ui.panel, editor.read, events, and the panel message bridge.
"use strict";

var mdPanel = null;
// Above this size, re-rendering the whole document on every debounced change
// would fight the editor for the main thread — preview suspends instead.
var MAX_LIVE_CHARS = 1500000;

function escapeHtml(s) {
    return s
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

// Scheme allowlist: document-controlled destinations must never become
// javascript:/file:/data: vectors inside the panel webview. Relative paths and
// fragments stay; unknown schemes render as plain text.
function safeUrl(raw, kind) {
    var trimmed = raw.trim();
    if (trimmed.charAt(0) === "#") return kind === "link" ? trimmed : null;
    var schemeMatch = trimmed.match(/^([A-Za-z][A-Za-z0-9+.-]*):/);
    if (!schemeMatch) return trimmed;
    var scheme = schemeMatch[1].toLowerCase();
    if (scheme === "http" || scheme === "https") return trimmed;
    if (kind === "link" && scheme === "mailto") return trimmed;
    return null;
}

// Inline markup. Code spans are split out first so markup inside them stays literal.
function inline(s) {
    var parts = s.split(/(`[^`\n]+`)/);
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i];
        if (/^`[^`\n]+`$/.test(p)) {
            out.push("<code>" + escapeHtml(p.slice(1, -1)) + "</code>");
            continue;
        }
        var t = escapeHtml(p);
        // Destinations were escapeHtml'd above, so quotes cannot break out of
        // the attribute; safeUrl() decides whether the URL is usable at all.
        t = t.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, function (_m, alt, url) {
            var safe = safeUrl(url, "image");
            return safe === null ? alt : '<img alt="' + alt + '" src="' + safe + '">';
        });
        t = t.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (_m, label, url) {
            var safe = safeUrl(url, "link");
            return safe === null ? label : '<a href="' + safe + '">' + label + "</a>";
        });
        t = t.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
        t = t.replace(/__([^_\n]+)__/g, "<strong>$1</strong>");
        t = t.replace(/\*([^*\n]+)\*/g, "<em>$1</em>");
        t = t.replace(/(^|[\s(])_([^_\n]+)_(?=[\s).,;:!?]|$)/g, "$1<em>$2</em>");
        t = t.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
        out.push(t);
    }
    return out.join("");
}

// Dependency-free line-based Markdown → HTML converter: headings, hr, fenced
// code, blockquotes, nested lists, paragraphs, and the inline set above.
function markdownToHtml(md) {
    var lines = md.replace(/\r\n?/g, "\n").split("\n");
    var out = [];
    var para = [];
    var listStack = [];
    var inCode = false;
    var codeLang = "";
    var codeBuf = [];
    var inQuote = false;

    function flushPara() {
        if (para.length) {
            out.push("<p>" + inline(para.join(" ")) + "</p>");
            para = [];
        }
    }
    function closeLists(depth) {
        while (listStack.length > depth) {
            out.push(listStack.pop() === "ul" ? "</ul>" : "</ol>");
        }
    }
    function closeQuote() {
        if (inQuote) {
            out.push("</blockquote>");
            inQuote = false;
        }
    }

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];

        if (inCode) {
            if (/^\s*```/.test(line)) {
                out.push('<pre><code class="lang-' + escapeHtml(codeLang) + '">' +
                    escapeHtml(codeBuf.join("\n")) + "</code></pre>");
                inCode = false;
                codeBuf = [];
            } else {
                codeBuf.push(line);
            }
            continue;
        }

        var fence = line.match(/^\s*```(\w*)/);
        if (fence) {
            flushPara(); closeLists(0); closeQuote();
            inCode = true;
            codeLang = fence[1] || "";
            continue;
        }

        var h = line.match(/^(#{1,6})\s+(.*)$/);
        if (h) {
            flushPara(); closeLists(0); closeQuote();
            var n = h[1].length;
            out.push("<h" + n + ">" + inline(h[2]) + "</h" + n + ">");
            continue;
        }

        if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
            flushPara(); closeLists(0); closeQuote();
            out.push("<hr>");
            continue;
        }

        var q = line.match(/^\s*>\s?(.*)$/);
        if (q) {
            flushPara(); closeLists(0);
            if (!inQuote) { out.push("<blockquote>"); inQuote = true; }
            out.push("<p>" + inline(q[1]) + "</p>");
            continue;
        }

        var li = line.match(/^(\s*)([-*+]|\d+\.)\s+(.*)$/);
        if (li) {
            flushPara(); closeQuote();
            var depth = Math.floor(li[1].replace(/\t/g, "  ").length / 2) + 1;
            var kind = /\d/.test(li[2]) ? "ol" : "ul";
            if (listStack.length > depth) {
                closeLists(depth);
            }
            while (listStack.length < depth) {
                out.push(kind === "ul" ? "<ul>" : "<ol>");
                listStack.push(kind);
            }
            out.push("<li>" + inline(li[3]) + "</li>");
            continue;
        }

        if (/^\s*$/.test(line)) {
            flushPara(); closeLists(0); closeQuote();
            continue;
        }

        closeLists(0); closeQuote();
        para.push(line.trim());
    }

    if (inCode) {
        out.push("<pre><code>" + escapeHtml(codeBuf.join("\n")) + "</code></pre>");
    }
    flushPara(); closeLists(0); closeQuote();
    return out.join("\n");
}

function render() {
    if (!mdPanel) return;
    var lang = noteclarity.editor.getLanguage();
    var text = noteclarity.editor.getText();
    var html;
    if (text.length > MAX_LIVE_CHARS) {
        html = "<div class='nc-hint'>Document too large for live preview.</div>";
    } else if (lang === "markdown" || lang === "plaintext") {
        html = markdownToHtml(text);
    } else {
        html = "<div class='nc-hint'>Active document language is “" + escapeHtml(lang) +
            "” — showing source.</div><pre class='nc-raw'>" + escapeHtml(text) + "</pre>";
    }
    mdPanel.postMessage({ type: "render", html: html });
}

function activate(context) {
    var panelHtml = context.readResource("panel.html");
    mdPanel = noteclarity.ui.registerPanel({
        id: "preview",
        title: "Markdown Preview",
        location: "right",
        html: panelHtml
    });
    mdPanel.onMessage(function (msg) {
        if (msg && msg.type === "ready") render();
    });
    noteclarity.events.on("document.changed", render);
    noteclarity.events.on("document.opened", render);
    noteclarity.events.on("language.changed", render);
    mdPanel.reveal();
    render();
}

function deactivate() {
    if (mdPanel) {
        mdPanel.dispose();
        mdPanel = null;
    }
}
