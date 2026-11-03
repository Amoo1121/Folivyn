import AppKit
import Darwin

/// Observes the file and its containing directory: the latter keeps atomic
/// replacement and delete/recreate visible after the original inode disappears.
/// Events are hints only. The caller must reread and compare its disk snapshot.
@MainActor
final class FileChangeMonitor {
    private let url: URL
    private let changed: () -> Void
    private let queue = DispatchQueue(label: "Folivyn.file-events", qos: .utility)
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var stopped = false

    init(url: URL, changed: @escaping () -> Void) {
        self.url = url
        self.changed = changed
        directorySource = observe(url.deletingLastPathComponent(), isDirectory: true)
        fileSource = observe(url, isDirectory: false)
    }

    private func observe(_ url: URL, isDirectory: Bool) -> DispatchSourceFileSystemObject? {
        let descriptor = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == (isDirectory ? S_IFDIR : S_IFREG) else {
            Darwin.close(descriptor)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke], queue: queue)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleCheck() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        guard !stopped else { return }
        // Coalesce a burst, but don't postpone forever during continuous writes.
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !self.stopped else { return }
            self.pending = nil
            self.fileSource?.cancel()
            self.fileSource = self.observe(self.url, isDirectory: false)
            self.changed()
        }
    }

    func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        fileSource?.cancel()
        directorySource?.cancel()
        fileSource = nil
        directorySource = nil
    }

    deinit {
        pending?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
    }
}
