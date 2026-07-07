import Foundation
import MacroEngineKit

@main
enum Ctl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let store = Store()

        switch args.first {
        case "list":
            let macros = store.loadMacros()
            if macros.isEmpty {
                print("No macros in \(store.macrosDir.path)")
                return
            }
            for m in macros {
                let hk = m.hotkey?.display ?? "-"
                let ctx = m.context ?? "global"
                let flags = (m.enabled ? "" : " [disabled]") + (m.hasUnknownSteps ? " [unknown steps]" : "")
                print("\(m.id.uuidString)  \(hk)  \(ctx)  \(m.name)\(flags)")
            }

        case "run":
            guard let key = args.dropFirst().first else {
                fail("usage: macroctl run <uuid-or-name>")
            }
            let macros = store.loadMacros()
            let target = macros.first { $0.id.uuidString.lowercased() == key.lowercased() }
                ?? macros.first { $0.name.lowercased() == key.lowercased() }
            guard let macro = target else {
                fail("no macro matching '\(key)'. Try: macroctl list")
            }
            run(macro)

        default:
            print("""
            macroctl: run Macro Studio macros from the terminal
              macroctl list
              macroctl run <uuid-or-name>
            """)
        }
    }

    static func run(_ macro: Macro) {
        #if os(macOS)
        let runner = MacRunner()
        runner.toast = { print($0) }
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Executor().run(macro, with: runner) { result in
            if case .failure(let err) = result {
                FileHandle.standardError.write(Data("error: \(err.description)\n".utf8))
                exitCode = 1
            } else {
                print("ok: \(macro.name)")
            }
            sem.signal()
        }
        sem.wait()
        exit(exitCode)
        #else
        fail("run is macOS only")
        #endif
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(1)
    }
}
