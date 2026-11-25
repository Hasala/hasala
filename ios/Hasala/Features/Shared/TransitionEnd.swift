import SwiftUI
import UIKit

@MainActor
final class TransitionEnd {
  private(set) var onScreen = false
  private var waiting: [@MainActor () -> Void] = []

  func afterArrival(immediately: Bool = false, _ action: @escaping @MainActor () -> Void) {
    if immediately || onScreen {
      action()
    } else {
      waiting.append(action)
    }
  }

  func arrived() {
    onScreen = true
    let ready = waiting
    waiting = []
    for action in ready { action() }
  }

  func left() {
    onScreen = false
  }
}

struct TransitionProbe: UIViewControllerRepresentable {
  let signal: TransitionEnd

  func makeUIViewController(context: Context) -> Controller { Controller() }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.signal = signal
  }

  final class Controller: UIViewController {
    var signal: TransitionEnd?

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      signal?.arrived()
    }

    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      signal?.left()
    }
  }
}
