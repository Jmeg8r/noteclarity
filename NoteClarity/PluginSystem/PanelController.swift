import Foundation
import AppKit
import WebKit
import JavaScriptCore

/// One plugin-contributed webview panel.
///
/// Bridge protocol (documented in the README):
/// - Panel → host: `window.noteclarity.postMessage(msg)` (injected at document
///   start, backed by a `WKScriptMessageHandler`) invokes every callback the
///   plugin registered with `PanelHandle.onMessage`.
/// - Host → panel: `PanelHandle.postMessage(msg)` evaluates
///   `window.__noteclarity_receive(msg)` in the webview. Messages queue until the
///   page finishes loading, so no message is dropped during startup.
///
/// Security boundary (P1-01): the panel renders the plugin's local document and
/// nothing else. The only navigation ever allowed is the host's own initial
/// load; user clicks on https links open in the default browser; every other
/// scheme and all subframe navigation is refused. Unless the plugin holds the
/// `network` permission, a content rule list additionally blocks http(s)/ws
/// subresource loads, so `ui.panel` alone can never reach the network. Bridge
/// messages are accepted only from the main frame's local (file) origin.
final class PanelController: NSObject, Identifiable {
    let pluginID: String
    let panelID: String
    let title: String
    let location: PanelLocation
    let webView: WKWebView

    /// Stable identity used by the panel tab UI.
    var id: String { pluginID + "." + panelID }

    private var loaded = false
    private var initialLoadApproved = false
    private var outgoingQueue: [String] = []
    var onMessageCallbacks: [JSValue] = []
    weak var instance: PluginInstance?

    init(pluginID: String, panelID: String, title: String, location: PanelLocation,
         html: String, baseURL: URL, instance: PluginInstance?, networkAllowed: Bool) {
        self.pluginID = pluginID
        self.panelID = panelID
        self.title = title
        self.location = location
        self.instance = instance

        let configuration = WKWebViewConfiguration()
        // Panels are ephemeral render surfaces — no cookies/local storage
        // shared with (or persisted for) anything else.
        configuration.websiteDataStore = .nonPersistent()
        let contentController = WKUserContentController()
        let bridge = """
        window.noteclarity = {
            postMessage: function (m) {
                window.webkit.messageHandlers.noteclarity.postMessage(m === undefined ? null : m);
            }
        };
        """
        contentController.addUserScript(WKUserScript(source: bridge,
                                                     injectionTime: .atDocumentStart,
                                                     forMainFrameOnly: true))
        configuration.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // Weak proxy: WKUserContentController retains its handler strongly.
        contentController.add(WeakScriptMessageHandler(self), name: "noteclarity")
        webView.navigationDelegate = self

        if networkAllowed {
            webView.loadHTMLString(html, baseURL: baseURL)
        } else {
            // The rule list compiles asynchronously; the panel HTML must not
            // load before the block is attached. On compile failure we fail
            // CLOSED — a broken rule list must not silently open the network.
            Self.withRemoteBlockRuleList { [weak self] ruleList in
                guard let self else { return }
                guard let ruleList else {
                    NSLog("[NoteClarity] panel %@ refused: remote-block rule list failed to compile", self.id)
                    self.webView.loadHTMLString(
                        "<p style=\"font: 12px -apple-system; padding: 12px\">Panel unavailable: the network isolation rules could not be compiled.</p>",
                        baseURL: nil)
                    return
                }
                self.webView.configuration.userContentController.add(ruleList)
                self.webView.loadHTMLString(html, baseURL: baseURL)
            }
        }
    }

    func postToWebview(_ message: Any?) {
        let payload = Self.jsonString(message ?? NSNull()) ?? "null"
        if loaded {
            evaluate(payload)
        } else {
            outgoingQueue.append(payload)
        }
    }

    private func evaluate(_ jsonPayload: String) {
        let js = "window.__noteclarity_receive && window.__noteclarity_receive(\(jsonPayload));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "noteclarity")
        webView.navigationDelegate = nil
        onMessageCallbacks.removeAll()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }

    static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is NSNull || value is NSNumber || value is NSString else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Remote-block rule list

    private static let ruleListIdentifier = "nc.panel.block-remote"
    private static let ruleListJSON = """
    [
      {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}}
    ]
    """
    private static var cachedRuleList: WKContentRuleList?
    private static var ruleListWaiters: [(WKContentRuleList?) -> Void] = []
    private static var ruleListCompiling = false

    /// Compiles (once) and hands back the shared remote-block rule list on the
    /// main queue. `nil` means compilation failed.
    private static func withRemoteBlockRuleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let cached = cachedRuleList {
            completion(cached)
            return
        }
        ruleListWaiters.append(completion)
        guard !ruleListCompiling else { return }
        ruleListCompiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleListIdentifier,
            encodedContentRuleList: ruleListJSON) { ruleList, error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("[NoteClarity] content rule list compile failed: %@", error.localizedDescription)
                }
                cachedRuleList = ruleList
                ruleListCompiling = false
                let waiters = ruleListWaiters
                ruleListWaiters.removeAll()
                for waiter in waiters { waiter(ruleList) }
            }
        }
    }
}

extension PanelController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The one permitted in-panel navigation: the host's own loadHTMLString.
        if !initialLoadApproved,
           navigationAction.navigationType == .other,
           navigationAction.targetFrame?.isMainFrame == true {
            initialLoadApproved = true
            decisionHandler(.allow)
            return
        }
        // https links leave the panel for the default browser; everything else
        // (http, file, javascript:, custom schemes, subframes) is refused.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           url.scheme?.lowercased() == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let queued = outgoingQueue
        outgoingQueue.removeAll()
        for payload in queued { evaluate(payload) }
    }
}

extension PanelController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "noteclarity", instance?.context != nil else { return }
        // Only the document we loaded may talk to the plugin: main frame,
        // local (file) origin. Anything else that somehow runs script does
        // not reach the bridge.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "file"
        else { return }
        let body = message.body
        for callback in onMessageCallbacks {
            callback.call(withArguments: [body])
        }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
