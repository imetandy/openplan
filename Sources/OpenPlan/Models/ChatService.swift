import Foundation
import SwiftUI

struct ChatService: Identifiable, Codable, Hashable {
  var id: UUID
  var name: String
  var bundleIdentifier: String
  var applicationPath: String
  var symbol: String
  var tintHex: String
  var isEnabled: Bool

  var applicationURL: URL? {
    let path = applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path)
  }

  var tint: Color {
    Color(hex: tintHex)
  }

  static func customSlot(at index: Int) -> ChatService {
    let palette = [
      "#FF6B6B",
      "#A66CFF",
      "#3ABFF8",
      "#F59E0B",
      "#10B981",
    ]

    return ChatService(
      id: UUID(),
      name: "New chat app",
      bundleIdentifier: "",
      applicationPath: "",
      symbol: "+",
      tintHex: palette[index % palette.count],
      isEnabled: false
    )
  }

  static let defaults: [ChatService] = [
    ChatService(
      id: UUID(uuidString: "A0B1C2D3-E4F5-4678-9012-3456789ABCDE")!,
      name: "Slack",
      bundleIdentifier: "com.tinyspeck.slackmacgap",
      applicationPath: "/Applications/Slack.app",
      symbol: "S",
      tintHex: "#7C5CFC",
      isEnabled: true
    ),
    ChatService(
      id: UUID(uuidString: "B1C2D3E4-F5A0-4789-8123-456789ABCDEF")!,
      name: "Discord",
      bundleIdentifier: "com.hnc.Discord",
      applicationPath: "/Applications/Discord.app",
      symbol: "D",
      tintHex: "#5865F2",
      isEnabled: true
    ),
    ChatService(
      id: UUID(uuidString: "C2D3E4F5-A0B1-4890-9234-56789ABCDEF0")!,
      name: "Buzz",
      bundleIdentifier: "xyz.block.buzz.app",
      applicationPath: "/Applications/Buzz.app",
      symbol: "B",
      tintHex: "#F4A340",
      isEnabled: true
    ),
    ChatService(
      id: UUID(uuidString: "D3E4F5A0-B1C2-4901-8345-6789ABCDEF01")!,
      name: "WhatsApp",
      bundleIdentifier: "net.whatsapp.WhatsApp",
      applicationPath: "/Applications/WhatsApp.app",
      symbol: "W",
      tintHex: "#22B573",
      isEnabled: true
    ),
    ChatService(
      id: UUID(uuidString: "E4F5A0B1-C2D3-4012-9456-789ABCDEF012")!,
      name: "Telegram",
      bundleIdentifier: "ru.keepcoder.Telegram",
      applicationPath: "/Applications/Telegram.app",
      symbol: "T",
      tintHex: "#2AABEE",
      isEnabled: true
    ),
  ]
}

extension Color {
  init(hex: String) {
    let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var number: UInt64 = 0
    Scanner(string: value).scanHexInt64(&number)

    let red: Double
    let green: Double
    let blue: Double

    if value.count == 6 {
      red = Double((number >> 16) & 0xFF) / 255
      green = Double((number >> 8) & 0xFF) / 255
      blue = Double(number & 0xFF) / 255
    } else {
      red = 0.45
      green = 0.45
      blue = 0.48
    }

    self.init(red: red, green: green, blue: blue)
  }
}
