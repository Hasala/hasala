import HasalaDesign
import HasalaModels
import SwiftUI
import Testing
import UIKit

@testable import Hasala

@MainActor
@Suite("Month pill")
struct MonthPillTests {
  let month = YearMonth(2026, 11)

  func size<V: View>(_ view: V) throws -> CGSize {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    return try #require(renderer.uiImage, "the view did not render").size
  }

  @Test func thePillIsOnlyTheMonthTitle() throws {
    let title = Text(month.title).hType(.subheadline.weight(.semibold))
    let plain = try size(title)
    #expect(plain.width > 0)
    #expect(try size(MonthPill(month: month)) == plain)
  }

  @Test func thePillHasNoPickerChromeOnTheUnfinishedSurface() throws {
    #expect(BuildSurface.showsUnfinished)
    let pill = try size(MonthPill(month: month))
    #expect(pill.height < 36)
  }
}
