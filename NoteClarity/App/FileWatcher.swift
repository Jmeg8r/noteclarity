import Dispatch
import Darwin
import Foundation

/// Watches one file path for external changes via kqueue (vnode events).
/// Mechanism only — reload/prompt/missing policy lives in AppState, the same
/// split EditorController uses for its onEdit/onSelectionChange closures.
final class FileWatcher {
    enum ChangeKind { case modified, missing }

    var onChange: ((ChangeKind) -> Void)?

    private let path: String
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let debouncer = Debouncer(0.3)

    init(url: URL) {
        self.path = url.path
        arm()
    }

    deinit {
        source?.cancel()
        source = nil
    }

    /// Bracket AppState's atomic save so our own inode replacement is never
    /// reported as an external change. Re-arming after the write is required
    /// anyway: the atomic write leaves the old watched fd pointing at a
    /// dead inode.
    func pauseForOwnWrite() { teardown() }
    func resumeAfterOwnWrite() { arm() }

    private func arm() {
        teardown()
        let opened = path.withCString { open($0, O_EVTONLY) }
        // Unopenable now (deleted, perms): degrade to unwatched; the
        // didBecomeActive sweep in AppState is the backstop.
        guard opened >= 0 else { return }
        fd = opened
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: opened,
            // .attrib/.link/.revoke excluded: chmod/touch noise — the resolve
            // step re-reads content anyway, so only real mutations matter.
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main)
        src.setEventHandler { [weak self] in
            self?.debouncer.call { [weak self] in self?.resolve() }
        }
        src.setCancelHandler { close(opened) }
        source = src
        src.resume()
    }

    private func teardown() {
        debouncer.cancel()
        source?.cancel()   // cancel handler closes the captured fd
        source = nil
        fd = -1
    }

    private func resolve() {
        guard FileManager.default.fileExists(atPath: path) else {
            teardown()
            onChange?(.missing)
            return
        }
        // Present again — same inode (in-place write) or a new one (atomic
        // replace by another app). Re-arm against whatever is there now; the
        // caller diffs content before deciding anything happened.
        arm()
        onChange?(.modified)
    }
}
