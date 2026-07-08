#if os(macOS)
import PaveKit
import SwiftUI

@main
struct MacroStudioApp: App {
    @StateObject private var model = EditorModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

enum SidebarItem: Hashable {
    case macro(UUID)
    case radial
    case settings
}

struct ContentView: View {
    @EnvironmentObject var model: EditorModel
    @State private var selection: SidebarItem? = .radial
    @State private var search = ""

    private var grouped: [(title: String, macros: [Macro])] {
        let filtered = search.isEmpty
            ? model.macros
            : model.macros.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let global = filtered.filter { $0.context == nil }
        let contexts = Dictionary(grouping: filtered.filter { $0.context != nil },
                                  by: { $0.context! })
        var out: [(String, [Macro])] = []
        if !global.isEmpty { out.append(("Global", global)) }
        for key in contexts.keys.sorted() {
            out.append((key, contexts[key] ?? []))
        }
        return out
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Surfaces") {
                    Label("Radial", systemImage: "circle.grid.cross")
                        .tag(SidebarItem.radial)
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarItem.settings)
                }
                ForEach(grouped, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.macros) { m in
                            HStack {
                                Text(m.name)
                                Spacer()
                                if m.hasUnknownSteps {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.orange)
                                        .help("Contains unknown step types. Read-only.")
                                }
                                if !m.enabled {
                                    Circle().fill(.secondary).frame(width: 6, height: 6)
                                }
                                if let hk = m.hotkey {
                                    Text(hk.display)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                }
                            }
                            .tag(SidebarItem.macro(m.id))
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search macros")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button {
                    let m = model.newMacro()
                    selection = .macro(m.id)
                } label: {
                    Image(systemName: "plus")
                }
                .help("New macro")
                Menu {
                    Button("Import…") { model.importPanel() }
                    Button("Export all…") { model.exportPanel() }
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
            }
        } detail: {
            switch selection {
            case .macro(let id):
                if let m = model.macros.first(where: { $0.id == id }) {
                    MacroEditorView(macro: m).id(id)
                } else {
                    Text("Select a macro").foregroundColor(.secondary)
                }
            case .radial:
                RingEditorView()
            case .settings:
                SettingsPaneView()
            case nil:
                Text("Select something").foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
                .environmentObject(model)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two permissions before the magic")
                .font(.title2.bold())
            Text("The agent reads your hotkeys and injects keystrokes. macOS gates both behind system permissions. Grant them to MacroStudioAgent (and to Macro Studio for test runs). Five starter macros are already loaded, the wheel works the second you grant access: hold Right Command.")
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(
                granted: model.axGranted,
                name: "Accessibility",
                pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            permissionRow(
                granted: model.inputGranted,
                name: "Input Monitoring",
                pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")

            HStack {
                Button("Check again") { model.refreshPermissions() }
                Button("Launch agent") { model.launchAgent() }
                Spacer()
                Button("Continue") { model.showOnboarding = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 540)
    }

    private func permissionRow(granted: Bool, name: String, pane: String) -> some View {
        HStack {
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(name)
            Spacer()
            if !granted {
                Button("Open Settings") {
                    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                }
            } else {
                Text("Granted").foregroundColor(.secondary)
            }
        }
    }
}

struct SettingsPaneView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        Form {
            Section("Radial") {
                Picker("Hold key", selection: $model.settings.holdKeyCode) {
                    Text("Right Command").tag(54)
                    Text("Right Option").tag(61)
                    Text("F18").tag(79)
                    Text("F19").tag(80)
                }
                Picker("Fire mode", selection: $model.settings.releaseToFire) {
                    Text("Release to fire").tag(true)
                    Text("Click to fire").tag(false)
                }
                Toggle("Tick sound", isOn: $model.settings.tickSound)
            }
            Section {
                Button("Launch agent") { model.launchAgent() }
                Text("Settings save automatically. Start-at-login lives in the agent's menu bar icon.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: model.settings) { _ in model.saveSettings() }
    }
}
#else
@main
enum MacroStudioApp {
    static func main() { print("Macro Studio runs on macOS only.") }
}
#endif
