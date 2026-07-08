#if os(macOS)
import PaveKit
import SwiftUI

enum StepType: String, CaseIterable, Identifiable {
    case app, open, text, keys, shell, window, system, delay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .app: return "App"
        case .open: return "Open"
        case .text: return "Type text"
        case .keys: return "Keystroke"
        case .shell: return "Shell"
        case .window: return "Window"
        case .system: return "System"
        case .delay: return "Delay"
        }
    }
}

struct StepDraft: Identifiable {
    let id = UUID()
    var type: StepType
    var bundleId = ""
    var target = ""
    var string = ""
    var restoreClipboard = true
    var key = ""
    var mods: Set<String> = []
    var script = ""
    var timeoutSec = "10"
    var toastOn = true
    var windowAction: WindowAction = .leftHalf
    var systemAction: SystemAction = .darkModeToggle
    var ms = "250"

    init(type: StepType) { self.type = type }

    init?(step: Step) {
        switch step {
        case .app(let b): type = .app; bundleId = b
        case .open(let t): type = .open; target = t
        case .text(let s, let r): type = .text; string = s; restoreClipboard = r
        case .keys(let k, let m): type = .keys; key = k; mods = Set(m)
        case .shell(let s, let t, let to):
            type = .shell; script = s; timeoutSec = String(Int(t)); toastOn = to
        case .window(let a): type = .window; windowAction = a
        case .system(let a): type = .system; systemAction = a
        case .delay(let v): type = .delay; ms = String(v)
        case .unknown: return nil
        }
    }

    func toStep() -> Step? {
        switch type {
        case .app: return bundleId.isEmpty ? nil : .app(bundleId: bundleId)
        case .open: return target.isEmpty ? nil : .open(target: target)
        case .text: return .text(string: string, restoreClipboard: restoreClipboard)
        case .keys:
            return KeyCodes.code(for: key) == nil ? nil : .keys(key: key, mods: Array(mods))
        case .shell:
            return script.isEmpty ? nil
                : .shell(script: script, timeoutSec: Double(timeoutSec) ?? 10, toast: toastOn)
        case .window: return .window(windowAction)
        case .system: return .system(systemAction)
        case .delay:
            guard let v = Int(ms), v >= 0 else { return nil }
            return .delay(ms: v)
        }
    }
}

struct MacroEditorView: View {
    @EnvironmentObject var model: EditorModel
    let macro: Macro

    @State private var name = ""
    @State private var context = ""
    @State private var enabled = true
    @State private var hasHotkey = false
    @State private var key = ""
    @State private var mods: Set<String> = []
    @State private var steps: [StepDraft] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if macro.hasUnknownSteps {
                VStack(alignment: .leading, spacing: 12) {
                    Label("This macro contains step types this build does not know.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("It is disabled and read-only here so nothing gets dropped. Edit the JSON by hand if you know what it is:")
                    Text(model.store.macrosDir.appendingPathComponent("\(macro.id.uuidString).json").path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                editor
            }
        }
        .onAppear { if !loaded { load(); loaded = true } }
    }

    private var editor: some View {
        Form {
            Section("Macro") {
                TextField("Name", text: $name)
                TextField("App context (bundle id, empty = global)", text: $context)
                Toggle("Enabled", isOn: $enabled)
            }
            Section("Hotkey") {
                Toggle("Bind a hotkey", isOn: $hasHotkey)
                if hasHotkey {
                    HStack(spacing: 10) {
                        modToggle("cmd", "\u{2318}")
                        modToggle("shift", "\u{21E7}")
                        modToggle("opt", "\u{2325}")
                        modToggle("ctrl", "\u{2303}")
                        TextField("Key (r, f5, space, left…)", text: $key)
                            .frame(width: 160)
                    }
                }
            }
            Section("Steps") {
                ForEach($steps) { $step in
                    StepRow(step: $step,
                            onDelete: { steps.removeAll { $0.id == step.id } },
                            onUp: { move(step.id, by: -1) },
                            onDown: { move(step.id, by: 1) })
                }
                Menu("Add step") {
                    ForEach(StepType.allCases) { t in
                        Button(t.label) { steps.append(StepDraft(type: t)) }
                    }
                }
            }
            if let error {
                Text(error).foregroundColor(.red)
            }
            Section {
                HStack {
                    Button("Save") { save() }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                    Button("Test run") {
                        save()
                        if error == nil { model.testRun(macro.id) }
                    }
                    .help("Runs through the agent, the real path.")
                    Spacer()
                    Button("Delete", role: .destructive) { model.delete(macro.id) }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func modToggle(_ name: String, _ symbol: String) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { mods.contains(name) },
            set: { on in if on { mods.insert(name) } else { mods.remove(name) } }))
        .toggleStyle(.button)
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < steps.count else { return }
        steps.swapAt(i, j)
    }

    private func load() {
        name = macro.name
        context = macro.context ?? ""
        enabled = macro.enabled
        hasHotkey = macro.hotkey != nil
        key = macro.hotkey?.key ?? ""
        mods = Set(macro.hotkey?.mods ?? [])
        steps = macro.steps.compactMap { StepDraft(step: $0) }
    }

    private func save() {
        let converted = steps.compactMap { $0.toStep() }
        guard converted.count == steps.count else {
            error = "Fix invalid steps: missing fields or an unknown key name."
            return
        }
        if hasHotkey, KeyCodes.code(for: key) == nil {
            error = "Unknown key '\(key)'. Use names like r, f5, space, left."
            return
        }
        var m = macro
        m.name = name.isEmpty ? "Untitled" : name
        m.context = context.isEmpty ? nil : context
        m.enabled = enabled
        m.hotkey = hasHotkey ? Hotkey(key: key, mods: Array(mods)) : nil
        m.steps = converted
        model.save(m)
        error = nil
    }
}

struct StepRow: View {
    @Binding var step: StepDraft
    var onDelete: () -> Void
    var onUp: () -> Void
    var onDown: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Picker("", selection: $step.type) {
                ForEach(StepType.allCases) { t in Text(t.label).tag(t) }
            }
            .labelsHidden()
            .frame(width: 110)

            VStack(alignment: .leading, spacing: 6) { fields }
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 2) {
                Button(action: onUp) { Image(systemName: "chevron.up") }
                Button(action: onDown) { Image(systemName: "chevron.down") }
                Button(action: onDelete) { Image(systemName: "xmark") }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var fields: some View {
        switch step.type {
        case .app:
            TextField("Bundle id (com.apple.Safari)", text: $step.bundleId)
        case .open:
            TextField("URL, file, or folder (~/Downloads)", text: $step.target)
        case .text:
            TextField("Text to type", text: $step.string)
            Toggle("Restore clipboard after", isOn: $step.restoreClipboard)
        case .keys:
            HStack {
                TextField("Key", text: $step.key).frame(width: 90)
                ForEach(["cmd", "shift", "opt", "ctrl"], id: \.self) { m in
                    Toggle(m, isOn: Binding(
                        get: { step.mods.contains(m) },
                        set: { on in if on { step.mods.insert(m) } else { step.mods.remove(m) } }))
                    .toggleStyle(.button)
                }
            }
        case .shell:
            TextField("Script", text: $step.script, axis: .vertical)
                .lineLimit(1 ... 6)
                .font(.body.monospaced())
            HStack {
                TextField("Timeout (s)", text: $step.timeoutSec).frame(width: 90)
                Toggle("Toast output", isOn: $step.toastOn)
            }
        case .window:
            Picker("Action", selection: $step.windowAction) {
                ForEach(WindowAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        case .system:
            Picker("Action", selection: $step.systemAction) {
                ForEach(SystemAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        case .delay:
            TextField("Milliseconds", text: $step.ms).frame(width: 120)
        }
    }
}
#endif
