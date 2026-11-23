import CoreText
import Foundation

public enum HasalaFonts {
  public static let files = ["InterVariable"]
  public static let faces = ["InterVariable", "InterVariable-Medium", "InterVariable-SemiBold", "InterVariable-Bold"]

  @discardableResult
  public static func register() -> Bool {
    registration
  }

  private static let registration: Bool = {
    var ok = true
    for file in files {
      guard let url = Bundle.module.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts") else {
        ok = false
        continue
      }
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
        if code != CTFontManagerError.alreadyRegistered.rawValue { ok = false }
      }
    }
    return ok
  }()

  public static var allFacesAvailable: Bool {
    faces.allSatisfy { name in
      let font = CTFontCreateWithName(name as CFString, 12, nil)
      return (CTFontCopyPostScriptName(font) as String) == name
    }
  }
}
