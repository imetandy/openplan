import SwiftUI

struct OpenPlanMark: View {
  var size: CGFloat = 22

  var body: some View {
    ZStack {
      RoundedRectangle(
        cornerRadius: size * 0.2,
        style: .continuous
      )
      .fill(Color.cyan.opacity(0.16))
      .overlay {
        RoundedRectangle(
          cornerRadius: size * 0.2,
          style: .continuous
        )
        .stroke(Color.cyan.opacity(0.34), lineWidth: 0.8)
      }
      .frame(width: size * 0.58, height: size * 0.46)
      .offset(x: size * 0.15, y: -size * 0.12)

      RoundedRectangle(
        cornerRadius: size * 0.22,
        style: .continuous
      )
      .fill(
        LinearGradient(
          colors: [
            Color(red: 0.46, green: 0.34, blue: 1),
            Color(red: 0.33, green: 0.84, blue: 1),
          ],
          startPoint: .bottomLeading,
          endPoint: .topTrailing
        )
      )
      .frame(width: size * 0.62, height: size * 0.48)
      .offset(x: size * 0.08, y: size * 0.08)

      Capsule()
        .fill(
          LinearGradient(
            colors: [
              Color(red: 0.46, green: 0.34, blue: 1),
              Color(red: 0.33, green: 0.84, blue: 1),
            ],
            startPoint: .bottom,
            endPoint: .top
          )
        )
        .frame(width: size * 0.11, height: size * 0.76)
        .offset(x: -size * 0.35)

      HStack(spacing: size * 0.07) {
        Capsule()
          .fill(Color.white.opacity(0.92))
          .frame(width: size * 0.22, height: size * 0.055)
        Capsule()
          .fill(Color.white.opacity(0.56))
          .frame(width: size * 0.13, height: size * 0.055)
      }
      .offset(x: size * 0.1, y: size * 0.08)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
