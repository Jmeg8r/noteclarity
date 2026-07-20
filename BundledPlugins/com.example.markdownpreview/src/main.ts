// Markdown Preview — TypeScript source. Compile with:
//   tsc src/main.ts --outFile main.js --target ES2019 --lib es2019,dom
/// <reference path="../../noteclarity.d.ts" />

/** Passed to activate() by the host (see README, "The activate context"). */
interface ExtensionContext {
    pluginId: string;
    pluginPath: string;
    storagePath: string;
    appVersion: string;
    /** Reads a file bundled inside this plugin's folder. */
    readResource(relativePath: string): string;
}

let mdPanel: PanelHandle | null = null;

function escapeHtml(s: string): string {
    return s
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

// Inline markup. Code spans are split out first so markup inside them stays literal.
function inline(s: string): string {
    const parts = s.split(/(`[^`\n]+`)/);
    const out: string[] = [];
    for (const p of parts) {
        if (/^`[^`\n]+`$/.test(p)) {
            out.push("<code>" + escapeHtml(p.slice(1, -1)) + "</code>");
            continue;
        }
        let t = escapeHtml(p);
        t = t.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, '<img alt="$1" src="$2">');
        t = t.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>');
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
function markdownToHtml(md: string): string {
    const lines = md.replace(/\r\n?/g, "\n").split("\n");
    const out: string[] = [];
    let para: string[] = [];
    const listStack: Array<"ul" | "ol"> = [];
    let inCode = false;
    let codeLang = "";
    let codeBuf: string[] = [];
    let inQuote = false;

    const flushPara = (): void => {
        if (para.length) {
            out.push("<p>" + inline(para.join(" ")) + "</p>");
            para = [];
        }
    };
    const closeLists = (depth: number): void => {
        while (listStack.length > depth) {
            out.push(listStack.pop() === "ul" ? "</ul>" : "</ol>");
        }
    };
    const closeQuote = (): void => {
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
            } else {
                codeBuf.push(line);
            }
            continue;
        }

        const fence = line.match(/^\s*```(\w*)/);
        if (fence) {
            flushPara(); closeLists(0); closeQuote();
            inCode = true;
            codeLang = fence[1] || "";
            continue;
        }

        const h = line.match(/^(#{1,6})\s+(.*)$/);
        if (h) {
            flushPara(); closeLists(0); closeQuote();
            const n = h[1].length;
            out.push(`<h${n}>` + inline(h[2]) + `</h${n}>`);
            continue;
        }

        if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
            flushPara(); closeLists(0); closeQuote();
            out.push("<hr>");
            continue;
        }

        const q = line.match(/^\s*>\s?(.*)$/);
        if (q) {
            flushPara(); closeLists(0);
            if (!inQuote) { out.push("<blockquote>"); inQuote = true; }
            out.push("<p>" + inline(q[1]) + "</p>");
            continue;
        }

        const li = line.match(/^(\s*)([-*+]|\d+\.)\s+(.*)$/);
        if (li) {
            flushPara(); closeQuote();
            const depth = Math.floor(li[1].replace(/\t/g, "  ").length / 2) + 1;
            const kind: "ul" | "ol" = /\d/.test(li[2]) ? "ol" : "ul";
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

function render(): void {
    if (!mdPanel) return;
    const lang = noteclarity.editor.getLanguage();
    const text = noteclarity.editor.getText();
    let html: string;
    if (lang === "markdown" || lang === "plaintext") {
        html = markdownToHtml(text);
    } else {
        html = "<div class='nc-hint'>Active document language is “" + escapeHtml(lang) +
            "” — showing source.</div><pre class='nc-raw'>" + escapeHtml(text) + "</pre>";
    }
    mdPanel.postMessage({ type: "render", html });
}

function activate(context: ExtensionContext): void {
    const panelHtml = context.readResource("panel.html");
    mdPanel = noteclarity.ui.registerPanel({
        id: "preview",
        title: "Markdown Preview",
        location: "right",
        html: panelHtml,
    });
    mdPanel.onMessage((msg: any) => {
        if (msg && msg.type === "ready") render();
    });
    noteclarity.events.on("document.changed", render);
    noteclarity.events.on("document.opened", render);
    noteclarity.events.on("language.changed", render);
    mdPanel.reveal();
    render();
}

function deactivate(): void {
    if (mdPanel) {
        mdPanel.dispose();
        mdPanel = null;
    }
}
