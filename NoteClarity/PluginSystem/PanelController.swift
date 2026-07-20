import Foundation
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
final class PanelController: NSObject, Identifiable {
    let pluginID: String
    let panelID: String
    let title: String
    let location: PanelLocation
    let webView: WKWebView

    /// Stable identity used by the panel tab UI.
    var id: String { pluginID + "." + panelID }

    private var loaded = false
    private var outgoingQueue: [String] = []
    var onMessageCallbacks: [JSValue] = []
    weak var instance: PluginInstance?

    init(pluginID: String, panelID: String, title: String, location: PanelLocation,
         html: String, baseURL: URL?, instance: PluginInstance?) {
        self.pluginID = pluginID
        self.panelID = panelID
        self.title = title
        self.location = location
        self.instance = instance

        let configuration = WKWebViewConfiguration()
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
        webView.loadHTMLString(html, baseURL: baseURL)
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
}

extension PanelController: WKNavigationDelegate {
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
