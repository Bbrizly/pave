#if os(macOS)
import MacroEngineKit
import SwiftUI

/// Assign macros to the 8 slices of a ring, per app context, with a live preview.
/// Submenus are supported by the agent but authored in rings.json by hand for now.
struct RingEditorView: View {
    @EnvironmentObject var model: EditorModel
    @State private var context = "global"
    @State private var newContext = ""
    @State private var slots: [UUID?] = Array(repeating: nil, count: 8)
    @State private var loadedContext = ""

    private var contexts: [String] {
        var set = Set(model.rings.keys)
        set.insert("global")
        for m in model.macros { if let c = m.context { set.insert(c) } }
        return set.sorted { a, b in
            if a == "global" { return true }
            if b == "global" { return false }
            return a < b
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Form {
                Section("Ring") {
                    Picker("App context", selection: $context) {
                        ForEach(contexts, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        TextField("New context (bundle id)", text: $newContext)
                        Button("Add") {
                            guard !newContext.isEmpty else { return }
                            model.rings[newContext] = []
                            context = newContext
                            newContext = ""
                        }
                    }
                }
                Section("Slices (top, then clockwise)") {
                    ForEach(0 ..< 8, id: \.self) { i in
                        Picker("Slice \(i + 1)", selection: $slots[i]) {
                            Text("Empty").tag(UUID?.none)
                            ForEach(model.macros.filter { !$0.hasUnknownSteps }) { m in
                                Text(m.name).tag(Optional(m.id))
                            }
                        }
                    }
                }
                Section {
                    Button("Save ring") { save() }
                        .buttonStyle(.borderedProminent)
                    Text("Hold the radial key anywhere to summon this. Center cancels.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 420)

            preview
                .frame(width: 320, height: 320)
                .padding(.top, 20)
        }
        .padding()
        .onAppear { loadIfNeeded() }
        .onChange(of: context) { _ in load() }
    }

    private var filledNames: [String] {
        slots.compactMap { id in
            id.flatMap { mid in model.macros.first { $0.id == mid }?.name }
        }
    }

    private var preview: some View {
        Canvas { ctx, size in
            let names = filledNames
            guard !names.isEmpty else {
                let t = Text("Empty ring").foregroundColor(.secondary)
                ctx.draw(t, at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 8
            let inner: CGFloat = 34
            let per = 2 * CGFloat.pi / CGFloat(names.count)
            for (i, name) in names.enumerated() {
                // Canvas y is down, so top = -pi/2 and clockwise = increasing angle.
                let mid = -CGFloat.pi / 2 + CGFloat(i) * per
                let a0 = mid - per / 2
                let a1 = mid + per / 2
                var p = Path()
                p.addArc(center: c, radius: outer,
                         startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
                p.addArc(center: c, radius: inner,
                         startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
                p.closeSubpath()
                ctx.fill(p, with: .color(Color(nsColor: .windowBackgroundColor)))
                ctx.stroke(p, with: .color(Color(nsColor: .separatorColor)), lineWidth: 1)
                let lr = (inner + outer) / 2
                let at = CGPoint(x: c.x + cos(mid) * lr, y: c.y + sin(mid) * lr)
                ctx.draw(Text(name).font(.system(size: 11, weight: .semibold)), at: at)
            }
            var hole = Path()
            hole.addEllipse(in: CGRect(x: c.x - 20, y: c.y - 20, width: 40, height: 40))
            ctx.fill(hole, with: .color(.black.opacity(0.25)))
        }
    }

    private func loadIfNeeded() {
        if loadedContext != context { load() }
    }

    private func load() {
        loadedContext = context
        var s: [UUID?] = Array(repeating: nil, count: 8)
        let ring = model.rings[context] ?? []
        for (i, slice) in ring.prefix(8).enumerated() {
            s[i] = slice.macro
        }
        slots = s
    }

    private func save() {
        let ring: [RingSlice] = slots.compactMap { id in
            guard let id, let m = model.macros.first(where: { $0.id == id }) else { return nil }
            return RingSlice(label: m.name, macro: m.id)
        }
        model.rings[context] = ring
        model.saveRings()
    }
}
#endif
