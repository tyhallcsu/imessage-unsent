import Darwin
import Foundation

@_silgen_name("clonefile")
private func clonefile(
  _ src: UnsafePointer<CChar>,
  _ dst: UnsafePointer<CChar>,
  _ flags: UInt32
) -> Int32

public enum ArchiveCloner {
  public enum Outcome: Equatable {
    case cloned
    case unsupported(errno: Int32)
    case failed(errno: Int32)
  }

  public static func clone(from source: URL, to destination: URL) -> Outcome {
    return source.withUnsafeFileSystemRepresentation { srcPtrOpt in
      destination.withUnsafeFileSystemRepresentation { dstPtrOpt in
        guard let srcPtr = srcPtrOpt, let dstPtr = dstPtrOpt else {
          return .failed(errno: EINVAL)
        }
        let rc = clonefile(srcPtr, dstPtr, 0)
        if rc == 0 { return .cloned }
        let saved = errno
        switch saved {
        case ENOTSUP, EXDEV:
          return .unsupported(errno: saved)
        default:
          return .failed(errno: saved)
        }
      }
    }
  }
}
