import SwiftUI

struct ContentView: View {
  @ObservedObject var store: AppStore
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ServiceRail(store: store)
      .frame(width: 76)
      .frame(maxHeight: .infinity)
      .ignoresSafeArea(.container, edges: .top)
      .background(
        HostWindowReader { window in
          store.registerHostWindow(window)
        }
      )
      .sheet(isPresented: $store.isPermissionHelpPresented) {
        PermissionView(store: store)
      }
      .onChange(of: store.isSettingsPresented) { _, isPresented in
        if isPresented {
          openWindow(id: "settings")
        }
      }
      .overlay(alignment: .topTrailing) {
        if store.statusMessage != nil {
          Circle()
            .fill(Color.orange)
            .frame(width: 7, height: 7)
            .padding(.top, 50)
            .padding(.trailing, 9)
            .help(store.statusMessage ?? "")
        }
      }
  }
}
