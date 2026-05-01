import CoreServices
import Foundation

public enum FSWatcherError: Error, Equatable, LocalizedError {
  case parentDirectoryMissing(String)
  case streamCreationFailed(String)

  public var errorDescription: String? {
    switch self {
    case let .parentDirectoryMissing(path):
      return "watch directory does not exist: \(path)"
    case let .streamCreationFailed(path):
      return "failed to create FSEvents stream for \(path)"
    }
  }
}

public final class FSWatcher {
  public typealias ChangeHandler = (Int64) -> Void

  private let walURL: URL
  private let watchRoot: URL
  private let coalesceInterval: TimeInterval
  private let handler: ChangeHandler
  private let queue: DispatchQueue
  private var stream: FSEventStreamRef?
  private var pendingCallback: DispatchWorkItem?

  public init(
    walURL: URL = defaultMessagesWalURL(),
    coalesceInterval: TimeInterval = 0.25,
    handler: @escaping ChangeHandler
  ) {
    self.walURL = walURL.standardizedFileURL
    self.watchRoot = walURL.deletingLastPathComponent().standardizedFileURL
    self.coalesceInterval = coalesceInterval
    self.handler = handler
    self.queue = DispatchQueue(label: "com.imu.watcher.fsevents")
  }

  deinit {
    stop()
  }

  public func start() throws {
    try queue.sync {
      guard stream == nil else {
        return
      }

      guard FileManager.default.fileExists(atPath: watchRoot.path) else {
        throw FSWatcherError.parentDirectoryMissing(watchRoot.path)
      }

      let eventLatency = min(coalesceInterval, 0.05)
      var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(self).toOpaque(),
        retain: nil,
        release: nil,
        copyDescription: nil
      )
      let pathsToWatch = [watchRoot.path] as CFArray
      let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents |
          kFSEventStreamCreateFlagUseCFTypes |
          kFSEventStreamCreateFlagNoDefer
      )

      guard let newStream = FSEventStreamCreate(
        kCFAllocatorDefault,
        Self.handleEvents,
        &context,
        pathsToWatch,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        eventLatency,
        flags
      ) else {
        throw FSWatcherError.streamCreationFailed(walURL.path)
      }

      FSEventStreamSetDispatchQueue(newStream, queue)
      guard FSEventStreamStart(newStream) else {
        FSEventStreamInvalidate(newStream)
        FSEventStreamRelease(newStream)
        throw FSWatcherError.streamCreationFailed(walURL.path)
      }

      stream = newStream
    }
  }

  public func stop() {
    queue.sync {
      pendingCallback?.cancel()
      pendingCallback = nil

      guard let activeStream = stream else {
        return
      }

      FSEventStreamStop(activeStream)
      FSEventStreamInvalidate(activeStream)
      FSEventStreamRelease(activeStream)
      stream = nil
    }
  }

  public static func fileSize(at url: URL) -> Int64 {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else {
      return 0
    }

    return size.int64Value
  }

  private static let handleEvents: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
    guard let info else {
      return
    }

    let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    watcher.handle(paths: paths.prefix(eventCount))
  }

  private func handle<S: Sequence>(paths: S) where S.Element == String {
    let targetPath = walURL.path
    let sawWalChange = paths.contains { path in
      URL(fileURLWithPath: path).standardizedFileURL.path == targetPath
    }

    guard sawWalChange else {
      return
    }

    scheduleCoalescedCallback()
  }

  private func scheduleCoalescedCallback() {
    guard pendingCallback == nil else {
      return
    }

    let callback = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }

      pendingCallback = nil
      handler(Self.fileSize(at: walURL))
    }

    pendingCallback = callback
    queue.asyncAfter(deadline: .now() + coalesceInterval, execute: callback)
  }
}

public func defaultMessagesWalURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Messages", isDirectory: true)
    .appendingPathComponent("chat.db-wal", isDirectory: false)
}
