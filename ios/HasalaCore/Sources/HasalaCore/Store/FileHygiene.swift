import Foundation

public enum FileHygiene {
  public static func prepareDirectory(_ directory: URL) throws {
    let fm = FileManager.default
    #if os(iOS)
      let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    #else
      let attrs: [FileAttributeKey: Any] = [:]
    #endif
    if !fm.fileExists(atPath: directory.path) {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attrs)
    } else if !attrs.isEmpty {
      try fm.setAttributes(attrs, ofItemAtPath: directory.path)
    }
    try exclude(directory)
  }

  public static func excludeDatabaseFiles(at db: URL) throws {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      let u = URL(fileURLWithPath: db.path + suffix)
      if FileManager.default.fileExists(atPath: u.path) { try exclude(u) }
    }
  }

  public static func exclude(_ url: URL) throws {
    var u = url
    var v = URLResourceValues()
    v.isExcludedFromBackup = true
    try u.setResourceValues(v)
  }

  public static func isExcluded(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
  }
}
