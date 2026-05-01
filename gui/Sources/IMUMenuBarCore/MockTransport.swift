import Foundation

public final class MockTransport: SocketTransport {
  public var responses: [String: Data]

  public init(responses: [String: Data]) {
    self.responses = responses
  }

  public func send(method: String, path: String) throws -> Data {
    let key = "\(method) \(path)"
    if let response = responses[key] {
      return response
    }
    throw NSError(domain: "MockTransport", code: 404)
  }
}
