import HasalaDesign
import HasalaModels
import SwiftUI

struct VerifyEmailView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  @State private var now = Date.now

  var body: some View {
    let model = store.signup
    let state = model.codeState(now: now)
    AccountScreen(
      title: "Check your email",
      subtitle: model.email.isEmpty ? "We sent you a 6-digit code. It works for 10 minutes." : "We sent a 6-digit code to",
      email: model.email.isEmpty ? nil : EmailAside(address: model.email, after: "It works for 10 minutes."),
      steps: (1, 3),
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 12) {
          cells(model, state: state)
          statusLine(model, state: state)
        }
        .id(Self.revealID)
        lines(model, state: state)
      }
      .hAnimation(.stateSwap, value: state)
    } actions: {
      if state == .expired {
        BusyButton(title: "Send a new code", busy: model.busy, identifier: "code.sendNew") {
          Task { await model.resendCode() }
        }
        LinkButton(title: "Change email", identifier: "code.changeEmail") { model.back() }
      }
    }
    .revealsOnKeyboard(Self.revealID)
    .onChange(of: model.code) { _, code in
      if code.count == 6 { Task { await model.submitCode() } }
    }
    .task(id: model.ticket?.startedAt) {
      guard let sent = model.ticket?.startedAt else { return }
      let left = sent.addingTimeInterval(10 * 60 + 1).timeIntervalSinceNow
      if left > 0 { try? await Task.sleep(for: .seconds(left)) }
      if !Task.isCancelled { now = .now }
    }
  }

  @ViewBuilder private func cells(_ model: SignupModel, state: CodeCells.State) -> some View {
    CodeCells(code: Bindable(model).code, state: state, identifier: "code.field", revealTarget: Self.revealID)
      .id(model.codeSentAt)
      .overlay {
        if state == .wrong, model.code.isEmpty, !model.wrongCode.isEmpty {
          WrongCodeCells(digits: model.wrongCode)
        }
      }
  }

  private static let revealID = "code.reveal"

  @ViewBuilder private func statusLine(_ model: SignupModel, state: CodeCells.State) -> some View {
    switch state {
    case .expired:
      JoinStatusLine(text: AuthFailure.codeExpired.message ?? "", tone: .warning)
    case .wrong:
      if let message = model.failure?.message {
        JoinStatusLine(text: message, tone: .error)
      }
    case .typing:
      EmptyView()
    }
  }

  @ViewBuilder private func lines(_ model: SignupModel, state: CodeCells.State) -> some View {
    switch state {
    case .expired:
      FailureBanner(failure: otherFailure(model))
    case .wrong, .typing:
      FailureBanner(failure: otherFailure(model))
      resendRow(model)
      HintCard(icon: .envelope, text: "Not there? Check Spam or Promotions for no-reply@hasala.app.")
    }
  }

  private func otherFailure(_ model: SignupModel) -> AuthFailure? {
    switch model.failure {
    case .codeWrong, .codeExpired, nil: nil
    case let other: other
    }
  }

  private func resendRow(_ model: SignupModel) -> some View {
    ReflowingRow {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let left = max(0, 60 - Int(context.date.timeIntervalSince(model.codeSentAt ?? .distantPast)))
        if model.busy {
          HStack(spacing: 8) {
            Spinner(size: 16)
            Text("Checking the code").hType(.subheadline).foregroundStyle(HColor.textSecondary)
          }
        } else if left > 0 {
          Text("Resend code in \(ResendRow.clock(TimeInterval(left)))")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .monospacedDigit()
        } else {
          InlineTextButton(title: "Resend code", identifier: "code.resend") {
            Task { await model.resendCode() }
          }
        }
      }
      .frame(minHeight: 44)
    } trailing: {
      InlineTextButton(title: "Change email", identifier: "code.changeEmail") { model.back() }
    }
  }
}

private struct WrongCodeCells: View {
  let digits: String

  var body: some View {
    HStack(spacing: 0) {
      group(0..<3)
      Spacer(minLength: CodeCells.groupGap)
      group(3..<6)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func group(_ range: Range<Int>) -> some View {
    HStack(spacing: CodeCells.cellGap) {
      ForEach(range, id: \.self) { i in
        Text(i < digits.count ? String(digits[digits.index(digits.startIndex, offsetBy: i)]) : "")
          .font(.system(size: 28, weight: .semibold, design: .rounded))
          .foregroundStyle(HColor.textPrimary)
          .frame(minWidth: CodeCells.cellMinWidth, maxWidth: HSpacing.codeCellWidth)
          .frame(height: HSpacing.codeCellHeight)
          .background(HColor.fieldSurfaceOnGrouped,
                      in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
          .overlay { FieldRing(color: HColor.fieldError) }
          .dynamicTypeSize(...DynamicTypeSize.accessibility1)
      }
    }
  }
}
