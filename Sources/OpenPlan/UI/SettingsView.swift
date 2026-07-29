import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @ObservedObject var store: AppStore
  @Environment(\.dismiss) private var dismiss

  @State private var draft: [ChatService]
  @State private var draggedServiceID: UUID?

  init(store: AppStore) {
    self.store = store
    _draft = State(initialValue: store.services)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Applications")
            .font(.system(size: 20, weight: .semibold, design: .rounded))
          Text("Choose, add, and order the macOS apps OpenPlan arranges.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .padding(22)

      Divider()

      ScrollView {
        VStack(spacing: 0) {
          ForEach($draft) { $service in
            applicationRow(service: $service)
              .onDrop(
                of: [.text],
                delegate: ServiceDropDelegate(
                  targetID: service.id,
                  services: $draft,
                  draggedServiceID: $draggedServiceID
                )
              )

            if service.id != draft.last?.id {
              Divider()
                .padding(.leading, 74)
            }
          }

          Divider()
            .padding(.leading, 74)

          Button {
            addApplicationSlot()
          } label: {
            Label("Add chat app", systemImage: "plus")
              .font(.system(size: 12, weight: .medium))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 13)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
      }

      Divider()

      HStack {
        Label(
          "Apps keep their own data and notifications.",
          systemImage: "app.badge"
        )
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)

        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          store.saveServices(draft)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(18)
    }
    .frame(minWidth: 480, minHeight: 400)
    .onChange(of: store.isSettingsPresented) { _, isPresented in
      if isPresented {
        draft = store.services
      }
    }
  }

  private func applicationRow(service: Binding<ChatService>) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.tertiary)
        .frame(width: 12, height: 38)
        .contentShape(Rectangle())
        .help("Drag to reorder")
        .onDrag {
          draggedServiceID = service.wrappedValue.id
          return NSItemProvider(
            object: service.wrappedValue.id.uuidString as NSString
          )
        }

      ServiceMark(service: service.wrappedValue, size: 38)

      VStack(alignment: .leading, spacing: 5) {
        TextField("App name", text: service.name)
          .font(.system(size: 12.5, weight: .semibold))
          .textFieldStyle(.plain)

        HStack(spacing: 7) {
          TextField(
            "/Applications/\(service.wrappedValue.name).app",
            text: service.applicationPath
          )
          .font(.system(size: 11.5, design: .monospaced))
          .textFieldStyle(.plain)
          .padding(.horizontal, 9)
          .frame(height: 29)
          .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 7)
          )

          Button("Choose…") {
            chooseApplication(for: service)
          }
          .controlSize(.small)
        }
      }

      Toggle("", isOn: service.isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)

      Button {
        removeApplication(service.wrappedValue.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Remove \(service.wrappedValue.name)")
    }
    .padding(.vertical, 12)
    .opacity(service.wrappedValue.isEnabled ? 1 : 0.5)
  }

  private func chooseApplication(for service: Binding<ChatService>) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")

    guard panel.runModal() == .OK, let url = panel.url else { return }
    service.wrappedValue.applicationPath = url.path

    if let bundle = Bundle(url: url) {
      if let identifier = bundle.bundleIdentifier {
        service.wrappedValue.bundleIdentifier = identifier
      }

      let displayName =
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? url.deletingPathExtension().lastPathComponent
      service.wrappedValue.name = displayName
      service.wrappedValue.symbol =
        displayName.first.map { String($0).uppercased() } ?? "+"
      service.wrappedValue.isEnabled = true
    }
  }

  private func addApplicationSlot() {
    withAnimation(.snappy(duration: 0.2)) {
      draft.append(ChatService.customSlot(at: draft.count))
    }
  }

  private func removeApplication(_ id: UUID) {
    withAnimation(.snappy(duration: 0.2)) {
      draft.removeAll(where: { $0.id == id })
    }
  }
}

private struct ServiceDropDelegate: DropDelegate {
  let targetID: UUID
  @Binding var services: [ChatService]
  @Binding var draggedServiceID: UUID?

  func dropEntered(info: DropInfo) {
    guard
      let draggedServiceID,
      draggedServiceID != targetID,
      let sourceIndex = services.firstIndex(where: {
        $0.id == draggedServiceID
      }),
      let targetIndex = services.firstIndex(where: { $0.id == targetID })
    else {
      return
    }

    withAnimation(.snappy(duration: 0.18)) {
      services.move(
        fromOffsets: IndexSet(integer: sourceIndex),
        toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
      )
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedServiceID = nil
    return true
  }
}
