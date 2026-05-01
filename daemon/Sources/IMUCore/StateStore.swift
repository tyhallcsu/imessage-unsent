import Foundation

public struct DetectorState: Codable, Equatable {
  public var lastSeenDateEdited: Int64 = 0
}

public final class StateStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() -> DetectorState {
    guard let data = try? Data(contentsOf: url) else { return DetectorState() }
    return (try? JSONDecoder().decode(DetectorState.self, from: data)) ?? DetectorState()
  }

  public func save(_ state: DetectorState) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder.pretty.encode(state)
    try data.write(to: url, options: .atomic)
  }
}

public extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

public extension JSONDecoder {
  static var imu: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
