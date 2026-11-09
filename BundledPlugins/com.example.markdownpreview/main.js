"use strict";
// Markdown Preview — TypeScript source. Compile with:
//   tsc src/main.ts --outFile main.js --target ES2019 --lib es2019,dom
/// <reference path="../../noteclarity.d.ts" />
let mdPanel = null;
// Above this size, re-rendering the whole document on every debounced change
// would fight the editor for the main thread — preview suspends instead.
const MAX_LIVE_CHARS = 1500000;
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
    const trimmed = raw.trim();
    if (trimmed.charAt(0) === "#")
        return kind === "link" ? trimmed : null;
    const schemeMatch = trimmed.match(/^([A-Za-z][A-Za-z0-9+.-]*):/);
    if (!schemeMatch)
        return trimmed;
    const scheme = schemeMatch[1].toLowerCase();
    if (scheme === "http" || scheme === "https")
        return trimmed;
    if (kind === "link" && scheme === "mailto")
        return trimmed;
    return null;
}
// Inline markup. Code spans are split out first so markup inside them stays literal.
function inline(s) {
    const parts = s.split(/(`[^`\n]+`)/);
    const out = [];
    for (const p of parts) {
        if (/^`[^`\n]+`$/.test(p)) {
            out.push("<code>" + escapeHtml(p.slice(1, -1)) + "</code>");
            continue;
        }
        let t = escapeHtml(p);
        // Destinations were escapeHtml'd above, so quotes cannot break out of
        // the attribute; safeUrl() decides whether the URL is usable at all.
        t = t.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (_m, alt, url) => {
            const safe = safeUrl(url, "image");
            return safe === null ? alt : '<img alt="' + alt + '" src="' + safe + '">';
        });
        t = t.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, label, url) => {
            const safe = safeUrl(url, "link");
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
    const lines = md.replace(/\r\n?/g, "\n").split("\n");
    const out = [];
    let para = [];
    const listStack = [];
    let inCode = false;
    let codeLang = "";
    let codeBuf = [];
    let inQuote = false;
    const flushPara = () => {
        if (para.length) {
            out.push("<p>" + inline(para.join(" ")) + "</p>");
            para = [];
        }
    };
    const closeLists = (depth) => {
        while (listStack.length > depth) {
            out.push(listStack.pop() === "ul" ? "</ul>" : "</ol>");
        }
    };
    const closeQuote = () => {
        if (inQuote) {
            out.push("</blockquote>");
            inQuote = false;
        }
    };
    for (const line of lines) {
        if (inCode) {
            if (/^\s*```/.test(line)) {
                out.push('<pre><code class="lang-' + escapeHtml(codeLang) + '">' +
                    escapeHtml(codeBuf.join("\n")) + "</code></pre>");
                inCode = false;
                codeBuf = [];
            }
            else {
                codeBuf.push(line);
            }
            continue;
        }
        const fence = line.match(/^\s*```(\w*)/);
        if (fence) {
            flushPara();
            closeLists(0);
            closeQuote();
            inCode = true;
            codeLang = fence[1] || "";
            continue;
        }
        const h = line.match(/^(#{1,6})\s+(.*)$/);
        if (h) {
            flushPara();
            closeLists(0);
            closeQuote();
            const n = h[1].length;
            out.push(`<h${n}>` + inline(h[2]) + `</h${n}>`);
            continue;
        }
        if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
            flushPara();
            closeLists(0);
            closeQuote();
            out.push("<hr>");
            continue;
        }
        const q = line.match(/^\s*>\s?(.*)$/);
        if (q) {
            flushPara();
            closeLists(0);
            if (!inQuote) {
                out.push("<blockquote>");
                inQuote = true;
            }
            out.push("<p>" + inline(q[1]) + "</p>");
            continue;
        }
        const li = line.match(/^(\s*)([-*+]|\d+\.)\s+(.*)$/);
        if (li) {
            flushPara();
            closeQuote();
            const depth = Math.floor(li[1].replace(/\t/g, "  ").length / 2) + 1;
            const kind = /\d/.test(li[2]) ? "ol" : "ul";
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
            flushPara();
            closeLists(0);
            closeQuote();
            continue;
        }
        closeLists(0);
        closeQuote();
        para.push(line.trim());
    }
    if (inCode) {
        out.push("<pre><code>" + escapeHtml(codeBuf.join("\n")) + "</code></pre>");
    }
    flushPara();
    closeLists(0);
    closeQuote();
    return out.join("\n");
}
function render() {
    if (!mdPanel)
        return;
    const lang = noteclarity.editor.getLanguage();
    const text = noteclarity.editor.getText();
    let html;
    if (text.length > MAX_LIVE_CHARS) {
        html = "<div class='nc-hint'>Document too large for live preview.</div>";
    }
    else if (lang === "markdown" || lang === "plaintext") {
        html = markdownToHtml(text);
    }
    else {
        html = "<div class='nc-hint'>Active document language is “" + escapeHtml(lang) +
            "” — showing source.</div><pre class='nc-raw'>" + escapeHtml(text) + "</pre>";
    }
    mdPanel.postMessage({ type: "render", html });
}
function activate(context) {
    const panelHtml = context.readResource("panel.html");
    mdPanel = noteclarity.ui.registerPanel({
        id: "preview",
        title: "Markdown Preview",
        location: "right",
        html: panelHtml,
    });
    mdPanel.onMessage((msg) => {
        if (msg && msg.type === "ready")
            render();
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
