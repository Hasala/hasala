import SwiftUI

struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = Self.rows(Self.sizes(subviews, width: proposal.width), width: proposal.width, spacing: spacing)
    let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
    let widest = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width.map { min(widest, $0) } ?? widest, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let sizes = Self.sizes(subviews, width: bounds.width)
    var y = bounds.minY
    for row in Self.rows(sizes, width: bounds.width, spacing: spacing) {
      var x = bounds.minX
      for i in row.indices {
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[i]))
        x += sizes[i].width + spacing
      }
      y += row.height + spacing
    }
  }

  static func sizes(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
    subviews.map { subview in
      let ideal = subview.sizeThatFits(.unspecified)
      guard let width, ideal.width > width + 0.5 else { return ideal }
      let fitted = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      return CGSize(width: min(fitted.width, width), height: fitted.height)
    }
  }

  struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  static func rows(_ sizes: [CGSize], width: CGFloat?, spacing: CGFloat) -> [Row] {
    let limit = (width ?? .infinity) + 0.5
    var rows: [Row] = []
    var row = Row()
    for (i, size) in sizes.enumerated() {
      let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      if !row.indices.isEmpty, next > limit {
        rows.append(row)
        row = Row()
      }
      row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.indices.append(i)
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}
