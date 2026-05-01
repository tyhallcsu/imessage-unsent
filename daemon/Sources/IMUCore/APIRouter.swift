import Foundation

public final class APIRouter {
  private let archiveStore: ArchiveStore
  private let statusProvider: () -> WatchStatus

  public init(archiveStore: ArchiveStore, statusProvider: @escaping () -> WatchStatus) {
    self.archiveStore = archiveStore
    self.statusProvider = statusProvider
  }

  public func route(_ request: HTTPRequest) -> HTTPResponse {
    do {
      if request.method == "GET", request.path == "/ping" {
        return try json(statusProvider())
      }
      if request.method == "GET", request.path.hasPrefix("/archives?") || request.path == "/archives" {
        let query = URLComponents(string: "imu://local\(request.path)")?.queryItems ?? []
        let page = Int(query.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
        let limit = Int(query.first(where: { $0.name == "limit" })?.value ?? "50") ?? 50
        return try json(archiveStore.list(page: page, limit: limit))
      }
      if request.path.hasPrefix("/archives/") {
        let id = String(request.path.dropFirst("/archives/".count)).removingPercentEncoding ?? ""
        if request.method == "GET" {
          return HTTPResponse(body: try archiveStore.recoveryJSON(id: id))
        }
        if request.method == "DELETE" {
          try archiveStore.delete(id: id)
          return try json(["deleted": id])
        }
      }
      return try json(["error": "not found"], status: 404)
    } catch {
      return (try? json(["error": error.localizedDescription], status: 500)) ?? HTTPResponse(status: 500, body: Data())
    }
  }

  private func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
    HTTPResponse(status: status, body: try JSONEncoder.pretty.encode(value))
  }
}
