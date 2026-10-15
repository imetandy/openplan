import ApplicationServices
import Foundation

// The retained AX reference is immutable; all requests run on a worker queue.
struct LiveWindowSnapshot: @unchecked Sendable {
  let window: AXUIElement
  let position: CGPoint
  let size: CGSize?
}

/// Samples the native drag directly from WindowServer, independently of AppKit's
/// tracking loop. Each tick reads the latest position and makes at most one AX
/// request. Slow applications never accumulate a backlog of old destinations.
@MainActor
final class LivePositionWriter {
  private static let queue = DispatchQueue(label: "openplan.window-lookup", qos: .userInteractive)
  private let worker: Worker
  private var timer: DispatchSourceTimer?
  var onInvalidWindow: (() -> Void)?

  init(readPosition: @escaping @Sendable () -> CGPoint?, write: @escaping @Sendable (CGPoint) -> AXError) {
    worker = Worker(readPosition: readPosition, write: write)
    worker.onInvalidWindow = { [weak self] in
      DispatchQueue.main.async { self?.onInvalidWindow?() }
    }
  }

  convenience init(snapshot: LiveWindowSnapshot, railWindowID: CGWindowID,
                   attachment: WindowAttachment, appSize: CGSize) {
    self.init(readPosition: {
      guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, railWindowID) as? [[String: Any]])?.first,
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
      return attachment.appQuartzOrigin(fromRailQuartzFrame: frame, appSize: appSize)
    }, write: { position in
      var position = position
      guard let value = AXValueCreate(.cgPoint, &position) else { return .failure }
      return AXUIElementSetAttributeValue(snapshot.window, kAXPositionAttribute as CFString, value)
    })
  }

  func start(framesPerSecond: Int) {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: worker.queue)
    timer.schedule(deadline: .now(), repeating: 1 / Double(max(60, framesPerSecond)),
                   leeway: .microseconds(250))
    let worker = worker
    timer.setEventHandler { worker.sample() }
    self.timer = timer
    timer.resume()
  }

  func finish(_ completion: @escaping (CGPoint?) -> Void) {
    timer?.cancel()
    timer = nil
    let worker = worker
    worker.queue.async {
      worker.sample()
      guard !worker.isCancelled else { return }
      let position = worker.lastPosition
      DispatchQueue.main.async { completion(position) }
    }
  }

  func cancel() {
    worker.cancel()
    timer?.cancel()
    timer = nil
  }

  deinit {
    worker.cancel()
    timer?.cancel()
  }

  // Only cancellation crosses queues. No main-thread round trip between writes.
  private final class Worker: @unchecked Sendable {
    let queue = DispatchQueue(label: "openplan.live-window-position", qos: .userInteractive)
    let readPosition: @Sendable () -> CGPoint?
    let write: @Sendable (CGPoint) -> AXError
    var onInvalidWindow: (() -> Void)?
    var lastPosition: CGPoint?
    private let lock = NSLock()
    private var cancelled = false

    init(readPosition: @escaping @Sendable () -> CGPoint?, write: @escaping @Sendable (CGPoint) -> AXError) {
      self.readPosition = readPosition
      self.write = write
    }

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }

    func sample() {
      guard !isCancelled, let position = readPosition(), position != lastPosition,
        !isCancelled else { return }
      let result = write(position)
      if result == .success { lastPosition = position }
      if result == .invalidUIElement {
        cancel()
        onInvalidWindow?()
      }
    }
  }

  static func prepare(processIdentifier: pid_t, completion: @escaping (LiveWindowSnapshot?) -> Void) {
    queue.async {
      let snapshot = readSnapshot(processIdentifier: processIdentifier)
      DispatchQueue.main.async { completion(snapshot) }
    }
  }

  nonisolated private static func readSnapshot(processIdentifier: pid_t) -> LiveWindowSnapshot? {
    let app = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.1)
    var rawWindows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
      let windows = rawWindows as? [AXUIElement]
    else { return nil }

    // Skip minimized windows and stale references without touching the UI thread.
    for window in windows {
      AXUIElementSetMessagingTimeout(window, 0.1)
      var minimized: CFTypeRef?
      AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
      if minimized as? Bool == true { continue }
      var rawPosition: CFTypeRef?
      guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
        let rawPosition, CFGetTypeID(rawPosition) == AXValueGetTypeID()
      else { continue }
      var position = CGPoint.zero
      guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position) else { continue }
      var size = CGSize.zero
      var rawSize: CFTypeRef?
      let hasSize = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success
      let validSize = hasSize && rawSize.map { value in
        CFGetTypeID(value) == AXValueGetTypeID()
          && AXValueGetValue(value as! AXValue, .cgSize, &size)
      } == true
      return LiveWindowSnapshot(window: window, position: position, size: validSize ? size : nil)
    }
    return nil
  }

}
