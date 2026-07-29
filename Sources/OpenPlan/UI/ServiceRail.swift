import SwiftUI

struct ServiceRail: View {
  @ObservedObject var store: AppStore
  @State private var hoveredServiceID: UUID?
  @State private var isMinimizeHovered = false
  @State private var isFitHovered = false

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
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
        .disabled(!store.appWindows.accessibilityGranted)
        .opacity(store.appWindows.accessibilityGranted ? 1 : 0.35)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 13)
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

      if !store.appWindows.accessibilityGranted {
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
    .contentShape(Circle())
  }

  private func serviceButton(
    _ service: ChatService,
    shortcut: Int?
  ) -> some View {
    let isSelected = store.selectedServiceID == service.id
    let isRunning = store.appWindows.runningBundleIdentifiers.contains(
      service.bundleIdentifier
    )
    let isHidden = store.appWindows.hiddenBundleIdentifiers.contains(
      service.bundleIdentifier
    )
    let isInstalled = store.appWindows.isInstalled(service)

    return Button {
      if !isInstalled {
        store.showSettings()
      } else {
        withAnimation(.snappy(duration: 0.2)) {
          store.select(service.id)
        }
      }
    } label: {
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
        Color.white.opacity(hoveredServiceID == service.id ? 0.045 : 0),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .scaleEffect(hoveredServiceID == service.id ? 1.025 : 1)
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
      hoveredServiceID = isHovering ? service.id : nil
    }
    .animation(
      .spring(response: 0.25, dampingFraction: 0.75),
      value: isRunning
    )
    .animation(.easeOut(duration: 0.14), value: hoveredServiceID)
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
