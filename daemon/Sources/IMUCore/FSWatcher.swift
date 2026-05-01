import CoreServices
import Foundation

public struct FileChange: Equatable {
  public var size: UInt64
  public var delta: Int64
}

public final class FSWatcher {
  private let watchedFile: URL
  private let callback: (FileChange) -> Void
  private let queue = DispatchQueue(label: "com.imessage-unsent.fswatcher")
  private var stream: FSEventStreamRef?
  private var lastSize: UInt64 = 0
  private var pending: DispatchWorkItem?

  public init(watchedFile: URL, callback: @escaping (FileChange) -> Void) {
    self.watchedFile = watchedFile
    self.callback = callback
  }

  deinit {
    stop()
  }

  public func start() throws {
    stop()
    lastSize = currentSize()

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )

    let path = watchedFile.deletingLastPathComponent().path as CFString
    let paths = [path] as CFArray
    let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
    guard let created = FSEventStreamCreate(
      kCFAllocatorDefault,
      { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.scheduleCallback()
      },
      &context,
      paths,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.1,
      flags
    ) else {
      throw NSError(domain: "IMUFSWatcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create FSEventStream"])
    }

    stream = created
    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
  }

  public func stop() {
    pending?.cancel()
    pending = nil
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
  }

  private func scheduleCallback() {
    pending?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let size = self.currentSize()
      let delta = Int64(size) - Int64(self.lastSize)
      self.lastSize = size
      self.callback(FileChange(size: size, delta: delta))
    }
    pending = item
    queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
  }

  private func currentSize() -> UInt64 {
    let values = try? watchedFile.resourceValues(forKeys: [.fileSizeKey])
    return UInt64(values?.fileSize ?? 0)
  }
}
