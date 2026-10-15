import AppKit

@MainActor
final class ApplicationMetadataCache {
  static let shared = ApplicationMetadataCache()

  private struct Key: Hashable {
    let path: String
    let bundleIdentifier: String
  }
  private struct Entry {
    let url: URL?
    var icon: NSImage?
  }
  private var entries: [Key: Entry] = [:]

  func invalidate() { entries.removeAll(keepingCapacity: true) }

  func url(for service: ChatService) -> URL? {
    let key = key(for: service)
    if let entry = entries[key] { return entry.url }
    let url: URL?
    if !key.path.isEmpty, FileManager.default.fileExists(atPath: key.path) {
      url = URL(fileURLWithPath: key.path)
    } else if !key.bundleIdentifier.isEmpty {
      url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key.bundleIdentifier)
    } else {
      url = nil
    }
    entries[key] = Entry(url: url)
    return url
  }

  func icon(for service: ChatService) -> NSImage? {
    let key = key(for: service)
    if let icon = entries[key]?.icon { return icon }
    guard let url = url(for: service) else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    icon.isTemplate = false
    entries[key]?.icon = icon
    return icon
  }

  private func key(for service: ChatService) -> Key {
    Key(
      path: service.applicationPath.trimmingCharacters(in: .whitespacesAndNewlines),
      bundleIdentifier: service.bundleIdentifier
    )
  }
}
