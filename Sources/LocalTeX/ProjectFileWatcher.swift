import CoreServices
import Foundation

@MainActor
final class ProjectFileWatcher {
    private final class CallbackContext {
        weak var watcher: ProjectFileWatcher?
    }

    private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs |
        kFSEventStreamEventFlagUserDropped |
        kFSEventStreamEventFlagKernelDropped |
        kFSEventStreamEventFlagEventIdsWrapped |
        kFSEventStreamEventFlagRootChanged
    )
    private static let listingFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated |
        kFSEventStreamEventFlagItemRemoved |
        kFSEventStreamEventFlagItemRenamed |
        kFSEventStreamEventFlagMount |
        kFSEventStreamEventFlagUnmount
    )

    private let rootPath: String
    private let rootPrefix: String
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?
    private var pendingRefresh: DispatchWorkItem?

    init?(root: URL, onChange: @escaping @MainActor () -> Void) {
        rootPath = SharedProjectStore.canonicalPath(root)
        rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        self.onChange = onChange

        // The native stream owns the callback context without retaining the watcher.
        let callbackContext = CallbackContext()
        callbackContext.watcher = self
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let options = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
        )
        let stream = withExtendedLifetime(callbackContext) {
            FSEventStreamCreate(
                nil, { _, info, count, eventPaths, flags, _ in
                    guard let info else { return }
                    let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
                    let paths = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue()
                    MainActor.assumeIsolated {
                        context.watcher?.receive(paths: paths, count: count, flags: flags)
                    }
                },
                &context, [rootPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, options
            )
        }
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        pendingRefresh?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func receive(paths: NSArray, count: Int, flags: UnsafePointer<FSEventStreamEventFlags>) {
        let shouldRefresh = (0..<count).contains { index in
            if flags[index] & Self.rescanFlags != 0 { return true }
            guard flags[index] & Self.listingFlags != 0,
                  let path = paths[index] as? String else { return false }
            if path == rootPath { return true }
            guard path.hasPrefix(rootPrefix) else { return false }
            return path.dropFirst(rootPrefix.count).split(separator: "/").allSatisfy { $0.first != "." }
        }
        guard shouldRefresh else { return }

        pendingRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            self.onChange()
        }
        pendingRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: refresh)
    }
}
