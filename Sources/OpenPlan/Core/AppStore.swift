import AppKit
import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
  @Published var services: [ChatService]
  @Published var selectedServiceID: UUID?
  @Published var isSettingsPresented = false
  @Published var isPermissionHelpPresented = false
  @Published var statusMessage: String?

  let appWindows = AppWindowCoordinator()

  private let defaultsKey = "openplan.native-services.v2"
  private let deletedDefaultsKey = "openplan.deleted-default-services.v1"
  private var cancellables = Set<AnyCancellable>()
  private var focusWorkItem: DispatchWorkItem?

  init() {
    if let data = UserDefaults.standard.data(forKey: defaultsKey),
      let saved = try? JSONDecoder().decode([ChatService].self, from: data)
    {
      let deletedDefaults = Set(
        UserDefaults.standard.stringArray(forKey: deletedDefaultsKey) ?? []
      )
      let missingDefaults = ChatService.defaults.filter { defaultService in
        !deletedDefaults.contains(defaultService.bundleIdentifier)
          && !saved.contains(where: {
            $0.bundleIdentifier == defaultService.bundleIdentifier
          })
      }
      services = saved + missingDefaults
    } else {
      services = ChatService.defaults
    }

    selectedServiceID = services.first(where: \.isEnabled)?.id
    appWindows.trackedServices = services

    appWindows.onTrackedApplicationActivated = { [weak self] bundleIdentifier in
      guard
        let service = self?.services.first(where: {
          $0.bundleIdentifier == bundleIdentifier
        })
      else {
        return
      }
      self?.isSettingsPresented = false
      self?.appWindows.hideSettingsWindow()
      self?.selectedServiceID = service.id
    }

    appWindows.onSettingsWindowClosed = { [weak self] in
      self?.isSettingsPresented = false
    }

    appWindows.$accessibilityGranted
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] granted in
        guard let self else { return }

        if granted {
          self.statusMessage = nil
          self.isPermissionHelpPresented = false
          DispatchQueue.main.async { [weak self] in
            guard
              let self,
              self.appWindows.accessibilityGranted,
              !self.isSettingsPresented,
              let selectedService = self.selectedService
            else {
              return
            }
            self.appWindows.select(selectedService, hiding: nil)
          }
        } else {
          self.statusMessage = "Accessibility permission is required."
        }
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(
      for: NSApplication.didBecomeActiveNotification
    )
    .sink { [weak self] _ in
      self?.scheduleSelectedAppFocus()
    }
    .store(in: &cancellables)
  }

  var enabledServices: [ChatService] {
    services.filter(\.isEnabled)
  }

  var selectedService: ChatService? {
    guard let selectedServiceID else { return nil }
    return services.first(where: { $0.id == selectedServiceID })
  }

  func registerHostWindow(_ window: NSWindow) {
    guard appWindows.hostWindow !== window else { return }
    appWindows.hostWindow = window
    configure(window)

    guard appWindows.accessibilityGranted else {
      statusMessage = "Accessibility permission is required."
      isPermissionHelpPresented = true
      return
    }

    if let selectedService, appWindows.isInstalled(selectedService) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.appWindows.select(selectedService, hiding: nil)
      }
    }
  }

  func select(_ id: UUID) {
    guard let service = services.first(where: { $0.id == id }) else { return }

    guard appWindows.isInstalled(service) else {
      statusMessage = "\(service.name) is not installed."
      showSettings()
      return
    }

    guard appWindows.accessibilityGranted else {
      statusMessage = "Accessibility permission is required."
      isPermissionHelpPresented = true
      return
    }

    isSettingsPresented = false
    appWindows.hideSettingsWindow()

    if selectedServiceID == id {
      statusMessage = nil
      appWindows.toggleVisibility(service)
      return
    }

    let previousService = selectedService
    selectedServiceID = id
    statusMessage = nil
    appWindows.select(service, hiding: previousService)
  }

  func select(at index: Int) {
    let available = enabledServices
    guard available.indices.contains(index) else { return }
    select(available[index].id)
  }

  func cycleSelection(direction: Int) {
    let available = enabledServices
    guard !available.isEmpty else { return }

    let current =
      available.firstIndex(where: { $0.id == selectedServiceID }) ?? 0
    let next = (current + direction + available.count) % available.count
    select(available[next].id)
  }

  func saveServices(_ updatedServices: [ChatService]) {
    services = updatedServices
    appWindows.trackedServices = updatedServices

    if let data = try? JSONEncoder().encode(updatedServices) {
      UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    let configuredBundleIdentifiers = Set(
      updatedServices.map(\.bundleIdentifier)
    )
    let deletedDefaults = ChatService.defaults.compactMap { service in
      configuredBundleIdentifiers.contains(service.bundleIdentifier)
        ? nil
        : service.bundleIdentifier
    }
    UserDefaults.standard.set(
      deletedDefaults,
      forKey: deletedDefaultsKey
    )

    if selectedService == nil || selectedService?.isEnabled == false {
      selectedServiceID = enabledServices.first?.id
    }
  }

  func requestAccessibilityAccess() {
    appWindows.requestAccessibilityAccess()
  }

  func showSettings() {
    if isSettingsPresented {
      isSettingsPresented = false
      appWindows.hideSettingsWindow()
      return
    }

    appWindows.prepareSettingsPresentation()
    isSettingsPresented = true
    appWindows.showSettingsWindow()
  }

  func registerSettingsWindow(_ window: NSWindow) {
    guard appWindows.settingsWindow !== window else { return }
    appWindows.settingsWindow = window
    appWindows.showSettingsWindow()
  }

  func fitSelectedWindow() {
    guard appWindows.accessibilityGranted else {
      isPermissionHelpPresented = true
      return
    }
    appWindows.tileSelectedApplication()
  }

  func revealSelectedWindow() {
    isSettingsPresented = false
    appWindows.hideSettingsWindow()
    appWindows.revealSelectedApplication()
  }

  func minimizeWorkspace() {
    guard appWindows.accessibilityGranted else {
      isPermissionHelpPresented = true
      return
    }
    appWindows.minimizeWorkspace()
  }

  private func scheduleSelectedAppFocus() {
    focusWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }

      if NSEvent.pressedMouseButtons != 0 {
        self.scheduleSelectedAppFocus()
        return
      }

      guard
        !self.isSettingsPresented,
        !self.isPermissionHelpPresented
      else {
        return
      }

      self.appWindows.focusSelectedApplication()
    }

    focusWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + 0.05,
      execute: workItem
    )
  }

  private func configure(_ window: NSWindow) {
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.isMovableByWindowBackground = true
    window.level = .floating
    window.hidesOnDeactivate = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.minSize = NSSize(width: 76, height: 600)
    window.maxSize = NSSize(width: 76, height: 1_400)
    window.setContentSize(NSSize(width: 76, height: 760))

    if let visibleFrame = NSScreen.main?.visibleFrame {
      window.setFrameOrigin(
        NSPoint(
          x: visibleFrame.minX + 20,
          y: visibleFrame.midY - window.frame.height / 2
        )
      )
    }
  }
}
