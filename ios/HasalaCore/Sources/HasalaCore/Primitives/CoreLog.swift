import os

public struct CoreLog: Sendable {
  public static let subsystem = "HasalaCore"

  public struct Field: Sendable {
    enum Value: Sendable {
      case count(Int64)
      case state(StaticString)
      case redacted(String)
    }

    let key: StaticString
    let value: Value

    public static func count(_ key: StaticString, _ n: some BinaryInteger) -> Field {
      Field(key: key, value: .count(Int64(clamping: n)))
    }

    public static func state(_ key: StaticString, _ name: StaticString) -> Field {
      Field(key: key, value: .state(name))
    }

    public static func redacted(_ key: StaticString, _ text: String) -> Field {
      Field(key: key, value: .redacted(text))
    }
  }

  private let logger: Logger

  public init(category: StaticString) {
    logger = Logger(subsystem: CoreLog.subsystem, category: "\(category)")
  }

  public func debug(_ event: StaticString, _ fields: Field...) { emit(.debug, event, fields) }
  public func info(_ event: StaticString, _ fields: Field...) { emit(.info, event, fields) }
  public func notice(_ event: StaticString, _ fields: Field...) { emit(.default, event, fields) }
  public func error(_ event: StaticString, _ fields: Field...) { emit(.error, event, fields) }
  public func fault(_ event: StaticString, _ fields: Field...) { emit(.fault, event, fields) }

  private func emit(_ level: OSLogType, _ event: StaticString, _ fields: [Field]) {
    let line = CoreLog.render(event, fields)
    if line.redacted.isEmpty {
      logger.log(level: level, "\(line.public, privacy: .public)")
    } else {
      logger.log(level: level, "\(line.public, privacy: .public) \(line.redacted, privacy: .private)")
    }
  }

  package static func render(_ event: StaticString, _ fields: [Field]) -> (public: String, redacted: String) {
    var open = "\(event)"
    var hidden: [String] = []
    for f in fields {
      switch f.value {
      case .count(let n): open += " \(f.key)=\(n)"
      case .state(let s): open += " \(f.key)=\(s)"
      case .redacted(let t): hidden.append("\(f.key)=\(t)")
      }
    }
    return (open, hidden.joined(separator: " "))
  }
}
