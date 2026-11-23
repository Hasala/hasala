import CoreJSON
import CoreMoney
import CoreTime
import CoreWire
import HasalaText

public struct PayloadError: Error, Sendable, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
}

enum P {
  static func object(_ op: Op) throws(PayloadError) -> JSONObject {
    guard let o = op.payload.objectValue else { throw PayloadError("payload is not a JSON object") }
    return o
  }

  static func object(_ v: JSONValue?, _ what: String) throws(PayloadError) -> JSONObject {
    guard let o = v?.objectValue else { throw PayloadError("\(what) must be an object, got \(showValue(v))") }
    return o
  }

  static func money(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Int64 {
    guard let s = v?.stringValue else {
      throw PayloadError("\(what) must be a decimal-integer string, got \(showValue(v))")
    }
    do {
      return try MoneyGrammar.parseV3(s)
    } catch {
      switch error {
      case .exceedsInt64: throw PayloadError("\(what): exceeds int64")
      default: throw PayloadError("\(what): want a decimal-integer string, got \(showValue(v))")
      }
    }
  }

  static func positiveMoney(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Int64 {
    let n = try money(v, what)
    if n <= 0 { throw PayloadError("\(what) is \(n), and amounts are always positive") }
    return n
  }

  static func currency(_ p: JSONObject, _ key: String, v: Int) throws(PayloadError) -> String {
    let raw = p[key]
    guard let s = raw?.stringValue else {
      throw PayloadError("\(key) must be a three-letter currency code, got \(showValue(raw))")
    }
    let u = Array(s.utf8)
    if v >= 4 {
      guard u.count == 3, u.allSatisfy(ASCII.isUpper) else {
        throw PayloadError("\(key) must be a CurrencyCode, got \(showValue(raw))")
      }
      return s
    }
    guard u.count == 3, u.allSatisfy({ ASCII.isUpper($0) || ASCII.isLower($0) }) else {
      throw PayloadError("\(key) must be a three-letter currency code, got \(showValue(raw))")
    }
    return ASCII.uppercased(s)
  }

  static func direction(_ v: JSONValue?) throws(PayloadError) -> String {
    guard let s = v?.stringValue, s == "debit" || s == "credit" else {
      throw PayloadError("direction must be debit or credit, got \(showValue(v))")
    }
    return s
  }

  static func instant(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue else { throw PayloadError("\(what) must be an RFC3339 timestamp, got \(showValue(v))") }
    do {
      _ = try parseInstantMs(s)
      let c = try canonicalTime(s)
      _ = try parseInstantMs(c)
      return c
    } catch {
      throw PayloadError("\(what): \(showValue(v)) is not a usable timestamp")
    }
  }

  static func requiredString(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, !s.isEmpty else { throw PayloadError("\(what) is \(showValue(v))") }
    return s
  }

  static func optionalString(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String? {
    guard let v else { return nil }
    guard let s = v.stringValue else { throw PayloadError("\(what) must be a string, got \(showValue(v))") }
    return s
  }

  static func nonEmptyString(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, !s.isEmpty else {
      throw PayloadError("\(what) must be a non-empty string, got \(showValue(v))")
    }
    return s
  }

  static func boolField(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Bool {
    guard let b = v?.boolValue else { throw PayloadError("\(what) must be a boolean, got \(showValue(v))") }
    return b
  }

  static func bool(_ v: JSONValue?, _ fallback: Bool) throws(PayloadError) -> Bool {
    guard let v else { return fallback }
    guard let b = v.boolValue else { throw PayloadError("want a boolean, got \(showValue(v))") }
    return b
  }

  static func optionalCategory(_ v: JSONValue?) throws(PayloadError) -> String? {
    guard let v, !v.isNull else { return nil }
    guard let s = v.stringValue else { throw PayloadError("category must be a string or null, got \(showValue(v))") }
    return s.isEmpty ? nil : s
  }

  static func intFieldV3(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Int64 {
    guard case .number(let n)? = v else { throw PayloadError("\(what) must be an integer, got \(showValue(v))") }
    let js = JSNumber.stringify(literal: n.literal)
    guard let i = Int64(js), i >= -JSONNumber.maxSafeInteger, i <= JSONNumber.maxSafeInteger else {
      throw PayloadError("\(what) must be an integer, got \(showValue(v))")
    }
    return i
  }

  static func intV4(_ v: JSONValue?, _ what: String, _ range: ClosedRange<Int64>) throws(PayloadError) -> Int64 {
    guard case .number(let n)? = v, let i = n.v4Int else {
      throw PayloadError("\(what) must be an integer literal, got \(showValue(v))")
    }
    guard range.contains(i) else { throw PayloadError("\(what) is \(i), outside \(range.lowerBound)...\(range.upperBound)") }
    return i
  }

  static func minorV4(_ v: JSONValue?, _ what: String, positive: Bool = false, signed: Bool = false)
    throws(PayloadError) -> Int64
  {
    guard let s = v?.stringValue else { throw PayloadError("\(what) must be a decimal string, got \(showValue(v))") }
    let n: Int64
    do {
      n = try MoneyGrammar.parseV4(s, allowNegative: signed)
    } catch {
      switch error {
      case .exceedsInt64: throw PayloadError("\(what): exceeds int64")
      default: throw PayloadError("\(what) is not a minor amount: \(showValue(v))")
      }
    }
    if positive, n <= 0 { throw PayloadError("\(what) must be positive") }
    return n
  }

  static func planMinor(_ v: JSONValue?, _ what: String, positive: Bool = false) throws(PayloadError) -> Int64 {
    guard let s = v?.stringValue, let n = Grammar.planMinor(s) else {
      throw PayloadError("\(what) must be a plan amount (0 to 9999999999999), got \(showValue(v))")
    }
    if positive, n <= 0 { throw PayloadError("\(what) must be positive") }
    return n
  }

  static func label(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue else { throw PayloadError("\(what) must be a Label, got \(showValue(v))") }
    if let bad = TextRules.checkLabel(s) { throw PayloadError("\(what) is not a Label (\(bad))") }
    return s
  }

  static func note(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue else { throw PayloadError("\(what) must be a Note, got \(showValue(v))") }
    if let bad = TextRules.checkNote(s) { throw PayloadError("\(what) is not a Note (\(bad))") }
    return s
  }

  static func categoryID(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.isCategoryID(s) else {
      throw PayloadError("\(what) must be a CategoryId, got \(showValue(v))")
    }
    return s
  }

  static func optionalCategoryV4(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String? {
    guard let v, !v.isNull, v.stringValue != "" else { return nil }
    return try categoryID(v, what)
  }

  static func ulid(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.isULID(s) else { throw PayloadError("\(what) must be an EntityId, got \(showValue(v))") }
    return s
  }

  static func id03b(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.isID(s) else { throw PayloadError("\(what) must be an Id, got \(showValue(v))") }
    return s
  }

  static func civilDate(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.civilDate(s) != nil else {
      throw PayloadError("\(what) must be a CivilDate, got \(showValue(v))")
    }
    return s
  }

  static func civilMonth(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.civilMonth(s) != nil else {
      throw PayloadError("\(what) must be a CivilMonth, got \(showValue(v))")
    }
    return s
  }

  static func oneOf(_ v: JSONValue?, _ what: String, _ allowed: [String]) throws(PayloadError) -> String {
    guard let s = v?.stringValue, allowed.contains(where: { utf8Equal($0, s) }) else {
      throw PayloadError("\(what) must be one of \(allowed.joined(separator: "|")), got \(showValue(v))")
    }
    return s
  }

  static func present(_ v: JSONValue?) -> JSONValue? {
    guard let v, !v.isNull else { return nil }
    return v
  }
}
