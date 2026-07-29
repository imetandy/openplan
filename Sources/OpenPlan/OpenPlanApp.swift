import AppKit
import SwiftUI

@main
struct OpenPlanApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = AppStore()

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
        .frame(width: 76)
        .frame(minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear {
          appDelegate.store = store
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 76, height: 760)
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Application Settings…") {
          store.showSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
      }

      CommandMenu("Applications") {
        Button("Previous Application") {
          store.cycleSelection(direction: -1)
        }
        .keyboardShortcut("[", modifiers: [.command, .shift])

        Button("Next Application") {
          store.cycleSelection(direction: 1)
        }
        .keyboardShortcut("]", modifiers: [.command, .shift])

        Divider()

        ForEach(
          Array(store.enabledServices.prefix(9).enumerated()),
          id: \.element.id
        ) { index, service in
          Button(service.name) {
            store.select(service.id)
          }
          .keyboardShortcut(
            KeyEquivalent(Character(String(index + 1))),
            modifiers: .command
          )
        }

        Divider()

        Button("Fit Selected App") {
          store.fitSelectedWindow()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])

        Button("Reveal Selected App") {
          store.revealSelectedWindow()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
      }
    }

    Window("OpenPlan Settings", id: "settings") {
      SettingsView(store: store)
        .preferredColorScheme(.dark)
        .background(
          HostWindowReader { window in
            store.registerSettingsWindow(window)
          }
        )
    }
    .defaultSize(width: 590, height: 480)
    .windowResizability(.contentMinSize)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var store: AppStore?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }
}
