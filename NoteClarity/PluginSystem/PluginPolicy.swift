import Foundation
import CryptoKit

// MARK: - Path policy

/// Single authority for turning plugin-controlled strings (IDs, entry points,
/// resource paths) into filesystem locations. Everything here is Foundation-only
/// so the unit suite can exercise the containment rules directly.
enum PluginPathPolicy {
    static let maxIDLength = 128

    /// Reverse-DNS-safe plugin ID: ASCII alphanumerics joined by `.`/`-`/`_`,
    /// starting and ending alphanumeric. The ID doubles as the storage
    /// filename, so this charset is also the filesystem-safety guarantee —
    /// no separators, no traversal, no leading dot.
    static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...maxIDLength).contains(bytes.count), bytes.count == id.count else { return false }
        guard !id.contains("..") else { return false }
        func isAlnum(_ c: UInt8) -> Bool {
            (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
        }
        guard isAlnum(bytes.first!), isAlnum(bytes.last!) else { return false }
        let punctuation: Set<UInt8> = [UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_")]
        return bytes.allSatisfy { isAlnum($0) || punctuation.contains($0) }
    }

    /// Resolves `relative` against `root` and returns the resolved URL only if
    /// it stays inside the resolved root. Symlinks are followed on BOTH sides
    /// before comparing, so neither `..` segments nor a symlink planted inside
    /// the plugin folder can reach outside it.
    static func containedURL(root: URL, relative: String) -> URL? {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.contains("\0")
        else { return nil }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = resolvedRoot.appendingPathComponent(relative)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else { return nil }
        return resolved
    }
}

// MARK: - Code identity

/// Grants are bound to the plugin bytes the user actually approved (manifest +
/// entry point), so replacing either file — or editing the permission list —
/// forces a fresh review instead of silently inheriting the old grant.
enum PluginIdentity {
    static func digest(manifestData: Data, mainData: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: manifestData)
        hasher.update(data: mainData)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func digest(directory: URL, mainURL: URL) -> String? {
        guard let manifest = try? Data(contentsOf: directory.appendingPathComponent("plugin.json")),
              let main = try? Data(contentsOf: mainURL)
        else { return nil }
        return digest(manifestData: manifest, mainData: main)
    }
}

// MARK: - Manifest validation

/// A manifest that passed every policy check, with its entry point resolved to
/// a contained on-disk location. Only validated plugins are ever instantiated.
struct ValidatedPlugin {
    let manifest: PluginManifest
    let directory: URL
    let mainURL: URL
}

struct PluginValidationFailure: LocalizedError {
    let problems: [String]
    var errorDescription: String? { problems.joined(separator: " · ") }
}

enum PluginManifestValidator {
    static let supportedAPIMajor = 1
    static let supportedAPIMinor = 0
    private static let maxNameLength = 100
    private static let maxVersionLength = 40
    private static let maxAuthorLength = 200
    private static let maxDescriptionLength = 2000
    private static let maxContributionIDLength = 128
    private static let maxTitleLength = 100

    static func validate(_ manifest: PluginManifest, directory: URL) -> Result<ValidatedPlugin, PluginValidationFailure> {
        var problems: [String] = []

        if !PluginPathPolicy.isValidID(manifest.id) {
            problems.append("invalid plugin id (allowed: ASCII letters/digits joined by . - _, max \(PluginPathPolicy.maxIDLength) chars)")
        }
        if manifest.name.isEmpty || manifest.name.count > maxNameLength {
            problems.append("name must be 1–\(maxNameLength) characters")
        }
        if manifest.version.isEmpty || manifest.version.count > maxVersionLength {
            problems.append("version must be 1–\(maxVersionLength) characters")
        }
        if let author = manifest.author, author.count > maxAuthorLength {
            problems.append("author exceeds \(maxAuthorLength) characters")
        }
        if let description = manifest.description, description.count > maxDescriptionLength {
            problems.append("description exceeds \(maxDescriptionLength) characters")
        }

        // API compatibility: same major, minor no newer than the host speaks.
        let apiParts = manifest.apiVersion.split(separator: ".").map { Int($0) }
        if apiParts.isEmpty || apiParts.contains(nil) {
            problems.append("apiVersion '\(manifest.apiVersion)' is not a number pair like \"1.0\"")
        } else {
            let major = apiParts[0]!
            let minor = apiParts.count > 1 ? apiParts[1]! : 0
            if major != supportedAPIMajor || minor > supportedAPIMinor {
                problems.append("apiVersion \(manifest.apiVersion) is not supported (host API is \(supportedAPIMajor).\(supportedAPIMinor))")
            }
        }

        if let permissions = manifest.permissions {
            for permission in permissions where PluginPermission(rawValue: permission) == nil {
                problems.append("unknown permission '\(permission)'")
            }
            if Set(permissions).count != permissions.count {
                problems.append("duplicate entries in permissions")
            }
        }

        var declaredCommandIDs = Set<String>()
        for command in manifest.contributes?.commands ?? [] {
            if command.id.isEmpty || command.id.count > maxContributionIDLength {
                problems.append("command id must be 1–\(maxContributionIDLength) characters")
            }
            if command.title.isEmpty || command.title.count > maxTitleLength {
                problems.append("command '\(command.id)' title must be 1–\(maxTitleLength) characters")
            }
            if !declaredCommandIDs.insert(command.id).inserted {
                problems.append("duplicate command id '\(command.id)'")
            }
        }
        for menu in manifest.contributes?.menus ?? [] where !declaredCommandIDs.contains(menu.command) {
            problems.append("menu references undeclared command '\(menu.command)'")
        }
        for panel in manifest.contributes?.panels ?? [] {
            if let id = panel.id, id.isEmpty || id.count > maxContributionIDLength {
                problems.append("panel id must be 1–\(maxContributionIDLength) characters")
            }
            if let location = panel.location, PanelLocation(rawValue: location) == nil {
                problems.append("panel location '\(location)' must be left, right or bottom")
            }
        }

        // Entry point: relative, contained after symlink resolution, and a real file.
        var mainURL: URL?
        if let contained = PluginPathPolicy.containedURL(root: directory, relative: manifest.main) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: contained.path, isDirectory: &isDir), !isDir.boolValue {
                mainURL = contained
            } else {
                problems.append("main '\(manifest.main)' does not exist in the plugin folder")
            }
        } else {
            problems.append("main '\(manifest.main)' must be a relative path inside the plugin folder")
        }

        guard problems.isEmpty, let mainURL else {
            return .failure(PluginValidationFailure(problems: problems))
        }
        return .success(ValidatedPlugin(manifest: manifest, directory: directory, mainURL: mainURL))
    }
}

// MARK: - Grant store

struct PluginGrant: Equatable {
    var permissions: Set<String>
    var identity: String
}

/// Persisted permission grants keyed by plugin ID, each bound to the code
/// identity the user approved. UserDefaults-backed; the suite is injectable so
/// tests never touch the real domain.
final class PluginGrantStore {
    private let defaults: UserDefaults
    private static let v2Key = "nc.plugin.grants.v2"
    /// Pre-identity grants ("nc.plugin.grants", [id: [permission]]).
    static let legacyKey = "nc.plugin.grants"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var raw: [String: [String: Any]] {
        get { defaults.dictionary(forKey: Self.v2Key) as? [String: [String: Any]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.v2Key) }
    }

    func grant(for id: String) -> PluginGrant? {
        guard let entry = raw[id],
              let permissions = entry["permissions"] as? [String],
              let identity = entry["identity"] as? String
        else { return nil }
        return PluginGrant(permissions: Set(permissions), identity: identity)
    }

    func setGrant(_ grant: PluginGrant, for id: String) {
        var all = raw
        all[id] = ["permissions": grant.permissions.sorted(), "identity": grant.identity]
        raw = all
    }

    func removeGrant(for id: String) {
        var all = raw
        all.removeValue(forKey: id)
        raw = all
    }

    func legacyPermissions(for id: String) -> [String]? {
        (defaults.dictionary(forKey: Self.legacyKey) as? [String: [String]])?[id]
    }

    /// One-time v1 adoption. Legacy grants predate identity binding; they are
    /// bound to whatever is on disk NOW, and the legacy entry is consumed so
    /// adoption can never repeat against different bytes.
    func adoptLegacyGrant(for id: String, permissions: [String], identity: String) -> PluginGrant {
        let grant = PluginGrant(permissions: Set(permissions), identity: identity)
        setGrant(grant, for: id)
        var legacy = defaults.dictionary(forKey: Self.legacyKey) as? [String: [String]] ?? [:]
        legacy.removeValue(forKey: id)
        if legacy.isEmpty {
            defaults.removeObject(forKey: Self.legacyKey)
        } else {
            defaults.set(legacy, forKey: Self.legacyKey)
        }
        return grant
    }
}
