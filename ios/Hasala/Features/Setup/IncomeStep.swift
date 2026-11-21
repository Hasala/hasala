import HasalaDesign
import HasalaModels
import SwiftUI

struct IncomeStep: View {
  @Bindable var model: MonthlyPlanModel
  @FocusState private var figureFocused: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    ScrollViewReader { proxy in
      screen.onAppear {
        guard typeSize.isAccessibilitySize else { return }
        proxy.scrollTo(Self.figureID, anchor: .top)
      }
    }
  }

  private static let figureID = "income.figure"
  static let subtitle = "After deductions. Change it any time."

  private var screen: some View {
    SetupScreen(
      title: "What lands in your account each month?",
      subtitle: Self.subtitle,
      back: .system,
      trailing: ("Skip", model.skipIncome),
      layout: .fill
    ) {
      amountArea
    } dock: {
      VStack(spacing: 0) {
        BusyButton(title: "Continue", busy: false, enabled: model.incomeMinor != nil,
                   identifier: "income.continue", action: model.continueWithIncome)
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.bottom, 16)
        AmountKeypad(entry: $model.incomeEntry, layout: .docked, compact: typeSize.isAccessibilitySize)
      }
    }
    .onAppear { figureFocused = true }
  }

  private var amountArea: some View {
    VStack(spacing: 16) {
      AmountFigure(entry: model.incomeEntry, layout: .docked)
        .padding(.horizontal, HSpacing.insetPage)
        .accessibilityIdentifier(Self.figureID)
        .id(Self.figureID)
        .focusable()
        .focused($figureFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: typed)
      PaydayPicker(choice: $model.paydayChoice, next: model.nextPayday)
        .padding(.top, 8)
      SetupFailureBanner(failure: model.failure)
        .padding(.horizontal, HSpacing.insetPage)
    }
    .padding(.vertical, 22)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, 28)
  }

  private func typed(_ press: KeyPress) -> KeyPress.Result {
    var entry = model.incomeEntry
    switch press.key {
    case .delete, .deleteForward:
      entry.type(.delete)
    case .return:
      model.continueWithIncome()
      return .handled
    default:
      guard let d = press.characters.first?.wholeNumberValue, press.characters.count == 1,
        press.characters.first?.isASCII == true
      else { return .ignored }
      entry.type(.digit(d))
    }
    model.incomeEntry = entry
    return .handled
  }
}
