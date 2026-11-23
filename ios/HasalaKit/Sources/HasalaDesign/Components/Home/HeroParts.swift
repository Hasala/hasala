import HasalaModels
import SwiftUI

public struct PeriodPill: View {
  let title: String
  let tinted: Bool
  let action: (() -> Void)?

  public init(_ title: String, tinted: Bool = false, action: (() -> Void)? = nil) {
    self.title = title
    self.tinted = tinted
    self.action = action
  }

  public var body: some View {
    if let action {
      Button(action: action) { pill }
        .buttonStyle(RowTargetPressStyle())
        .accessibilityLabel("Period, \(title)")
        .accessibilityHint("Double-tap to change.")
    } else {
      pill
        .frame(minHeight: HSpacing.targetMinimum, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Period, \(title)")
    }
  }

  private var pill: some View {
    HStack(spacing: 6) {
      Text(title).hType(.subheadline.weight(.semibold)).foregroundStyle(ink)
      if action != nil {
        HIconView(.chevronDown, size: 14, color: ink, strokeWidth: 2.6)
      }
    }
    .padding(.leading, 14)
    .padding(.trailing, action == nil ? 14 : 12)
    .padding(.vertical, 8)
    .frame(minHeight: 36)
    .background(tinted ? HColor.actionAccentSubtle : HColor.surfacePrimary, in: Capsule())
    .hElevation(.near)
  }

  private var ink: Color { tinted ? HColor.actionAccent : HColor.textPrimary }
}

private struct RowTargetPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HPressStyle().makeBody(configuration: configuration)
      .frame(minHeight: HSpacing.targetMinimum)
      .contentShape(Rectangle())
  }
}

public struct HeroVerdictLine: View {
  let verdict: Verdict?
  let word: MoneyPhrase
  let fact: MoneyPhrase?
  let hidden: Bool
  let link: Link?

  public struct Link {
    public var title: String
    public var identifier: String
    public var action: () -> Void

    public init(_ title: String, identifier: String, action: @escaping () -> Void) {
      self.title = title
      self.identifier = identifier
      self.action = action
    }
  }

  public init(verdict: Verdict?, word: MoneyPhrase, fact: MoneyPhrase?, hidden: Bool, link: Link? = nil) {
    self.verdict = verdict
    self.word = word
    self.fact = fact
    self.hidden = hidden
    self.link = link
  }

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  public var body: some View {
    ReflowingRow(spacing: 12) {
      HStack(alignment: .top, spacing: 6) {
        Circle().fill(dotColor).frame(width: 8, height: 8).frame(height: lane)
          .accessibilityHidden(true)
        Text("\(Text(word.rendered(hidden: hidden)).font(wordFont).foregroundStyle(wordColor))\(factText)")
          .hType(.subheadline)
          .foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(spoken)
      }
    } trailing: {
      if let link {
        Button(action: link.action) {
          Text(link.title)
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textOnWashLink)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -12)
        .accessibilityIdentifier(link.identifier)
      }
    }
  }

  private var wordFont: Font { HType.subheadline.weight(.semibold).font }

  private var factText: Text {
    Text(verbatim: fact.map { " · " + $0.rendered(hidden: hidden) } ?? "")
  }

  private var spoken: String {
    [word.spoken(hidden: hidden), fact?.spoken(hidden: hidden)].compactMap { $0 }.joined(separator: ", ")
  }

  private var dotColor: Color { verdict?.foreground ?? HColor.textOnWashSecondary }
  private var wordColor: Color { verdict?.foreground ?? HColor.textPrimary }
}
