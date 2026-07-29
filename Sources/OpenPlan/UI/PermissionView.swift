import SwiftUI

struct PermissionView: View {
  @ObservedObject var store: AppStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 18) {
        ZStack {
          Circle()
            .fill(Color.orange.opacity(0.14))
            .frame(width: 62, height: 62)

          Image(systemName: "macwindow.on.rectangle")
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(Color.orange)
        }

        VStack(spacing: 7) {
          Text("Allow window arrangement")
            .font(.system(size: 20, weight: .semibold, design: .rounded))

          Text(
            "OpenPlan needs Accessibility access to position your chat windows beside the rail."
          )
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 330)
        }

        VStack(alignment: .leading, spacing: 9) {
          permissionDetail(
            "Messages and credentials stay inside each chat app.",
            symbol: "lock.fill"
          )
          permissionDetail(
            "The permission is used only for window position and size.",
            symbol: "arrow.up.left.and.arrow.down.right"
          )
        }
      }
      .padding(.top, 28)
      .padding(.horizontal, 28)

      Spacer()

      Divider()

      HStack {
        Button("Not now") {
          store.isPermissionHelpPresented = false
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        Button("Open System Settings") {
          store.requestAccessibilityAccess()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(18)
    }
    .frame(width: 440, height: 330)
  }

  private func permissionDetail(_ text: String, symbol: String) -> some View {
    Label {
      Text(text)
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    } icon: {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.orange.opacity(0.85))
        .frame(width: 17)
    }
  }
}
