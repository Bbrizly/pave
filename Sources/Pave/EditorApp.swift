#if os(macOS)
import PaveKit
import SwiftUI

@main
struct PaveApp: App {
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
    case activity
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

    /// A macro's sidebar glyph, borrowed from its first step. Mirrors the agent.
    static func icon(for macro: Macro) -> String {
        switch macro.steps.first {
        case .app: return "app.fill"
        case .open: return "folder.fill"
        case .text: return "text.cursor"
        case .keys: return "keyboard.fill"
        case .shell: return "terminal.fill"
        case .window: return "macwindow"
        case .system: return "gearshape.fill"
        case .delay: return "clock.fill"
        default: return "sparkles"
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Surfaces") {
                    Label("Radial", systemImage: "circle.grid.cross")
                        .tag(SidebarItem.radial)
                    Label("Activity", systemImage: "footprints")
                        .tag(SidebarItem.activity)
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarItem.settings)
                }
                ForEach(grouped, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.macros) { m in
                            HStack(spacing: 8) {
                                Image(systemName: Self.icon(for: m))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(m.enabled ? .accentColor : .secondary)
                                    .frame(width: 16)
                                Text(m.name)
                                    .foregroundColor(m.enabled ? .primary : .secondary)
                                Spacer(minLength: 6)
                                if m.hasUnknownSteps {
                                    Image(systemName: "exclamationmark.triangle.fill")
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
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12),
                                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(SidebarItem.macro(m.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search macros")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
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
            case .activity:
                ActivityView()
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
        .frame(minWidth: 940, minHeight: 600)
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two permissions before the magic")
                .font(.title2.bold())
            Text("The agent reads your hotkeys and injects keystrokes. macOS gates both behind system permissions. Grant them to PaveAgent (and to Pave for test runs). Five starter macros are already loaded, the wheel works the second you grant access: hold Right Command.")
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
            Section("Trigger") {
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
                LabeledContent("Hold delay") {
                    HStack {
                        Slider(value: intBinding($model.settings.holdDelayMs), in: 60 ... 400, step: 10)
                            .frame(maxWidth: 220)
                        Text("\(model.settings.holdDelayMs) ms")
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Text("How long to hold before the wheel appears. Shorter feels instant, longer lets you tap the key for other uses.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Appearance") {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $model.settings.radialScale, in: 0.6 ... 1.2, step: 0.05)
                            .frame(maxWidth: 220)
                        Text("\(Int((model.settings.radialScale * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent("Animation speed") {
                    HStack {
                        Slider(value: $model.settings.radialAnimSpeed, in: 0.5 ... 2.0, step: 0.05)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.2f×", model.settings.radialAnimSpeed))
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Toggle("Bloom animation", isOn: $model.settings.radialBloom)
                Toggle("Selection glow", isOn: $model.settings.radialGlow)
            }

            Section("Feedback") {
                Toggle("Tick sound", isOn: $model.settings.tickSound)
            }

            Section("Menu-bar hand") {
                Toggle("Animated hand icon", isOn: $model.settings.icon.enabled)
                if model.settings.icon.enabled {
                    Picker("Style", selection: $model.settings.icon.renderStyle) {
                        Text("Template (adapts to light/dark)").tag("template")
                        Text("Full colour").tag("color")
                    }
                    Toggle("Animate while working", isOn: $model.settings.icon.animateWorking)
                    LabeledContent("Working speed") {
                        HStack {
                            Slider(value: $model.settings.icon.workingFPS, in: 6 ... 24, step: 1)
                                .frame(maxWidth: 220)
                            Text("\(Int(model.settings.icon.workingFPS)) fps")
                                .font(.callout.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    LabeledContent("Icon size") {
                        HStack {
                            Slider(value: $model.settings.icon.pointHeight, in: 14 ... 22, step: 1)
                                .frame(maxWidth: 220)
                            Text("\(Int(model.settings.icon.pointHeight)) pt")
                                .font(.callout.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    Toggle("Finish the loop before switching state", isOn: $model.settings.icon.finishFullLoop)
                    Toggle("Alert badge dot", isOn: $model.settings.icon.showAlertDot)
                    HStack {
                        Button("Test animation") { model.testIcon() }
                        Spacer()
                        Text("Plays the working hand in your menu bar.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Button("Reset radial to defaults") {
                        let d = Settings()
                        model.settings.holdDelayMs = d.holdDelayMs
                        model.settings.radialScale = d.radialScale
                        model.settings.radialAnimSpeed = d.radialAnimSpeed
                        model.settings.radialBloom = d.radialBloom
                        model.settings.radialGlow = d.radialGlow
                    }
                    Spacer()
                    Button("Launch agent") { model.launchAgent() }
                }
                Text("Settings save and reload the agent automatically. Start-at-login lives in the agent's menu bar icon.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: model.settings) { _ in model.saveSettings() }
    }

    /// Bridges an Int setting to the Double a Slider needs.
    private func intBinding(_ source: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(source.wrappedValue) },
                set: { source.wrappedValue = Int($0.rounded()) })
    }
}
#else
@main
enum PaveApp {
    static func main() { print("Pave runs on macOS only.") }
}
#endif
