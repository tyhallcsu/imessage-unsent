import Foundation

/// A cheap fingerprint of a file used to detect content changes that a
/// **size-only** comparison misses (#111 / F-H5).
///
/// SQLite doesn't truncate `chat.db-wal` on checkpoint — the WAL sits at its
/// high-water size while subsequent commits overwrite frames *in place*. In
/// that steady state a size comparator sees no change, so both the FSWatcher
/// poll fallback and the rolling snapshot buffer could go blind to the very
/// write they exist to catch. This fingerprint additionally carries the
/// nanosecond-granular mtime (APFS `st_mtimespec`) and the inode, so:
///
/// - a same-size in-place frame overwrite is caught by the changed mtime,
/// - a truncate-and-regrow to the same size is caught by mtime,
/// - a delete-and-recreate (WAL replaced) is caught by the changed inode,
/// - an ordinary append is caught by the changed size (as before).
///
/// It is computed from a single `stat(2)` — no file open, no extra read — so it
/// adds no meaningful CPU or I/O over the size-only check it replaces.
struct WALChangeSignature: Equatable {
  let size: Int64
  let mtimeSeconds: Int64
  let mtimeNanoseconds: Int64
  let inode: UInt64

  /// Sentinel for a missing/unreadable file — distinct from any real file
  /// (a real file, even empty, has size >= 0).
  static let absent = WALChangeSignature(size: -1, mtimeSeconds: -1, mtimeNanoseconds: -1, inode: 0)

  /// The size to surface to callers that still think in bytes (0 when absent).
  var byteSize: Int64 { size < 0 ? 0 : size }

  static func read(at url: URL) -> WALChangeSignature {
    var info = stat()
    guard stat(url.path, &info) == 0 else {
      return .absent
    }
    return WALChangeSignature(
      size: Int64(info.st_size),
      mtimeSeconds: Int64(info.st_mtimespec.tv_sec),
      mtimeNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      inode: UInt64(info.st_ino)
    )
  }
}
