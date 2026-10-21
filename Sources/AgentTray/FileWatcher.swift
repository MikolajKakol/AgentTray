import CoreServices
import Foundation

/// FSEvents stream over a set of directories, recursive, coalesced over 300 ms.
///
/// The handler gets the changed directory paths, or nil when FSEvents asks for a full
/// rescan (dropped events). It runs on a private serial queue.
final class FileWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([String]?) -> Void

    private let handler: Handler
    private let queue = DispatchQueue(label: "local.agenttray.fsevents")
    // Only touched on `queue`.
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        // No other references remain, so the stream can be torn down directly.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Replaces the watched set. A no-op when it did not change.
    func watch(_ paths: [String]) {
        let sorted = Array(Set(paths)).sorted()
        queue.async { [self] in
            guard sorted != watchedPaths else { return }
            watchedPaths = sorted
            stopStream()
            guard !sorted.isEmpty else { return }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray as? [String] ?? []
                let rescanFlags = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs
                        | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped
                )
                let needsRescan = (0..<count).contains { eventFlags[$0] & rescanFlags != 0 }
                watcher.handler(needsRescan ? nil : paths)
            }
            guard let newStream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                sorted as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.3,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            ) else { return }
            FSEventStreamSetDispatchQueue(newStream, queue)
            FSEventStreamStart(newStream)
            stream = newStream
        }
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
