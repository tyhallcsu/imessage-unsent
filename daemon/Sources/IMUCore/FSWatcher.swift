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
  private let pollInterval: TimeInterval
  private let enableFSEvents: Bool
  private let handler: ChangeHandler
  private let queue: DispatchQueue
  private var stream: FSEventStreamRef?
  private var pendingCallback: DispatchWorkItem?
  private var pollTimer: DispatchSourceTimer?
  // -1 sentinel = never reported. Set to the current size on start() so the
  // first poll cycle does not spuriously fire on the file's pre-existing size.
  private var lastReportedSize: Int64 = -1

  public init(
    walURL: URL = defaultMessagesWalURL(),
    coalesceInterval: TimeInterval = 0.25,
    pollInterval: TimeInterval = 1.0,
    enableFSEvents: Bool = true,
    handler: @escaping ChangeHandler
  ) {
    self.walURL = walURL.standardizedFileURL
    self.watchRoot = walURL.deletingLastPathComponent().standardizedFileURL
    self.coalesceInterval = coalesceInterval
    self.pollInterval = pollInterval
    self.enableFSEvents = enableFSEvents
    self.handler = handler
    self.queue = DispatchQueue(label: "com.imu.watcher.fsevents")
  }

  deinit {
    stop()
  }

  public func start() throws {
    try queue.sync {
      guard stream == nil, pollTimer == nil else {
        return
      }

      guard FileManager.default.fileExists(atPath: watchRoot.path) else {
        throw FSWatcherError.parentDirectoryMissing(watchRoot.path)
      }

      if enableFSEvents {
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

      lastReportedSize = Self.fileSize(at: walURL)

      if pollInterval > 0 {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
          deadline: .now() + pollInterval,
          repeating: pollInterval,
          leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
          self?.pollWAL()
        }
        timer.resume()
        pollTimer = timer
      }
    }
  }

  public func stop() {
    queue.sync {
      pendingCallback?.cancel()
      pendingCallback = nil

      pollTimer?.cancel()
      pollTimer = nil

      if let activeStream = stream {
        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)
        stream = nil
      }
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

  /// Called by the polling timer on `queue`. Detects size changes that
  /// FSEvents may have missed (a known macOS quirk for high-frequency writes
  /// inside TCC-protected directories like `~/Library/Messages`). Issue #59.
  private func pollWAL() {
    let currentSize = Self.fileSize(at: walURL)
    guard currentSize != lastReportedSize else {
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
      let size = Self.fileSize(at: walURL)
      lastReportedSize = size
      handler(size)
    }

    pendingCallback = callback
    queue.asyncAfter(deadline: .now() + coalesceInterval, execute: callback)
  }
}

public func defaultMessagesWalURL(home: URL = imuUserHomeDirectory()) -> URL {
  home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Messages", isDirectory: true)
    .appendingPathComponent("chat.db-wal", isDirectory: false)
}
