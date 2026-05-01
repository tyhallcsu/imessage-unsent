import Foundation

public final class ArchiveStore {
  public let archivesDir: URL

  public init(archivesDir: URL) {
    self.archivesDir = archivesDir
  }

  public func list(page: Int = 1, limit: Int = 50) throws -> ArchiveListResponse {
    let dirs = try archiveDirectories()
    let safePage = max(page, 1)
    let safeLimit = max(min(limit, 200), 1)
    let start = min((safePage - 1) * safeLimit, dirs.count)
    let end = min(start + safeLimit, dirs.count)
    let summaries = try dirs[start..<end].map(summary)
    return ArchiveListResponse(page: safePage, limit: safeLimit, total: dirs.count, archives: summaries)
  }

  public func recoveryJSON(id: String) throws -> Data {
    let url = try archiveURL(id: id).appendingPathComponent("recovery.json")
    return try Data(contentsOf: url)
  }

  public func delete(id: String) throws {
    let url = try archiveURL(id: id)
    var trashed: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
  }

  public func count() -> Int {
    (try? archiveDirectories().count) ?? 0
  }

  public func prune(keepLast: Int) throws {
    guard keepLast >= 0 else { return }
    let dirs = try archiveDirectories()
    guard dirs.count > keepLast else { return }
    for url in dirs.dropFirst(keepLast) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func archiveDirectories() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: archivesDir.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: archivesDir,
      includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    .filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  private func archiveURL(id: String) throws -> URL {
    guard !id.isEmpty,
          id.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil,
          !id.hasPrefix(".") else {
      throw NSError(domain: "IMUArchiveStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid archive id"])
    }
    return archivesDir.appendingPathComponent(id, isDirectory: true)
  }

  private func summary(for url: URL) throws -> ArchiveSummary {
    let manifestURL = url.appendingPathComponent("manifest.json")
    let recoveryURL = url.appendingPathComponent("recovery.json")
    let manifest = try? JSONDecoder.imu.decode(Manifest.self, from: Data(contentsOf: manifestURL))
    let recovery = (try? JSONSerialization.jsonObject(with: Data(contentsOf: recoveryURL))) as? [String: Any]
    let recovered = recovery?["recovered"] as? [String: Any]
    let textB64 = recovered?["text_b64"] as? String
    let preview = textB64.flatMap { encoded -> String? in
      guard let data = Data(base64Encoded: encoded) else { return nil }
      return String(data: data, encoding: .utf8).map { String($0.prefix(120)) }
    }
    let candidate = recovery?["candidate"] as? [String: Any]
    return ArchiveSummary(
      id: url.lastPathComponent,
      rowid: manifest?.rowid ?? (candidate?["rowid"] as? NSNumber)?.int64Value,
      handle: manifest?.handle ?? recovery?["handle"] as? String,
      guid: manifest?.guid ?? candidate?["guid"] as? String,
      detectedAt: manifest?.detectedAt,
      recovered: textB64?.isEmpty == false,
      preview: preview,
      archiveDir: url.path
    )
  }
}
