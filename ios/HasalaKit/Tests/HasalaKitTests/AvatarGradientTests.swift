import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import HasalaDesign

@MainActor
@Suite("Avatar gradient")
struct AvatarGradientTests {
  typealias Triple = (Double, Double, Double)

  static let size = 960

  static func linear(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  static func encoded(_ c: Double) -> Double {
    c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
  }

  static func oklab(_ c: HRGBA) -> Triple {
    let r = linear(Double(c.red) / 255), g = linear(Double(c.green) / 255), b = linear(Double(c.blue) / 255)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    )
  }

  static func srgb(oklab c: Triple) -> Triple {
    let l = pow(c.0 + 0.3963377774 * c.1 + 0.2158037573 * c.2, 3)
    let m = pow(c.0 - 0.1055613458 * c.1 - 0.0638541728 * c.2, 3)
    let s = pow(c.0 - 0.0894841775 * c.1 - 1.2914855480 * c.2, 3)
    return (
      encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
      encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
      encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    )
  }

  static func mix(_ a: Triple, _ b: Triple, _ t: Double) -> Triple {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
  }

  static func segment(at t: Double) -> (from: HRGBA, to: HRGBA, local: Double) {
    let stops = AvatarDisc.gradientStops
    let i = stops.indices.dropLast().last { stops[$0].location <= t } ?? 0
    let a = stops[i], b = stops[i + 1]
    return (a.color, b.color, (t - a.location) / (b.location - a.location))
  }

  static func inOklab(at t: Double) -> Triple {
    let s = segment(at: t)
    return srgb(oklab: mix(oklab(s.from), oklab(s.to), s.local))
  }

  static func inSRGB(at t: Double) -> Triple {
    let s = segment(at: t)
    func unit(_ c: HRGBA) -> Triple { (Double(c.red) / 255, Double(c.green) / 255, Double(c.blue) / 255) }
    return mix(unit(s.from), unit(s.to), s.local)
  }

  static func distance(_ a: Triple, _ b: Triple) -> Double {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
  }

  func drawn(at t: Double) throws -> Triple {
    let renderer = ImageRenderer(
      content: AvatarDisc(initial: "", size: CGFloat(Self.size)).environment(\.colorScheme, .light))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let start = AvatarDisc.gradientStart, end = AvatarDisc.gradientEnd
    let x = Int(((start.x + (end.x - start.x) * t) * Double(width)).rounded())
    let y = Int(((start.y + (end.y - start.y) * t) * Double(height)).rounded())
    let i = (y * width + x) * 4
    try #require(bytes[i + 3] == 255)
    return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
  }

  @Test func theStopsAndTheAngleAreThoseOfPaper() {
    #expect(AvatarDisc.gradientStops.map(\.color.description) == ["#F6B66B", "#E8988A", "#8C6BB8"])
    #expect(AvatarDisc.gradientStops.map(\.location) == [0, 0.55, 1])
    #expect(AvatarDisc.gradientSpace == .perceptual)
    #expect(AvatarDisc.gradientStart == UnitPoint(x: 0.2, y: 0))
    #expect(AvatarDisc.gradientEnd == UnitPoint(x: 0.8, y: 1))
  }

  nonisolated static let samples = [0.65, 0.7, 0.75, 0.8, 0.85]
  nonisolated static let level = 1.0 / 255

  @Test(arguments: samples)
  func theTwoBlendsDifferEnoughToTellApart(t: Double) {
    #expect(Self.distance(Self.inOklab(at: t), Self.inSRGB(at: t)) > 2.5 * Self.level)
  }

  @Test(arguments: samples)
  func theDiscBlendsItsStopsInOklab(t: Double) throws {
    let pixel = try drawn(at: t)
    let fromOklab = Self.distance(pixel, Self.inOklab(at: t))
    let fromSRGB = Self.distance(pixel, Self.inSRGB(at: t))
    #expect(fromOklab < 1.5 * Self.level)
    #expect(fromSRGB > 2 * Self.level)
    #expect(fromOklab < fromSRGB)
  }
}
