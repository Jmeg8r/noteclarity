import Foundation
import Darwin

/// A single bounded read contract for open, reload and session restoration.
/// O_NONBLOCK also prevents an accidentally opened FIFO from hanging the app.
enum TextFileReader {
    static let sizeLimit = 50_000_000

    static func read(_ url: URL, limit: Int = sizeLimit) throws -> Data {
        precondition(limit >= 0 && limit < Int.max)
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: "NoteClarity.File", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Only regular text files can be opened."])
        }
        guard info.st_size <= limit else { throw tooLarge(limit) }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(65_536, limit - result.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - result.count else { throw tooLarge(limit) }
            result.append(chunk)
        }
        return result
    }

    private static func tooLarge(_ limit: Int) -> Error {
        NSError(domain: "NoteClarity.File", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "File exceeds the editor limit of \(limit) bytes."])
    }
}
