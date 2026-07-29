import AppKit
import SwiftUI

struct ServiceMark: View {
  let service: ChatService
  var size: CGFloat = 42
  var isSelected = false

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        .fill(
          isSelected
            ? service.tint.opacity(0.2)
            : Color.white.opacity(0.045)
        )

      RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        .strokeBorder(
          isSelected
            ? service.tint.opacity(0.55)
            : Color.white.opacity(0.07),
          lineWidth: 1
        )

      if let icon = ApplicationIconCache.shared.icon(for: service) {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
          .frame(width: size * 0.78, height: size * 0.78)
          .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
      } else {
        Text(service.symbol.uppercased())
          .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
          .foregroundStyle(isSelected ? Color.white : service.tint)
      }
    }
    .frame(width: size, height: size)
    .shadow(
      color: isSelected ? service.tint.opacity(0.18) : .clear,
      radius: 10,
      y: 3
    )
  }
}

@MainActor
private final class ApplicationIconCache {
  static let shared = ApplicationIconCache()

  private var icons: [String: NSImage] = [:]

  func icon(for service: ChatService) -> NSImage? {
    let path = service.applicationPath
    guard FileManager.default.fileExists(atPath: path) else { return nil }

    if let cached = icons[path] {
      return cached
    }

    let icon = NSWorkspace.shared.icon(forFile: path)
    icon.isTemplate = false
    icons[path] = icon
    return icon
  }
}
