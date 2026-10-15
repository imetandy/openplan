import SwiftUI

struct ServiceRail: View {
  @ObservedObject var store: AppStore
  @ObservedObject private var appWindows: AppWindowCoordinator

  init(store: AppStore) {
    self.store = store
    self.appWindows = store.appWindows
  }
  @State private var isMinimizeHovered = false
  @State private var isFitHovered = false

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Button {
            store.minimizeWorkspace()
          } label: {
            trafficLight(
              color: Color(nsColor: .systemYellow),
              symbol: "minus",
              isHovered: isMinimizeHovered
            )
          }
          .buttonStyle(.plain)
          .help("Minimize OpenPlan and all managed chat windows")
          .onHover { isMinimizeHovered = $0 }
          .accessibilityLabel("Minimize OpenPlan and chat apps")

          Button {
            store.fitSelectedWindow()
          } label: {
            trafficLight(
              color: Color(nsColor: .systemGreen),
              symbol: "arrow.up.left.and.arrow.down.right",
              isHovered: isFitHovered
            )
          }
          .buttonStyle(.plain)
          .help("Fit selected app beside OpenPlan")
          .onHover { isFitHovered = $0 }
          .accessibilityLabel("Fit selected app")
        }
        .disabled(!appWindows.accessibilityGranted)
        .opacity(appWindows.accessibilityGranted ? 1 : 0.35)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 9)
        .frame(height: 36)
        .background(Color.white.opacity(0.095))
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(Color.white.opacity(0.075))
            .frame(height: 1)
        }

        OpenPlanMark(size: 23)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: 76, height: 76)
      .overlay(WindowDragHandle(
        onBegin: appWindows.beginToolbarDrag
      ))
      .contentShape(Rectangle())
      .help("Drag to move OpenPlan")

      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(spacing: 14) {
          ForEach(Array(store.enabledServices.enumerated()), id: \.element.id) {
            index, service in
            serviceButton(
              service,
              shortcut: index < 9 ? index + 1 : nil
            )
          }
        }
        .padding(.vertical, 14)
      }
      .frame(maxHeight: .infinity)

      if !appWindows.accessibilityGranted {
        Button {
          store.requestAccessibilityAccess()
        } label: {
          Image(systemName: "hand.raised.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.orange)
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle())
        .help("Allow Accessibility access")
        .padding(.bottom, 6)
      }

      Button {
        store.showSettings()
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 15, weight: .medium))
          .frame(width: 38, height: 38)
          .contentShape(Rectangle())
      }
      .buttonStyle(RailButtonStyle())
      .help("Workspace settings (⌘,)")
      .padding(.bottom, 16)
    }
    .frame(width: 76)
    .background(
      ZStack {
        Color(nsColor: NSColor(calibratedWhite: 0.055, alpha: 1))
        LinearGradient(
          colors: [Color.white.opacity(0.025), .clear],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    )
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color.white.opacity(0.075))
        .frame(width: 1)
    }
  }

  private func trafficLight(
    color: Color,
    symbol: String,
    isHovered: Bool
  ) -> some View {
    ZStack {
      Circle()
        .fill(color)
        .overlay {
          Circle()
            .stroke(Color.black.opacity(0.16), lineWidth: 0.5)
        }

      Image(systemName: symbol)
        .font(.system(size: 6, weight: .black))
        .foregroundStyle(Color.black.opacity(isHovered ? 0.7 : 0))
    }
    .frame(width: 13, height: 13)
    .frame(width: 21, height: 28)
    .contentShape(Rectangle())
  }

  private func serviceButton(
    _ service: ChatService,
    shortcut: Int?
  ) -> some View {
    let isSelected = store.selectedServiceID == service.id
    let isRunning = appWindows.runningBundleIdentifiers.contains(
      service.bundleIdentifier
    )
    let isHidden = appWindows.hiddenBundleIdentifiers.contains(
      service.bundleIdentifier
    )
    let isInstalled = appWindows.installedServiceIDs.contains(service.id)

    return ServiceRailButton(
      service: service,
      shortcut: shortcut,
      isSelected: isSelected,
      isRunning: isRunning,
      isHidden: isHidden,
      isInstalled: isInstalled
    ) { store.select(service.id) }
  }
}

private struct ServiceRailButton: View {
  let service: ChatService
  let shortcut: Int?
  let isSelected: Bool
  let isRunning: Bool
  let isHidden: Bool
  let isInstalled: Bool
  let action: () -> Void
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      ZStack {
        if isSelected {
          Capsule()
            .fill(service.tint.opacity(isHidden ? 0.4 : 0.95))
            .frame(width: 3, height: 25)
            .offset(x: -29)
            .transition(.opacity.combined(with: .scale))
        }

        ZStack(alignment: .topTrailing) {
          ServiceMark(service: service, isSelected: isSelected)
            .opacity(isHidden ? 0.5 : 1)

          if isRunning {
            Circle()
              .fill(isHidden ? Color.white.opacity(0.34) : Color.green)
              .frame(width: 10, height: 10)
              .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 2))
              .offset(x: 4, y: -3)
              .transition(.scale.combined(with: .opacity))
          } else if !isInstalled {
            Image(systemName: "exclamationmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.black)
              .frame(width: 17, height: 17)
              .background(service.tint, in: Circle())
              .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 2))
              .offset(x: 6, y: -5)
          }
        }
      }
      .frame(width: 62, height: 50)
      .background(
        Color.white.opacity(isHovered ? 0.045 : 0),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .scaleEffect(isHovered ? 1.025 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(
      isSelected
        ? "\(isHidden ? "Show" : "Hide") \(service.name)\(shortcutLabel(shortcut))"
        : "\(service.name)\(shortcutLabel(shortcut))"
    )
    .accessibilityLabel(service.name)
    .onHover { isHovering in
      isHovered = isHovering
    }
    .animation(
      reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.75),
      value: isRunning
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
  }

  private func shortcutLabel(_ shortcut: Int?) -> String {
    shortcut.map { " (⌘\($0))" } ?? ""
  }
}

private struct RailButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.5 : 0.58))
      .background(
        Color.white.opacity(configuration.isPressed ? 0.08 : 0),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
  }
}
