import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class AppWindowCoordinator: ObservableObject {
  @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
  @Published private(set) var runningBundleIdentifiers: Set<String> = []
  @Published private(set) var hiddenBundleIdentifiers: Set<String> = []
  @Published private(set) var sharedWindowSize: CGSize?

  @Published private(set) var installedServiceIDs: Set<UUID> = []

  var trackedServices: [ChatService] = [] {
    didSet { refreshInstalledApplications() }
  }
  var onTrackedApplicationActivated: ((String) -> Void)?
  var onSettingsWindowClosed: (() -> Void)?

  weak var hostWindow: NSWindow? {
    didSet {
      windowPair.railWindow = hostWindow
      observeHostWindow()
    }
  }

  weak var settingsWindow: NSWindow? {
    didSet {
      observeSettingsWindow()
    }
  }

  private var selectedService: ChatService?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var windowObservers: [NSObjectProtocol] = []
  private var settingsWindowObservers: [NSObjectProtocol] = []
  private var permissionTimer: Timer?
  private var tileWorkItem: DispatchWorkItem?
  private let windowPair = WindowPairController()
  private var pairGeneration = 0
  private var isPairing = false
  private var tileGeneration = 0
  private var windowCache: [pid_t: AXUIElement] = [:]
  private let sharedWindowSizeKey = "openplan.shared-window-size.v1"

  init() {
    if let encodedSize = UserDefaults.standard.string(
      forKey: sharedWindowSizeKey
    ) {
      let size = NSSizeFromString(encodedSize)
      if size.width >= 320, size.height >= 300 {
        sharedWindowSize = size
      }
    }

    let center = NSWorkspace.shared.notificationCenter

    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.windowCache.removeAll()
          self?.refreshRunningApplications()
        }
      }
    )

    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.windowCache.removeAll()
          self?.refreshRunningApplications()
        }
      }
    )

    for name in [
      NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification,
    ] {
      workspaceObservers.append(
        center.addObserver(
          forName: name,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor in self?.refreshRunningApplications() }
        }
      )
    }

    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          let bundleIdentifier = application.bundleIdentifier
        else {
          return
        }

        Task { @MainActor in
          guard
            let self,
            let service = self.trackedServices.first(where: {
              $0.isEnabled && $0.bundleIdentifier == bundleIdentifier
            })
          else {
            return
          }
          let selectionChanged = self.selectedService?.id != service.id
          if selectionChanged {
            self.cancelLiveMove()
            self.cancelPendingTile()
            self.selectedService = service
          }
          self.windowCache[application.processIdentifier] = nil
          self.onTrackedApplicationActivated?(bundleIdentifier)
          if selectionChanged || !self.windowPair.isAttached { self.attachSelectedApplication() }
        }
      }
    )

    refreshRunningApplications()
  }

  deinit {
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    for observer in windowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    for observer in settingsWindowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    permissionTimer?.invalidate()
  }

  func requestAccessibilityAccess() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let trusted = AXIsProcessTrustedWithOptions(
      [promptKey: true] as CFDictionary
    )
    updateAccessibilityState(trusted)

    permissionTimer?.invalidate()
    permissionTimer = Timer.scheduledTimer(
      withTimeInterval: 0.75,
      repeats: true
    ) { [weak self] timer in
      Task { @MainActor in
        guard let self else {
          timer.invalidate()
          return
        }
        let trusted = AXIsProcessTrusted()
        self.updateAccessibilityState(trusted)
        if trusted {
          timer.invalidate()
        }
      }
    }
  }

  func refreshInstalledApplications() {
    ApplicationMetadataCache.shared.invalidate()
    let installed = Set(trackedServices.filter {
      ApplicationMetadataCache.shared.url(for: $0) != nil
    }.map(\.id))
    if installed != installedServiceIDs { installedServiceIDs = installed }
  }

  func isInstalled(_ service: ChatService) -> Bool {
    ApplicationMetadataCache.shared.url(for: service) != nil
  }

  func select(_ service: ChatService, hiding previousService: ChatService?) {
    cancelLiveMove()

    if let previousService, previousService.id != service.id {
      captureSharedWindowSize(from: previousService)
      runningApplication(for: previousService)?.hide()
    }

    selectedService = service
    guard accessibilityGranted else { return }

    if let application = runningApplication(for: service) {
      setMinimized(false, for: application)
      application.unhide()
      application.activate(options: [.activateAllWindows])
      scheduleTile(service: service, attemptsRemaining: 6)
      refreshRunningApplications()
      return
    }

    guard let url = applicationURL(for: service) else { return }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(
      at: url,
      configuration: configuration
    ) { [weak self] _, _ in
      Task { @MainActor in
        self?.refreshRunningApplications()
        self?.scheduleTile(service: service, attemptsRemaining: 10)
      }
    }
  }

  func tileSelectedApplication() {
    cancelLiveMove()
    if settingsWindow?.isVisible == true {
      tileSettingsWindow()
      return
    }

    guard let selectedService else { return }
    scheduleTile(service: selectedService, attemptsRemaining: 3)
  }

  func toggleVisibility(_ service: ChatService) {
    cancelLiveMove()
    selectedService = service

    guard let application = runningApplication(for: service) else {
      select(service, hiding: nil)
      return
    }

    if application.isHidden || isMainWindowMinimized(of: application) {
      setMinimized(false, for: application)
      application.unhide()
      application.activate(options: [.activateAllWindows])
      scheduleTile(service: service, attemptsRemaining: 4)
    } else {
      captureSharedWindowSize(from: service)
      cancelPendingTile()
      application.hide()
    }

    refreshRunningApplications()
  }

  func revealSelectedApplication() {
    cancelLiveMove()
    guard
      let selectedService,
      let application = runningApplication(for: selectedService)
    else {
      return
    }
    setMinimized(false, for: application)
    application.unhide()
    application.activate(options: [.activateAllWindows])
    scheduleTile(service: selectedService, attemptsRemaining: 3)
    refreshRunningApplications()
  }

  func focusSelectedApplication() {
    guard
      hostWindow?.isMiniaturized != true,
      settingsWindow?.isVisible != true,
      let selectedService,
      let application = runningApplication(for: selectedService),
      !application.isHidden
    else {
      return
    }

    setMinimized(false, for: application)
    application.activate(options: [.activateAllWindows])
  }

  func prepareSettingsPresentation() {
    cancelLiveMove()
    cancelPendingTile()

    if let selectedService {
      captureSharedWindowSize(from: selectedService)
      runningApplication(for: selectedService)?.hide()
    }

    refreshRunningApplications()
  }

  func showSettingsWindow() {
    guard let settingsWindow else { return }

    settingsWindow.isReleasedWhenClosed = false
    settingsWindow.minSize = NSSize(width: 480, height: 400)
    settingsWindow.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
    ]

    tileSettingsWindow()
    settingsWindow.deminiaturize(nil)
    settingsWindow.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  func hideSettingsWindow() {
    if settingsWindow?.isVisible == true { cancelLiveMove() }
    settingsWindow?.orderOut(nil)
  }

  func minimizeWorkspace() {
    cancelLiveMove()
    cancelPendingTile()

    for service in trackedServices where service.isEnabled {
      guard let application = runningApplication(for: service) else { continue }
      setMinimized(true, for: application)
    }

    if settingsWindow?.isVisible == true {
      settingsWindow?.miniaturize(nil)
    }
    hostWindow?.miniaturize(nil)
  }

  private func observeHostWindow() {
    for observer in windowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    windowObservers.removeAll()

    guard let hostWindow else { return }
    let center = NotificationCenter.default

    windowObservers.append(
      center.addObserver(
        forName: NSWindow.didMoveNotification,
        object: hostWindow,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.handleHostWindowMove() }
      }
    )

    windowObservers.append(
      center.addObserver(
        forName: NSWindow.didEndLiveResizeNotification,
        object: hostWindow,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.tileSelectedApplication() }
      }
    )

    windowObservers.append(
      center.addObserver(
        forName: NSWindow.didDeminiaturizeNotification,
        object: hostWindow,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.restoreWorkspace() }
      }
    )
  }

  private func observeSettingsWindow() {
    for observer in settingsWindowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    settingsWindowObservers.removeAll()

    guard let settingsWindow else { return }
    let center = NotificationCenter.default

    settingsWindowObservers.append(
      center.addObserver(
        forName: NSWindow.willCloseNotification,
        object: settingsWindow,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.cancelLiveMove()
          self?.onSettingsWindowClosed?()
        }
      }
    )

    settingsWindowObservers.append(
      center.addObserver(
        forName: NSWindow.didEndLiveResizeNotification,
        object: settingsWindow,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.captureSharedSettingsSize() }
      }
    )
  }

  func beginToolbarDrag() {
    cancelPendingTile()
    windowPair.beginRailDrag()
  }

  private func handleHostWindowMove() {
    // A follower move is one-way. Never send it back to Slack as another AX move.
    guard !windowPair.isAttached, !isPairing, NSEvent.pressedMouseButtons & 1 == 0 else { return }
    scheduleSettledTile(after: 0.05)
  }

  private func attachSelectedApplication(attemptsRemaining: Int = 3) {
    guard accessibilityGranted, let service = selectedService,
      let application = runningApplication(for: service), !application.isHidden,
      settingsWindow?.isVisible != true, hostWindow?.isMiniaturized != true
    else { return }
    cancelLiveMove()
    tileWorkItem?.cancel()
    isPairing = true
    let generation = pairGeneration
    LivePositionWriter.prepare(processIdentifier: application.processIdentifier) { [weak self] snapshot in
      guard let self, generation == self.pairGeneration,
        self.selectedService?.id == service.id, !application.isHidden,
        self.settingsWindow?.isVisible != true
      else { return }
      self.isPairing = false
      if let snapshot,
        self.windowPair.attach(processIdentifier: application.processIdentifier, snapshot: snapshot) {
        self.windowCache[application.processIdentifier] = snapshot.window
        self.windowPair.onUnavailable = { [weak self] in
          self?.windowCache[application.processIdentifier] = nil
          self?.attachSelectedApplication()
        }
      } else if attemptsRemaining > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
          guard let self, self.pairGeneration == generation else { return }
          self.attachSelectedApplication(attemptsRemaining: attemptsRemaining - 1)
        }
      }
    }
  }

  private func cancelLiveMove() {
    pairGeneration += 1
    isPairing = false
    windowPair.onUnavailable = nil
    windowPair.detach()
  }

  private func scheduleSettledTile(after delay: TimeInterval) {
    tileWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.tileSelectedApplication()
    }
    tileWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func scheduleTile(
    service: ChatService,
    attemptsRemaining: Int
  ) {
    tileGeneration += 1
    performTile(
      service: service,
      attemptsRemaining: attemptsRemaining,
      generation: tileGeneration
    )
  }

  private func performTile(
    service: ChatService,
    attemptsRemaining: Int,
    generation: Int
  ) {
    guard generation == tileGeneration else { return }
    guard service.id == selectedService?.id else { return }

    if tile(service) {
      attachSelectedApplication()
      return
    }

    guard attemptsRemaining > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      self?.performTile(
        service: service,
        attemptsRemaining: attemptsRemaining - 1,
        generation: generation
      )
    }
  }

  private func cancelPendingTile() {
    tileWorkItem?.cancel()
    tileGeneration += 1
  }

  private func restoreWorkspace() {
    if let settingsWindow, settingsWindow.isMiniaturized {
      settingsWindow.deminiaturize(nil)
      tileSettingsWindow()
      settingsWindow.makeKeyAndOrderFront(nil)
      return
    }

    revealSelectedApplication()
  }

  private func tileSettingsWindow() {
    cancelLiveMove()
    guard
      let settingsWindow,
      let targetFrame = targetFrame()
    else {
      return
    }

    if settingsWindow.frame != targetFrame {
      settingsWindow.setFrame(targetFrame, display: true)
    }
    windowPair.attach(nativeWindow: settingsWindow)
  }

  private func updateAccessibilityState(_ trusted: Bool) {
    guard trusted != accessibilityGranted else { return }
    accessibilityGranted = trusted
  }

  @discardableResult
  private func tile(_ service: ChatService) -> Bool {
    guard
      accessibilityGranted,
      let application = runningApplication(for: service),
      !application.isHidden,
      let targetFrame = targetFrame(),
      let window = firstWindow(of: application)
    else {
      return false
    }

    var position = CGPoint(
      x: targetFrame.minX,
      y: quartzTopEdge - targetFrame.maxY
    )
    var size = targetFrame.size

    let currentPosition = pointAttribute(
      kAXPositionAttribute as CFString,
      from: window
    )
    let currentSize = sizeAttribute(
      kAXSizeAttribute as CFString,
      from: window
    )

    let positionChanged =
      currentPosition.map { distance($0, position) > 1 } ?? true
    let sizeChanged =
      currentSize.map {
        abs($0.width - size.width) > 1 || abs($0.height - size.height) > 1
      } ?? true

    if !positionChanged && !sizeChanged {
      return true
    }

    var positionResult: AXError = .success
    var sizeResult: AXError = .success

    if positionChanged,
      let positionValue = AXValueCreate(.cgPoint, &position)
    {
      positionResult = AXUIElementSetAttributeValue(
        window,
        kAXPositionAttribute as CFString,
        positionValue
      )
    }

    if sizeChanged, let sizeValue = AXValueCreate(.cgSize, &size) {
      sizeResult = AXUIElementSetAttributeValue(
        window,
        kAXSizeAttribute as CFString,
        sizeValue
      )
    }

    if positionResult == .invalidUIElement || sizeResult == .invalidUIElement {
      windowCache[application.processIdentifier] = nil
    }

    return positionResult == .success && sizeResult == .success
  }

  private func firstWindow(of application: NSRunningApplication) -> AXUIElement? {
    if let cached = windowCache[application.processIdentifier] {
      return cached
    }

    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 0.1)
    var value: CFTypeRef?

    guard
      AXUIElementCopyAttributeValue(
        appElement,
        kAXWindowsAttribute as CFString,
        &value
      ) == .success,
      let windows = value as? [AXUIElement]
    else {
      return nil
    }

    let window =
      windows.first(where: { window in
        AXUIElementSetMessagingTimeout(window, 0.1)
        var minimizedValue: CFTypeRef?
        AXUIElementCopyAttributeValue(
          window,
          kAXMinimizedAttribute as CFString,
          &minimizedValue
        )
        return (minimizedValue as? Bool) != true
      }) ?? windows.first

    if let window {
      AXUIElementSetMessagingTimeout(window, 0.1)
      windowCache[application.processIdentifier] = window
    }
    return window
  }

  private func pointAttribute(
    _ attribute: CFString,
    from element: AXUIElement
  ) -> CGPoint? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == AXValueGetTypeID()
    else {
      return nil
    }

    var point = CGPoint.zero
    guard
      AXValueGetValue(rawValue as! AXValue, .cgPoint, &point)
    else {
      return nil
    }
    return point
  }

  private func sizeAttribute(
    _ attribute: CFString,
    from element: AXUIElement
  ) -> CGSize? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == AXValueGetTypeID()
    else {
      return nil
    }

    var size = CGSize.zero
    guard
      AXValueGetValue(rawValue as! AXValue, .cgSize, &size)
    else {
      return nil
    }
    return size
  }

  private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
  }

  private func captureSharedWindowSize(from service: ChatService) {
    guard
      accessibilityGranted,
      let application = runningApplication(for: service),
      let window = firstWindow(of: application),
      let size = sizeAttribute(kAXSizeAttribute as CFString, from: window),
      size.width >= 320,
      size.height >= 300
    else {
      return
    }

    storeSharedWindowSize(size)
  }

  private func storeSharedWindowSize(_ size: CGSize) {
    guard size.width >= 320, size.height >= 300 else { return }
    if let sharedWindowSize,
      abs(sharedWindowSize.width - size.width) <= 1,
      abs(sharedWindowSize.height - size.height) <= 1
    {
      return
    }

    sharedWindowSize = size
    UserDefaults.standard.set(
      NSStringFromSize(size),
      forKey: sharedWindowSizeKey
    )
  }

  private func captureSharedSettingsSize() {
    guard
      let size = settingsWindow?.frame.size,
      size.width >= 480,
      size.height >= 400
    else {
      return
    }

    sharedWindowSize = size
    UserDefaults.standard.set(
      NSStringFromSize(size),
      forKey: sharedWindowSizeKey
    )
  }

  private func isMainWindowMinimized(
    of application: NSRunningApplication
  ) -> Bool {
    guard let window = firstWindow(of: application) else { return false }
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        window,
        kAXMinimizedAttribute as CFString,
        &rawValue
      ) == .success
    else {
      return false
    }
    return (rawValue as? Bool) == true
  }

  private func setMinimized(
    _ minimized: Bool,
    for application: NSRunningApplication
  ) {
    guard let window = firstWindow(of: application) else { return }
    AXUIElementSetAttributeValue(
      window,
      kAXMinimizedAttribute as CFString,
      minimized ? kCFBooleanTrue : kCFBooleanFalse
    )
  }

  private func targetFrame() -> CGRect? {
    guard let railFrame = hostWindow?.frame else { return nil }

    let screen =
      NSScreen.screens.first(where: { $0.frame.intersects(railFrame) })
      ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else { return nil }

    let horizontalGap: CGFloat = 8
    let trailingMargin: CGFloat = 20
    let spaceOnRight =
      visibleFrame.maxX - railFrame.maxX - horizontalGap - trailingMargin
    let spaceOnLeft =
      railFrame.minX - visibleFrame.minX - horizontalGap - trailingMargin

    let requestedWidth = sharedWindowSize?.width
    let requestedHeight = sharedWindowSize?.height
    let prefersRight =
      spaceOnRight >= (requestedWidth ?? 640)
      || spaceOnRight >= spaceOnLeft

    let width: CGFloat
    let x: CGFloat
    if prefersRight {
      width = min(
        requestedWidth ?? max(480, spaceOnRight),
        max(480, spaceOnRight)
      )
      x = railFrame.maxX + horizontalGap
    } else {
      width = min(
        requestedWidth ?? max(480, spaceOnLeft),
        max(480, spaceOnLeft)
      )
      x = railFrame.minX - horizontalGap - width
    }

    let height = min(
      requestedHeight ?? railFrame.height,
      visibleFrame.height
    )

    return CGRect(
      x: x,
      y: max(
        visibleFrame.minY,
        min(railFrame.minY, visibleFrame.maxY - height)
      ),
      width: width,
      height: height
    )
  }

  private var quartzTopEdge: CGFloat {
    NSScreen.screens.first?.frame.maxY ?? 0
  }

  private func applicationURL(for service: ChatService) -> URL? {
    ApplicationMetadataCache.shared.url(for: service)
  }

  private func runningApplication(
    for service: ChatService
  ) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(
      withBundleIdentifier: service.bundleIdentifier
    ).first
  }

  private func refreshRunningApplications() {
    let applications = NSWorkspace.shared.runningApplications
    let running = Set(applications.compactMap(\.bundleIdentifier))
    let hidden = Set(
      applications.compactMap { application in
        application.isHidden ? application.bundleIdentifier : nil
      }
    )
    if running != runningBundleIdentifiers { runningBundleIdentifiers = running }
    let wasHidden = selectedService.map { hiddenBundleIdentifiers.contains($0.bundleIdentifier) } ?? false
    if hidden != hiddenBundleIdentifiers { hiddenBundleIdentifiers = hidden }
    if let service = selectedService {
      if hidden.contains(service.bundleIdentifier) || !running.contains(service.bundleIdentifier) {
        cancelLiveMove()
      } else if wasHidden {
        attachSelectedApplication()
      }
    }
  }
}
