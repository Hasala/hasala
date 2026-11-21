import HasalaModels
import SwiftUI

public enum AmountKey: Sendable, Hashable {
  case digit(Int)
  case decimal
  case delete
}

public struct AmountEntry: Sendable, Hashable {
  public static let maxWholeDigits = 9

  public private(set) var text: String

  public init() { text = "" }

  public init(typing text: String) {
    self.init()
    for ch in text {
      if MoneyFormat.isPoint(ch) {
        type(.decimal)
      } else if let d = MoneyFormat.typedDigit(ch) {
        type(.digit(d))
      }
    }
  }

  public static let maxMinor: Int64 = 999_999_999_99

  public static func clamped(_ minor: Int64) -> Int64 { min(max(0, minor), maxMinor) }

  public init(editing typed: String, previous: String, decimalSeparator: String) {
    let new = Array(typed)
    let old = Array(previous)
    let shared = min(new.count, old.count)
    var head = 0
    while head < shared, new[head] == old[head] { head += 1 }
    var tail = 0
    while tail < shared - head, new[new.count - 1 - tail] == old[old.count - 1 - tail] { tail += 1 }
    let inserted = head..<(new.count - tail)
    let commaIsPoint = decimalSeparator == ","
    self.init(typing: String(new.indices.map { i in commaIsPoint && inserted.contains(i) && new[i] == "," ? "." : new[i] }))
  }

  public init(minor: Int64) {
    let m = minor.magnitude
    let fils = m % 100
    text = fils == 0 ? "\(m / 100)" : "\(m / 100)." + (fils < 10 ? "0" : "") + "\(fils)"
  }

  public var isEmpty: Bool { text.isEmpty }

  public var isZero: Bool { (minor ?? 0) == 0 }

  private var parts: (whole: Substring, decimals: Substring?) {
    if let dot = text.firstIndex(of: ".") {
      return (text[..<dot], text[text.index(after: dot)...])
    }
    return (Substring(text), nil)
  }

  public mutating func type(_ key: AmountKey) {
    let (whole, decimals) = parts
    switch key {
    case .digit(let d):
      guard (0...9).contains(d) else { return }
      if let decimals {
        guard decimals.count < 2 else { return }
        text.append(String(d))
      } else if whole == "0" {
        text = String(d)
      } else {
        guard whole.count < Self.maxWholeDigits else { return }
        text.append(String(d))
      }
    case .decimal:
      guard decimals == nil else { return }
      text = (whole.isEmpty ? "0" : String(whole)) + "."
    case .delete:
      if !text.isEmpty { text.removeLast() }
      if text == "0" { text = "" }
    }
  }

  public mutating func clear() { text = "" }

  public var minor: Int64? {
    guard !text.isEmpty else { return nil }
    let (whole, decimals) = parts
    var units: Int64 = 0
    for ch in whole { units = units * 10 + Int64(ch.wholeNumberValue ?? 0) }
    var fils: Int64 = 0
    let dec = decimals.map(Array.init) ?? []
    if dec.count > 0 { fils += Int64(dec[0].wholeNumberValue ?? 0) * 10 }
    if dec.count > 1 { fils += Int64(dec[1].wholeNumberValue ?? 0) }
    return units * 100 + fils
  }

  public var display: String {
    let (whole, decimals) = parts
    let units = UInt64(whole) ?? 0
    let grouped = whole.isEmpty ? "0" : MoneyFormat.grouped(units)
    return decimals.map { grouped + "." + $0 } ?? grouped
  }

  public func spoken(unit: String = "AED") -> String {
    unit == "AED" ? "\(display) dirhams" : "\(unit) \(display)"
  }
}

public struct AmountKeypad: View {
  public enum Layout: Sendable { case docked, inline }

  @Binding var entry: AmountEntry
  let layout: Layout
  let compact: Bool
  @State private var presses = 0

  public init(entry: Binding<AmountEntry>, layout: Layout = .docked, compact: Bool = false) {
    _entry = entry
    self.layout = layout
    self.compact = compact
  }

  private static let rows: [[AmountKey]] = [
    [.digit(1), .digit(2), .digit(3)],
    [.digit(4), .digit(5), .digit(6)],
    [.digit(7), .digit(8), .digit(9)],
    [.decimal, .digit(0), .delete],
  ]

  public var body: some View {
    VStack(spacing: layout == .docked && !compact ? 8 : 6) {
      ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 6) {
          ForEach(row, id: \.self) { key in
            KeypadKey(key: key, layout: layout, compact: compact) {
              entry.type(key)
              presses += 1
            } onClear: {
              entry.clear()
              presses += 1
            }
          }
        }
      }
    }
    .padding(.top, layout == .docked ? 8 : 6)
    .padding(.horizontal, 6)
    .padding(.bottom, layout == .docked ? 12 : 6)
    .background {
      if layout == .docked {
        HColor.keypadTray.ignoresSafeArea(edges: .bottom)
      } else {
        RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous).fill(HColor.keypadTrayInline)
      }
    }
    .hHaptic(.keyTick, trigger: presses)
  }
}

struct KeypadKey: View {
  let key: AmountKey
  let layout: AmountKeypad.Layout
  var compact = false
  let action: () -> Void
  let onClear: () -> Void

  var body: some View {
    Button(action: action) {
      label
        .frame(maxWidth: .infinity, minHeight: height)
        .contentShape(Rectangle())
    }
    .buttonStyle(KeypadKeyStyle(tile: hasTile, layout: layout))
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.5).onEnded { _ in if key == .delete { onClear() } }
    )
    .accessibilityLabel(spoken)
    .accessibilityIdentifier(identifier)
    .accessibilityActions {
      if let name = Self.clearActionName(for: key) {
        Button(name, action: onClear)
      }
    }
  }

  static func clearActionName(for key: AmountKey) -> String? {
    key == .delete ? "Clear amount" : nil
  }

  private var height: CGFloat {
    layout == .docked && !compact ? HSpacing.keypadKeyHeight : HSpacing.keypadKeyHeightInline
  }

  private var hasTile: Bool {
    if case .digit = key { return true }
    return false
  }

  @ViewBuilder private var label: some View {
    switch key {
    case .digit(let d):
      Text("\(d)")
        .font(.system(size: HFontSize.numericMedium, weight: .medium, design: .rounded))
        .foregroundStyle(HColor.textPrimary)
        .accessibilityIdentifier(hasalaCappedFigureIdentifier)
    case .decimal:
      Text(verbatim: ".")
        .font(.system(size: HFontSize.numericMedium, weight: .medium, design: .rounded))
        .foregroundStyle(HColor.textPrimary)
        .accessibilityIdentifier(hasalaCappedFigureIdentifier)
    case .delete:
      HIconView(.delete, size: 26, color: HColor.iconPrimary)
    }
  }

  private var spoken: String {
    switch key {
    case .digit(let d): "\(d)"
    case .decimal: "Decimal point"
    case .delete: "Delete"
    }
  }

  private var identifier: String {
    switch key {
    case .digit(let d): "keypad.\(d)"
    case .decimal: "keypad.decimal"
    case .delete: "keypad.delete"
    }
  }
}

struct KeypadKeyStyle: ButtonStyle {
  let tile: Bool
  let layout: AmountKeypad.Layout

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let shape = RoundedRectangle(cornerRadius: HRadius.control, style: .continuous)
    configuration.label
      .background {
        if tile {
          shape
            .fill(pressed ? (layout == .docked ? HColor.keypadTray : HColor.keypadTrayInline) : HColor.keypadKey)
            .shadow(color: .black.opacity(pressed ? 0 : (layout == .docked ? 0.07 : 0.10)), radius: 0, x: 0, y: 1)
            .hContrastEdge(shape)
        }
      }
      .animation(.easeOut(duration: HMotion.highlight), value: pressed)
  }
}
