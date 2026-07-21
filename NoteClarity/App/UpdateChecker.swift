import AppKit
import Foundation

/// Hand-rolled update check against the GitHub releases API — zero
/// dependencies, no Sparkle. Auto checks are silent on every failure (and
/// leave lastCheckedAt untouched so a transient offline moment retries next
/// launch); the manual menu command always answers, with the concrete reason
/// on failure.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let lastCheckedKey = "nc.updateCheck.lastCheckedAt"
    private static let checkInterval: TimeInterval = 7 * 24 * 3600
    private static let releasesPage = URL(string: "https://github.com/Jmeg8r/noteclarity/releases/latest")!

    private static var apiURL: URL {
        // Testing seam, same pattern as NOTECLARITY_SUPPORT_DIR.
        if let override = ProcessInfo.processInfo.environment["NOTECLARITY_UPDATE_API"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/Jmeg8r/noteclarity/releases/latest")!
    }

    private var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func checkManually() { perform(silent: false) }

    func checkAutomaticallyIfDue() {
        guard AppSettings.shared.autoCheckForUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        perform(silent: true)
    }

    private func perform(silent: Bool) {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("NoteClarity/\(localVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { [weak self] in
                self?.handle(data: data, response: response, error: error, silent: silent)
            }
        }.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?, silent: Bool) {
        let tag: String? = {
            if error != nil { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, SemVer.parse(tag) != nil
            else { return nil }
            return tag
        }()

        guard let tag else {
            // Undeterminable (offline, 404 pre-first-release, malformed):
            // auto stays silent and does NOT advance lastCheckedAt.
            if !silent {
                alert(title: "Could not check for updates.",
                      body: error?.localizedDescription
                          ?? "The releases feed was unavailable or unreadable.",
                      showReleases: false)
            }
            return
        }

        UserDefaults.standard.set(Date(), forKey: Self.lastCheckedKey)
        if SemVer.isNewer(tag, than: localVersion) {
            alert(title: "NoteClarity \(tag) is available.",
                  body: "You are running \(localVersion).",
                  showReleases: true)
        } else if !silent {
            alert(title: "You're up to date.",
                  body: "NoteClarity \(localVersion) is the latest release.",
                  showReleases: false)
        }
    }

    private func alert(title: String, body: String, showReleases: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        if showReleases {
            alert.addButton(withTitle: "Open Releases Page")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesPage)
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
