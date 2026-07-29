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

  var trackedServices: [ChatService] = []
  var onTrackedApplicationActivated: ((String) -> Void)?
  var onSettingsWindowClosed: (() -> Void)?

  weak var hostWindow: NSWindow? {
    didSet {
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
  private var liveMoveWorkItem: DispatchWorkItem?
  private var tileGeneration = 0
  private var windowCache: [pid_t: AXUIElement] = [:]
  private var liveMoveSession: LiveMoveSession?
  private var pendingLiveRailOrigin: CGPoint?
  private var lastSettledRailOrigin: CGPoint?
  private let sharedWindowSizeKey = "openplan.shared-window-size.v1"

  private struct LiveMoveSession {
    let serviceID: UUID
    let processIdentifier: pid_t
    let window: AXUIElement
    let anchorRailOrigin: CGPoint
    let anchorAppPosition: CGPoint
    var lastAppliedPosition: CGPoint
  }

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
            self.trackedServices.contains(where: {
              $0.bundleIdentifier == bundleIdentifier
            })
          else {
            return
          }
          self.onTrackedApplicationActivated?(bundleIdentifier)
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

  func isInstalled(_ service: ChatService) -> Bool {
    if FileManager.default.fileExists(atPath: service.applicationPath) {
      return true
    }
    return NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: service.bundleIdentifier
    ) != nil
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
    lastSettledRailOrigin = hostWindow.frame.origin
    let center = NotificationCenter.default

    windowObservers.append(
      center.addObserver(
        forName: NSWindow.didMoveNotification,
        object: hostWindow,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.handleHostWindowMove() }
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
        Task { @MainActor in self?.onSettingsWindowClosed?() }
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

  private func handleHostWindowMove() {
    guard let hostWindow else { return }
    let currentRailOrigin = hostWindow.frame.origin

    if settingsWindow?.isVisible == true {
      tileSettingsWindow(positionOnly: NSEvent.pressedMouseButtons != 0)
      lastSettledRailOrigin = currentRailOrigin
      return
    }

    guard NSEvent.pressedMouseButtons != 0 else {
      if liveMoveSession != nil {
        finishLiveMove()
      } else {
        lastSettledRailOrigin = currentRailOrigin
        scheduleSettledTile(after: 0.05)
      }
      return
    }

    if liveMoveSession == nil {
      guard
        accessibilityGranted,
        let selectedService,
        let application = runningApplication(for: selectedService),
        !application.isHidden,
        let window = firstWindow(of: application),
        let appPosition = pointAttribute(
          kAXPositionAttribute as CFString,
          from: window
        )
      else {
        return
      }

      cancelPendingTile()
      captureSharedWindowSize(from: selectedService)
      liveMoveSession = LiveMoveSession(
        serviceID: selectedService.id,
        processIdentifier: application.processIdentifier,
        window: window,
        anchorRailOrigin: lastSettledRailOrigin ?? currentRailOrigin,
        anchorAppPosition: appPosition,
        lastAppliedPosition: appPosition
      )
    }

    pendingLiveRailOrigin = currentRailOrigin
    scheduleLivePositionUpdate()
    scheduleLiveMoveFinishCheck()
  }

  private func scheduleLivePositionUpdate() {
    guard liveMoveWorkItem == nil else { return }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.liveMoveWorkItem = nil
      self.applyPendingLivePosition()

      if self.pendingLiveRailOrigin != nil {
        self.scheduleLivePositionUpdate()
      }
    }

    liveMoveWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + (1.0 / 60.0),
      execute: workItem
    )
  }

  private func applyPendingLivePosition() {
    guard
      var session = liveMoveSession,
      session.serviceID == selectedService?.id,
      let railOrigin = pendingLiveRailOrigin
    else {
      pendingLiveRailOrigin = nil
      return
    }
    pendingLiveRailOrigin = nil

    let deltaX = railOrigin.x - session.anchorRailOrigin.x
    let deltaY = railOrigin.y - session.anchorRailOrigin.y
    var targetPosition = CGPoint(
      x: session.anchorAppPosition.x + deltaX,
      y: session.anchorAppPosition.y - deltaY
    )

    guard distance(session.lastAppliedPosition, targetPosition) > 0.75 else {
      return
    }

    guard let positionValue = AXValueCreate(.cgPoint, &targetPosition) else {
      return
    }

    let result = AXUIElementSetAttributeValue(
      session.window,
      kAXPositionAttribute as CFString,
      positionValue
    )

    if result == .success {
      session.lastAppliedPosition = targetPosition
      liveMoveSession = session
    } else if result == .invalidUIElement {
      windowCache[session.processIdentifier] = nil
      cancelLiveMove()
    }
  }

  private func scheduleLiveMoveFinishCheck() {
    tileWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }

      if NSEvent.pressedMouseButtons != 0 {
        self.scheduleLiveMoveFinishCheck()
      } else {
        self.finishLiveMove()
      }
    }
    tileWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
  }

  private func finishLiveMove() {
    liveMoveWorkItem?.cancel()
    liveMoveWorkItem = nil
    applyPendingLivePosition()
    liveMoveSession = nil
    pendingLiveRailOrigin = nil
    lastSettledRailOrigin = hostWindow?.frame.origin
    tileSelectedApplication()
  }

  private func cancelLiveMove() {
    liveMoveWorkItem?.cancel()
    liveMoveWorkItem = nil
    liveMoveSession = nil
    pendingLiveRailOrigin = nil
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

  private func tileSettingsWindow(positionOnly: Bool = false) {
    guard
      let settingsWindow,
      let targetFrame = targetFrame()
    else {
      return
    }

    if positionOnly {
      settingsWindow.setFrameOrigin(targetFrame.origin)
    } else {
      settingsWindow.setFrame(targetFrame, display: true)
    }
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
      lastSettledRailOrigin = hostWindow?.frame.origin
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

    if positionResult == .success && sizeResult == .success {
      lastSettledRailOrigin = hostWindow?.frame.origin
    }

    return positionResult == .success && sizeResult == .success
  }

  private func firstWindow(of application: NSRunningApplication) -> AXUIElement? {
    if let cached = windowCache[application.processIdentifier] {
      return cached
    }

    let appElement = AXUIElementCreateApplication(application.processIdentifier)
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
        var minimizedValue: CFTypeRef?
        AXUIElementCopyAttributeValue(
          window,
          kAXMinimizedAttribute as CFString,
          &minimizedValue
        )
        return (minimizedValue as? Bool) != true
      }) ?? windows.first

    if let window {
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
    if FileManager.default.fileExists(atPath: service.applicationPath) {
      return URL(fileURLWithPath: service.applicationPath)
    }
    return NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: service.bundleIdentifier
    )
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
    runningBundleIdentifiers = Set(applications.compactMap(\.bundleIdentifier))
    hiddenBundleIdentifiers = Set(
      applications.compactMap { application in
        application.isHidden ? application.bundleIdentifier : nil
      }
    )
  }
}
