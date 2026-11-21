import CoreJSON
import CorePrimitives
import CoreTime
import Foundation
import HasalaText

public enum BlobKind: String, Sendable {
  case ops
  case rawBody = "raw_body"
}

public enum WireDecodeError: Error, Equatable, Sendable {
  case unknownNewerVersion(String)
  case setAside(String)

  public var message: String {
    switch self {
    case .unknownNewerVersion(let m), .setAside(let m): m
    }
  }
}

public enum OpValidationError: Error, Equatable, Sendable {
  case invalid(String)
  case unknownNewerVersion(String)
}

public enum OpCodec {
  public static func decodeBlobOps(_ bytes: some Collection<UInt8>) throws(WireDecodeError) -> [Op] {
    let doc = try parseBody(bytes, what: "op blob")
    try requireIntegerLiteral(doc, "v", what: "op blob")
    _ = try readVersion(doc, what: "op blob")
    guard doc["kind"]?.stringValue == BlobKind.ops.rawValue else {
      throw .setAside("blob kind is \(showValue(doc["kind"])), not \"ops\"")
    }
    let raw = doc["ops"]
    guard let raw, !raw.isNull else { return [] }
    guard let list = raw.arrayValue else { throw .setAside("ops is not an array") }
    var out: [Op] = []
    out.reserveCapacity(list.count)
    for (i, o) in list.enumerated() { out.append(try decodeOp(o, index: i)) }
    return out
  }

  public static func kindOf(_ bytes: some Collection<UInt8>) throws(WireDecodeError) -> BlobKind {
    let doc = try parseBody(bytes, what: "blob")
    let kind = doc["kind"]
    if let s = kind?.stringValue, let k = BlobKind(rawValue: s) { return k }
    if kind == nil || kind?.stringValue == "" { throw .setAside("blob has no kind") }
    throw .setAside("blob kind is \(showValue(kind))")
  }

  static func parseBody(_ bytes: some Collection<UInt8>, what: String) throws(WireDecodeError) -> JSONObject {
    let doc: JSONValue
    do {
      doc = try JSONParser.parse(bytes, refuseLoneSurrogates: true)
    } catch {
      throw .setAside("\(what): body is not valid JSON (\(bytes.count) bytes)")
    }
    guard let o = doc.objectValue else { throw .setAside("\(what): body is not a JSON object") }
    return o
  }

  static func requireIntegerLiteral(_ holder: JSONObject, _ key: String, what: String) throws(WireDecodeError) {
    guard case .number(let n)? = holder[key] else { return }
    let src = n.literal
    guard n.isIntegerLiteral else {
      throw .setAside("\(what): \(key) is written as \(src), which Go refuses as a non-integer literal")
    }
    if !fitsSafeInteger(src) {
      throw .setAside(
        "\(what): \(key) is \(src), outside the range a JSON number carries exactly — "
          + "Go's int64 can hold it and this executor cannot")
    }
  }

  static func fitsSafeInteger(_ literal: String) -> Bool {
    guard let v = Int64(literal) else { return false }
    return v >= -JSONNumber.maxSafeInteger && v <= JSONNumber.maxSafeInteger
  }

  static func integer(_ v: JSONValue?) -> Int64? {
    guard case .number(let n)? = v else { return nil }
    return n.int64Value
  }

  static func readVersion(_ doc: JSONObject, what: String) throws(WireDecodeError) -> Int64 {
    guard let v = integer(doc["v"]) else { throw .setAside("\(what): version is \(showValue(doc["v"]))") }
    if v > Int64(SchemaVersion.current) + 1 { throw .setAside("\(what): version \(v) is not valid") }
    if v > Int64(SchemaVersion.current) {
      throw .unknownNewerVersion("\(what) is v\(v), this build supports v\(SchemaVersion.current)")
    }
    if v < 1 { throw .setAside("\(what): version \(v) is not valid") }
    return v
  }

  static func decodeOp(_ raw: JSONValue, index i: Int) throws(WireDecodeError) -> Op {
    guard let o = raw.objectValue else { throw .setAside("op \(i): not a JSON object") }
    try requireIntegerLiteral(o, "v", what: "op \(i)")
    try requireIntegerLiteral(o, "parent_version", what: "op \(i)")
    guard let v = integer(o["v"]) else { throw .setAside("op \(i): version is \(showValue(o["v"]))") }
    if v > Int64(SchemaVersion.current) + 1 { throw .setAside("op \(i): version \(v) is not valid") }
    if v > Int64(SchemaVersion.current) {
      throw .unknownNewerVersion("op \(i) is v\(v), this build supports v\(SchemaVersion.current)")
    }

    var authoredAt = o["authored_at"]
    if let s = authoredAt?.stringValue {
      do {
        authoredAt = .string(try canonicalTime(s))
      } catch {
        throw .setAside(timeMessage(s, error))
      }
    }
    var entity = o["entity"]
    if entity?.isNull == true { entity = nil }
    var ingest = o["ingest_id"]
    if ingest?.stringValue == "" { ingest = nil }

    let fields = RawFields(
      v: v, type: o["type"], opID: o["op_id"], authoredAt: authoredAt, entity: entity,
      parentVersion: o["parent_version"] ?? .null, ingestID: ingest, payload: o["payload"])
    do {
      return try validate(fields)
    } catch {
      switch error {
      case .unknownNewerVersion(let m): throw .unknownNewerVersion(m)
      case .invalid(let m): throw .setAside("op \(i): \(m)")
      }
    }
  }

  struct RawFields {
    var v: Int64
    var type: JSONValue?
    var opID: JSONValue?
    var authoredAt: JSONValue?
    var entity: JSONValue?
    var parentVersion: JSONValue
    var ingestID: JSONValue?
    var payload: JSONValue?
  }

  static func validate(_ f: RawFields) throws(OpValidationError) -> Op {
    let opIDText = f.opID?.stringValue ?? showValue(f.opID)
    if f.v > Int64(SchemaVersion.current) + 1 { throw .invalid("version \(f.v) is not valid") }
    if f.v > Int64(SchemaVersion.current) { throw .unknownNewerVersion("op \(opIDText) is v\(f.v)") }
    if f.v < 1 { throw .invalid("version \(f.v) is not valid") }
    guard let typeString = f.type?.stringValue, let type = OpType(rawValue: typeString) else {
      throw .invalid("unknown type \(showValue(f.type))")
    }
    if f.v < Int64(type.minVersion) { throw .invalid("type \(type.rawValue) requires schema v\(type.minVersion)") }
    if type == .txnDuplicateDisposition { try validateDuplicateDisposition(f.payload) }
    guard let opID = f.opID?.stringValue, !opID.isEmpty else { throw .invalid("op_id is empty") }
    guard let s = f.authoredAt?.stringValue else {
      throw .invalid("want an RFC3339 timestamp, got \(showValue(f.authoredAt))")
    }
    let authoredAt: String
    do { authoredAt = try canonicalTime(s) } catch { throw .invalid(timeMessage(s, error)) }

    var entity: EntityRef?
    var parentVersion: Int64?
    if type.isParentFree {
      if f.entity != nil { throw .invalid("\(type.rawValue) is parent-free and must not name an entity") }
      if !f.parentVersion.isNull {
        throw .invalid("\(type.rawValue) is parent-free and must not carry a parent_version")
      }
    } else {
      guard let e = f.entity else { throw .invalid("\(type.rawValue) must name an entity") }
      guard let kind = e["kind"]?.stringValue, !kind.isEmpty, let id = e["id"]?.stringValue, !id.isEmpty else {
        throw .invalid("entity needs both a kind and an id")
      }
      entity = EntityRef(kind: kind, id: id)
      if !f.parentVersion.isNull {
        guard let pv = integer(f.parentVersion) else {
          throw .invalid("parent_version is \(showValue(f.parentVersion))")
        }
        if pv < 0 { throw .invalid("parent_version \(pv) is negative") }
        if pv > JSONNumber.maxSafeInteger {
          throw .invalid("parent_version \(pv) is outside the range a JSON number can carry exactly")
        }
        parentVersion = pv
      }
    }

    var ingestID: String?
    if type.carriesIngestID {
      guard let s = f.ingestID?.stringValue, ASCII.isLowerHex(s, count: 64) else {
        throw .invalid("\(type.rawValue) needs a 64-hex-char ingest_id, got \(showValue(f.ingestID))")
      }
      ingestID = s
    } else if let other = f.ingestID {
      throw .invalid("\(type.rawValue) must not carry an ingest_id, got \(showValue(other))")
    }

    guard let payload = f.payload else { throw .invalid("payload is empty") }
    return Op(
      v: Int(f.v), type: type, opID: opID, authoredAt: authoredAt, entity: entity, parentVersion: parentVersion,
      ingestID: ingestID, payload: payload)
  }

  static func validateDuplicateDisposition(_ payload: JSONValue?) throws(OpValidationError) {
    guard let p = payload?.objectValue else { throw .invalid("duplicate disposition payload must be an object") }
    guard let other = p["other_txn_id"]?.stringValue, !other.isEmpty else {
      throw .invalid("duplicate disposition needs other_txn_id")
    }
    guard let d = p["disposition"] else { throw .invalid("duplicate disposition needs disposition") }
    if !(d.isNull || d.stringValue == "same" || d.stringValue == "different") {
      throw .invalid("duplicate disposition must be same, different, or null")
    }
  }

  public static func validateOp(_ op: Op) throws(OpValidationError) {
    _ = try validate(rawFields(op))
  }

  static func rawFields(_ op: Op) -> RawFields {
    RawFields(
      v: Int64(op.v), type: .string(op.type.rawValue), opID: .string(op.opID), authoredAt: .string(op.authoredAt),
      entity: op.entity.map(entityJSON),
      parentVersion: op.parentVersion.map { .number(JSONNumber($0)) } ?? .null,
      ingestID: op.ingestID.flatMap { $0.isEmpty ? nil : .string($0) }, payload: op.payload)
  }

  static func entityJSON(_ e: EntityRef) -> JSONValue {
    .object(JSONObject([("kind", .string(e.kind)), ("id", .string(e.id))]))
  }

  public static func encodeBlobOps(_ ops: [Op]) throws(OpValidationError) -> [UInt8] {
    var wire: [JSONValue] = []
    wire.reserveCapacity(ops.count)
    var version = 1
    for (i, op) in ops.enumerated() {
      let checked: Op
      do {
        checked = try validate(rawFields(op))
      } catch {
        switch error {
        case .unknownNewerVersion: throw error
        case .invalid(let m): throw .invalid("op \(i): \(m)")
        }
      }
      version = max(version, op.v)
      var o = JSONObject()
      o["v"] = .number(JSONNumber(Int64(checked.v)))
      o["type"] = .string(checked.type.rawValue)
      o["op_id"] = .string(checked.opID)
      o["authored_at"] = .string(checked.authoredAt)
      if let e = checked.entity { o["entity"] = entityJSON(e) }
      o["parent_version"] = checked.parentVersion.map { .number(JSONNumber($0)) } ?? .null
      if let ingest = checked.ingestID { o["ingest_id"] = .string(ingest) }
      o["payload"] = checked.payload
      wire.append(.object(o))
    }
    let blob = JSONObject([
      ("v", .number(JSONNumber(Int64(version)))), ("kind", .string(BlobKind.ops.rawValue)), ("ops", .array(wire)),
    ])
    return JSONWriter().bytes(.object(blob))
  }

  public static func parseDecimal(_ v: JSONValue?) throws(WireDecodeError) -> String {
    guard let s = v?.stringValue, ASCII.isDecimal(s) else {
      throw .setAside("want a decimal-integer string, got \(showValue(v))")
    }
    return s
  }

  static func timeMessage(_ s: String, _ error: InstantError) -> String {
    let shown = showValue(.string(s))
    switch error {
    case .notRFC3339:
      return "want an RFC3339 timestamp, got \(shown)"
    case .zeroTime:
      return "timestamp is the zero time"
    case .outsideFourDigitYears:
      let canonical = (try? parseInstantMs(s)).map(expandedISO) ?? ""
      return "timestamp \(shown) canonicalises to \(showValue(.string(canonical))), "
        + "which is outside the four-digit-year range this wire format carries"
    case .outOfRange:
      let u = Array(s.utf8)
      func n(_ a: Int) -> Int { Int(u[a] - 0x30) * 10 + Int(u[a + 1] - 0x30) }
      var year: Int64 = 0
      for k in 0..<4 { year = year * 10 + Int64(u[k] - 0x30) }
      let mo = n(5)
      let d = n(8)
      if mo < 1 || mo > 12 { return "timestamp \(shown) has month \(mo)" }
      if d < 1 || d > Civil.daysInMonth(year: year, month: mo) { return "timestamp \(shown) has day \(d)" }
      if n(11) > 23 { return "timestamp \(shown) has hour \(n(11))" }
      if n(14) > 59 { return "timestamp \(shown) has minute \(n(14))" }
      if n(17) > 59 { return "timestamp \(shown) has second \(n(17))" }
      return "timestamp \(shown) has an out-of-range UTC offset"
    }
  }

  static func expandedISO(_ ms: Int64) -> String {
    let rem = ms - Civil.floorDiv(ms, Civil.msPerDay) * Civil.msPerDay
    func pad(_ v: Int64, _ w: Int) -> String {
      let s = String(v)
      return String(repeating: "0", count: max(0, w - s.utf8.count)) + s
    }
    return utcDay(ms) + "T" + pad(rem / 3_600_000, 2) + ":" + pad(rem / 60_000 % 60, 2) + ":"
      + pad(rem / 1000 % 60, 2) + "." + pad(rem % 1000, 3) + "Z"
  }
}

public func showValue(_ v: JSONValue?) -> String {
  guard let v else { return "undefined" }
  if !shallowEnough(v) { return "[deeply nested object]" }
  let s = JSONWriter().string(v)
  let units = Array(s.utf16)
  guard units.count > 512 else { return s }
  return String(decoding: units[0..<512], as: UTF16.self) + "…"
}

private func shallowEnough(_ v: JSONValue) -> Bool {
  var stack: [(JSONValue, Int)] = [(v, 0)]
  while let (x, d) = stack.popLast() {
    switch x {
    case .array(let a):
      if d >= 24 { return false }
      for c in a { stack.append((c, d + 1)) }
    case .object(let o):
      if d >= 24 { return false }
      for m in o.members { stack.append((m.value, d + 1)) }
    default: continue
    }
  }
  return true
}
