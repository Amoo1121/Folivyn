import Darwin
import Foundation

/// Publishes a new local document without replacing an intervening directory entry.
/// Existing-document replacement remains in DocumentFile. This helper does not
/// establish metadata preservation or power-loss durability for either save path.
enum NewDocumentWriter {
    static func write(_ data: Data, to target: URL, beforePublish: (() throws -> Void)? = nil) throws {
        guard target.isFileURL, !target.path.utf8.contains(0) else {
            throw DocumentFileError.invalidURL(target)
        }
        let parent = target.deletingLastPathComponent()
        let directory = parent.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard directory >= 0 else { throw systemError() }
        defer { _ = Darwin.close(directory) }

        let temporary = ".folivyn-\(UUID().uuidString).tmp"
        // O_EXCL establishes ownership of this temporary name. Standard creation
        // permissions are filtered by the process umask and parent inheritance.
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard file >= 0 else { throw systemError() }
        var published = false
        defer {
            if !published { removeOwnedTemporary(file, named: temporary, in: directory) }
            _ = Darwin.close(file)
        }

        var created = stat()
        guard fstat(file, &created) == 0 else { throw systemError() }
        guard created.st_mode & S_IFMT == S_IFREG, created.st_uid == geteuid(), created.st_nlink == 1 else {
            throw systemError(EPERM)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw systemError(count == 0 ? EIO : errno) }
                offset += count
            }
        }
        while fsync(file) != 0 {
            if errno != EINTR { throw systemError() }
        }
        try beforePublish?()

        // Refuse a changed temporary name rather than publishing someone else's
        // entry. Cleanup uses the same descriptor identity and never recurses.
        guard ownsTemporary(file, named: temporary, in: directory) else { throw systemError(ESTALE) }
        let result = renameatx_np(directory, temporary, directory, target.lastPathComponent, UInt32(RENAME_EXCL))
        if result != 0 {
            let failure = errno
            if failure == EEXIST { throw DocumentFileError.externalConflict(target) }
            // Unsupported filesystems fail closed: never retry with plain rename.
            throw systemError(failure)
        }
        published = true
    }

    private static func ownsTemporary(_ file: Int32, named name: String, in directory: Int32) -> Bool {
        var descriptor = stat()
        var entry = stat()
        return fstat(file, &descriptor) == 0 &&
            fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
            descriptor.st_dev == entry.st_dev && descriptor.st_ino == entry.st_ino &&
            entry.st_mode & S_IFMT == S_IFREG && entry.st_uid == geteuid() && entry.st_nlink == 1
    }

    private static func removeOwnedTemporary(_ file: Int32, named name: String, in directory: Int32) {
        if ownsTemporary(file, named: name, in: directory) { _ = unlinkat(directory, name, 0) }
    }

    private static func systemError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
