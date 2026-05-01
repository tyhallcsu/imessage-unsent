public struct EventFilter {
  public var allow: [String]
  public var deny: [String]

  public init(allow: [String], deny: [String]) {
    self.allow = allow
    self.deny = deny
  }

  public func allows(_ event: RetractionEvent) -> Bool {
    if deny.contains(event.handle) {
      return false
    }
    if !allow.isEmpty, !allow.contains(event.handle) {
      return false
    }
    return true
  }
}
