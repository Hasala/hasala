import HasalaModels
import SwiftUI

public struct MailboxStatusChip: View {
  let state: MailboxState

  public init(_ state: MailboxState) {
    self.state = state
  }

  public var body: some View {
    HStack(spacing: state == .syncing ? 5 : 4) {
      if state == .syncing {
        Spinner(size: 12, tint: HColor.statusInfoForeground, track: HColor.actionAccentSubtlePressed)
      }
      Text(Self.word(state))
        .hType(HType(size: 13, leading: 16, weight: .semibold, textStyle: .footnote))
        .foregroundStyle(foreground)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.leading, state == .syncing ? 8 : 10)
    .padding(.trailing, 10)
    .frame(minHeight: 24)
    .background(surface, in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.word(state))
  }

  public static func word(_ state: MailboxState) -> String {
    switch state {
    case .connected: "Connected"
    case .syncing: "Syncing"
    case .needsSignIn: "Sign-in ended"
    case .readingStopped: "Reading stopped"
    case .disconnected: "Disconnected"
    }
  }

  private var foreground: Color {
    switch state {
    case .connected: HColor.statusSuccessForeground
    case .syncing: HColor.statusInfoForeground
    case .needsSignIn, .readingStopped: HColor.statusWarningForeground
    case .disconnected: HColor.textSecondary
    }
  }

  private var surface: Color {
    switch state {
    case .connected: HColor.statusSuccessSurface
    case .syncing: HColor.statusInfoSurface
    case .needsSignIn, .readingStopped: HColor.statusWarningSurface
    case .disconnected: HColor.surfaceGrouped
    }
  }
}

public struct MailboxRow: View {
  let mailbox: MailboxSnapshot
  let showsChevron: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ mailbox: MailboxSnapshot, showsChevron: Bool = false) {
    self.mailbox = mailbox
    self.showsChevron = showsChevron
  }

  @ViewBuilder private var chevron: some View {
    if showsChevron {
      HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
    }
  }

  private var off: Bool { mailbox.state == .disconnected }

  public var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          mark
          VStack(alignment: .leading, spacing: 2) {
            address.fixedSize(horizontal: false, vertical: true)
            metaLine
            noteLine
          }
          MailboxStatusChip(mailbox.state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { chevron }
      } else {
        ViewThatFits(in: .horizontal) {
          if mailbox.state != .readingStopped {
            HStack(spacing: HSpacing.listRowGap) {
              mark
              VStack(alignment: .leading, spacing: 2) {
                address.singleLineAtDefaultTextSize()
                metaLine
                noteLine
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              MailboxStatusChip(mailbox.state)
              chevron
            }
          }
          HStack(spacing: HSpacing.listRowGap) {
            mark
            VStack(alignment: .leading, spacing: 2) {
              address.singleLineAtDefaultTextSize()
              HStack(spacing: 8) {
                metaLine
                Spacer(minLength: 0)
                MailboxStatusChip(mailbox.state)
              }
              noteLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            chevron
          }
          HStack(alignment: .top, spacing: HSpacing.listRowGap) {
            mark
            VStack(alignment: .leading, spacing: 2) {
              address.fixedSize(horizontal: false, vertical: true)
              metaLine
              noteLine
              MailboxStatusChip(mailbox.state).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            chevron
          }
        }
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([mailbox.address, meta, mailbox.note].compactMap { $0 }.joined(separator: ", "))
    .accessibilityValue(MailboxStatusChip.word(mailbox.state))
  }

  private var meta: String { "\(mailbox.provider.appName) · \(mailbox.meta)" }

  private var mark: some View { ProviderMark(mailbox.provider, size: .tile40, faded: off) }

  public static func displayAddress(_ address: String) -> String {
    var out = ""
    for c in address {
      switch c {
      case "-": out.append("\u{2011}")
      case "@", ".": out.append(c); out.append("\u{200B}")
      default: out.append(c)
      }
    }
    return out
  }

  private var address: some View {
    Text(Self.displayAddress(mailbox.address))
      .hType(.rowTitle)
      .foregroundStyle(off ? HColor.textSecondary : HColor.textPrimary)
  }

  private var metaLine: some View {
    Text(meta).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var noteLine: some View {
    if let note = mailbox.note {
      Text(note).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
    }
  }
}

public struct ProviderRow: View {
  let provider: MailProviderKind
  let subtitle: String
  let action: () -> Void

  public init(provider: MailProviderKind, subtitle: String? = nil, action: @escaping () -> Void) {
    self.provider = provider
    self.subtitle = subtitle ?? provider.chooserSubtitle
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HListRow(leading: .provider(provider), title: provider.appName, supporting: .wrapping(subtitle),
               trailing: .chevron)
    }
    .buttonStyle(HRowPressStyle())
  }
}
