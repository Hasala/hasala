import Foundation

public enum CoreResources {
  public static var bundle: Bundle { Bundle.module }

  public static func commonPasswords() -> String {
    guard let url = Bundle.module.url(forResource: "common-passwords-v1", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return text
  }
}
