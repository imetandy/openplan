import AppKit
import SwiftUI

struct HostWindowReader: NSViewRepresentable {
  let onResolve: (NSWindow) -> Void

  func makeNSView(context: Context) -> WindowReaderView {
    WindowReaderView(onResolve: onResolve)
  }

  func updateNSView(_ nsView: WindowReaderView, context: Context) {
    nsView.onResolve = onResolve
  }

  final class WindowReaderView: NSView {
    var onResolve: (NSWindow) -> Void

    init(onResolve: @escaping (NSWindow) -> Void) {
      self.onResolve = onResolve
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      // Resolve only on attachment, outside SwiftUI's update pass.
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window else { return }
        self.onResolve(window)
      }
    }
  }
}
